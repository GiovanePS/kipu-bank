import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { parseEther } from "viem";
import { network } from "hardhat";

const ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

describe("KipuBankV2", async function() {
    const { viem } = await network.connect();

    async function deployAll(opts?: {
        ethPriceUsd8?: bigint;
        maxEthCap?: bigint;
        maxUsdCap?: bigint;
    }) {
        const {
            ethPriceUsd8 = 2_500n * 10n ** 8n,
            maxEthCap = parseEther("100"),
            maxUsdCap = 100_000n * 10n ** 6n,
        } = opts ?? {};

        const [deployer, user, recovery] = await viem.getWalletClients();
        const publicClient = await viem.getPublicClient();

        const feed = await viem.deployContract("MockV3Aggregator", [8, ethPriceUsd8], {
            client: { wallet: deployer },
        });

        const usdc = await viem.deployContract("MockERC20", ["USD Coin", "USDC", 6], {
            client: { wallet: deployer },
        });

        const permit2 = await viem.deployContract("MockPermit2", [], {
            client: { wallet: deployer },
        });

        const router = await viem.deployContract("MockUniversalRouter", [usdc.address], {
            client: { wallet: deployer },
        });

        const bank = await viem.deployContract(
            "KipuBank",
            [maxEthCap, maxUsdCap, feed.address, usdc.address, router.address, permit2.address],
            { client: { wallet: deployer } },
        );

        return { deployer, user, recovery, publicClient, feed, usdc, bank };
    }

    describe("Roles and Access Control", () => {
        it("sets roles and recovery", async () => {
            const { bank, recovery, deployer } = await deployAll();

            const RECOVERY_ROLE = await bank.read.RECOVERY_ROLE();
            await bank.write.grantRecovery([recovery.account.address], { account: deployer.account });

            const has = await bank.read.hasRole([RECOVERY_ROLE, recovery.account.address]);
            assert.equal(has, true);
        });
    });

    describe("ETH Deposits and Withdrawals", () => {
        it("depositEth updates balances and ETH cap", async () => {
            const { bank, user } = await deployAll();

            const beforeCap = await bank.read.currentBankCapEth();
            await bank.write.depositEth({ account: user.account, value: parseEther("1") });

            const bal = await bank.read.getMyBalance([ETH], { account: user.account });
            const afterCap = await bank.read.currentBankCapEth();

            assert.equal(bal, parseEther("1"));
            assert.equal(beforeCap - afterCap, parseEther("1"));
        });

        it("withdraw ETH respects USD $1,000 limit", async () => {
            const { bank, user } = await deployAll({ ethPriceUsd8: 2_500n * 10n ** 8n });

            await bank.write.depositEth({ account: user.account, value: parseEther("1") });

            await bank.write.withdraw([ETH, parseEther("0.3")], { account: user.account });

            await assert.rejects(
                bank.write.withdraw([ETH, parseEther("0.5")], { account: user.account }),
                /WithdrawLimitExceeded/,
            );
        });
    });

    describe("USDC Deposits and Withdrawals", () => {
        it("depositUsdc pulls tokens and reduces USDC cap", async () => {
            const { bank, user, usdc, deployer } = await deployAll();

            await usdc.write.mint([user.account.address, 5_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([bank.address, 5_000n * 10n ** 6n], { account: user.account });

            const capBefore = await bank.read.currentBankCapUsdc();
            await bank.write.depositUsdc([1_500n * 10n ** 6n], { account: user.account });

            const bal = await bank.read.getMyBalance([usdc.address], { account: user.account });
            const capAfter = await bank.read.currentBankCapUsdc();

            assert.equal(bal, 1_500n * 10n ** 6n);
            assert.equal(capBefore - capAfter, 1_500n * 10n ** 6n);
        });

        it("withdraw USDC respects USD $1,000 limit", async () => {
            const { bank, user, usdc, deployer } = await deployAll();

            await usdc.write.mint([user.account.address, 2_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([bank.address, 2_000n * 10n ** 6n], { account: user.account });

            await bank.write.depositUsdc([1_500n * 10n ** 6n], { account: user.account });

            await assert.rejects(
                bank.write.withdraw([usdc.address, 1_100n * 10n ** 6n], { account: user.account }),
                /WithdrawLimitExceeded/,
            );

            await bank.write.withdraw([usdc.address, 900n * 10n ** 6n], { account: user.account });
        });
    });

    describe("Admin Recovery", () => {
        it("admin recovery adjusts balances and caps per token (ETH)", async () => {
            const { bank, recovery, user, deployer } = await deployAll({ maxEthCap: parseEther("10") });

            await bank.write.grantRecovery([recovery.account.address], { account: deployer.account });

            const capEthBefore = await bank.read.currentBankCapEth();
            await bank.write.setInternalBalance([user.account.address, ETH, parseEther("1")], {
                account: recovery.account,
            });
            const capEthAfter = await bank.read.currentBankCapEth();
            assert.equal(capEthBefore - capEthAfter, parseEther("1"));

            await bank.write.setInternalBalance([user.account.address, ETH, 0n], {
                account: recovery.account,
            });
            const capEthAfter2 = await bank.read.currentBankCapEth();
            assert.equal(capEthAfter2, capEthBefore);
        });
    });

    describe("Oracle Integration", () => {
        it("stale oracle blocks ETH withdrawals", async () => {
            const { bank, user, feed, publicClient } = await deployAll();

            await bank.write.depositEth({ account: user.account, value: parseEther("1") });

            const latest = await publicClient.getBlock({ blockTag: "latest" });
            const nowTs = Number(latest!.timestamp);
            const staleTs = BigInt(nowTs - (3 * 3600 + 30));

            const agg = await viem.getContractAt("MockV3Aggregator", feed.address);
            await agg.write.setUpdatedAt([staleTs]);

            await assert.rejects(
                bank.write.withdraw([ETH, parseEther("0.1")], { account: user.account }),
                /OracleStale/,
            );
        });
    });
});
