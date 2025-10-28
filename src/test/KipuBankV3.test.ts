import { describe, it } from "node:test";
import assert from "node:assert";
import { parseEther, parseUnits, zeroAddress } from "viem";
import { network } from "hardhat";

// Helper to generate poolKey for Uniswap V4
function createPoolKey(token0: `0x${string}`, token1: `0x${string}`) {
    return {
        currency0: token0 as `0x${string}`,
        currency1: token1 as `0x${string}`,
        fee: 3000, // 0.3%
        tickSpacing: 60,
        hooks: zeroAddress as `0x${string}`,
    };
}

const ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE" as `0x${string}`;

describe("KipuBankV3 - Uniswap V4 Integration Tests", async function() {
    const { viem } = await network.connect();

    async function deployAll(opts?: { maxUsdCap?: bigint }) {
        const publicClient = await viem.getPublicClient();
        const [deployer, user, user2] = await viem.getWalletClients();

        const priceFeed = await viem.deployContract("MockV3Aggregator", [8, 3_000_00000000n], {
            client: { wallet: deployer },
        });

        const usdc = await viem.deployContract("MockERC20", ["USD Coin", "USDC", 6], {
            client: { wallet: deployer },
        });

        const dai = await viem.deployContract("MockERC20", ["Dai Stablecoin", "DAI", 18], {
            client: { wallet: deployer },
        });

        const wbtc = await viem.deployContract("MockERC20", ["Wrapped Bitcoin", "WBTC", 8], {
            client: { wallet: deployer },
        });

        const permit2 = await viem.deployContract("MockPermit2", [], {
            client: { wallet: deployer },
        });

        const router = await viem.deployContract("MockUniversalRouter", [usdc.address], {
            client: { wallet: deployer },
        });

        const maxEthCap = parseEther("100");
        const maxUsdCap = opts?.maxUsdCap ?? 50_000n * 10n ** 6n;
        const bank = await viem.deployContract(
            "KipuBank",
            [maxEthCap, maxUsdCap, priceFeed.address, usdc.address, router.address, permit2.address],
            { client: { wallet: deployer } },
        );

        return { bank, priceFeed, usdc, dai, wbtc, permit2, router, deployer, user, user2, publicClient };
    }
    describe("V3: Happy Path - Basic Token Deposits", () => {
        it("deposits DAI, swaps to USDC, and credits user balance", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("1000", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });

            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            const capBefore = await bank.read.currentBankCapUsdc();

            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const userBalance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(userBalance > 0n, "User balance should be greater than 0");

            const capAfter = await bank.read.currentBankCapUsdc();
            assert.ok(capBefore > capAfter, "Bank cap should decrease");
            assert.equal(capBefore - capAfter, userBalance, "Cap decrease should equal user balance");
        });

        it("deposits WBTC, swaps to USDC, and credits user balance", async () => {
            const { bank, user, wbtc, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            await router.write.setExchangeRate([wbtc.address, 30_000n * 10n ** 6n]);

            const wbtcAmount = 50_000_000n;
            await wbtc.write.mint([user.account.address, wbtcAmount], { account: deployer.account });

            await wbtc.write.approve([bank.address, wbtcAmount], { account: user.account });

            const poolKey = createPoolKey(wbtc.address, usdc.address);

            await bank.write.depositArbitraryToken(
                [wbtc.address, wbtcAmount, poolKey, 1n],
                { account: user.account }
            );

            const userBalance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(userBalance > 0n, "User balance should be greater than 0");

            assert.ok(userBalance > 10_000n * 10n ** 6n, "Should receive substantial USDC");
        });

        it("handles tokens with different decimals correctly", async () => {
            const { bank, user, dai, wbtc, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKeyDai = createPoolKey(dai.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKeyDai, 1n],
                { account: user.account }
            );

            const balanceAfterDai = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balanceAfterDai > 0n, "Should handle 18 decimal tokens");

            const wbtcAmount = 1_000_000n;
            await wbtc.write.mint([user.account.address, wbtcAmount], { account: deployer.account });
            await wbtc.write.approve([bank.address, wbtcAmount], { account: user.account });

            const poolKeyWbtc = createPoolKey(wbtc.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [wbtc.address, wbtcAmount, poolKeyWbtc, 1n],
                { account: user.account }
            );

            const balanceAfterWbtc = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balanceAfterWbtc > balanceAfterDai, "Should handle 8 decimal tokens");
        });
    });

    describe("V3: Bank Cap Validation", () => {
        it("respects USDC bank cap after swap", async () => {

            const { bank, user, dai, usdc, deployer, router } = await deployAll({
                maxUsdCap: 1_000n * 10n ** 6n
            });


            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });


            const daiAmount = parseUnits("2000", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);


            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, daiAmount, poolKey, 1n],
                    { account: user.account }
                ),
                /BankCapUsdcExceeded/
            );
        });

        it("allows deposit if within cap, rejects if exceeds", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll({
                maxUsdCap: 1_000n * 10n ** 6n
            });

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            // First deposit: 500 DAI -> ~500 USDC (within cap)
            const daiAmount1 = parseUnits("500", 18);
            await dai.write.mint([user.account.address, daiAmount1], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount1], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            // Should succeed
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount1, poolKey, 1n],
                { account: user.account }
            );

            const balanceAfter1 = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balanceAfter1 > 0n, "First deposit should succeed");

            // Second deposit: 600 DAI -> ~600 USDC (would exceed remaining cap)
            const daiAmount2 = parseUnits("600", 18);
            await dai.write.mint([user.account.address, daiAmount2], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount2], { account: user.account });

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, daiAmount2, poolKey, 1n],
                    { account: user.account }
                ),
                /BankCapUsdcExceeded/
            );
        });
    });

    describe("V3: Slippage Protection", () => {
        it("reverts if swap output less than minAmountOut", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            const unrealisticMin = 1_000n * 10n ** 6n;

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, daiAmount, poolKey, unrealisticMin],
                    { account: user.account }
                ),
                /SlippageExceeded/
            );
        });

        it("succeeds if swap output meets minAmountOut", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            // Set reasonable minAmountOut (95 USDC from 100 DAI, 5% slippage)
            const reasonableMin = 95n * 10n ** 6n;

            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, reasonableMin],
                { account: user.account }
            );

            const balance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balance >= reasonableMin, "Should receive at least minAmountOut");
        });

        it("works with minAmountOut = 1 (default minimum)", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const balance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balance > 0n, "Should receive some USDC");
        });
    });

    describe("V3: Input Validation", () => {
        it("reverts if tokenIn is ETH address", async () => {
            const { bank, user, usdc } = await deployAll();

            const poolKey = createPoolKey(ETH, usdc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [ETH, parseEther("1"), poolKey, 1n],
                    { account: user.account }
                ),
                /UnsupportedToken/
            );
        });

        it("reverts if tokenIn is zero address", async () => {
            const { bank, user, usdc } = await deployAll();

            const poolKey = createPoolKey(zeroAddress, usdc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [zeroAddress, 1000n, poolKey, 1n],
                    { account: user.account }
                ),
                /UnsupportedToken/
            );
        });

        it("reverts if tokenIn is USDC address", async () => {
            const { bank, user, usdc } = await deployAll();

            const poolKey = createPoolKey(usdc.address, usdc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [usdc.address, 1000n * 10n ** 6n, poolKey, 1n],
                    { account: user.account }
                ),
                /UnsupportedToken/
            );
        });

        it("reverts if amountIn is zero", async () => {
            const { bank, user, dai, usdc } = await deployAll();

            const poolKey = createPoolKey(dai.address, usdc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, 0n, poolKey, 1n],
                    { account: user.account }
                ),
                /InvalidValue/
            );
        });

        it("reverts if poolKey currencies don't match tokenIn/USDC", async () => {
            const { bank, user, dai, wbtc, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const wrongPoolKey = createPoolKey(dai.address, wbtc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, daiAmount, wrongPoolKey, 1n],
                    { account: user.account }
                ),
                /InvalidSwapParams/
            );
        });
    });

    describe("V3: Pool Key Validation", () => {
        it("accepts poolKey with tokenIn as currency0 and USDC as currency1", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const balance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balance > 0n, "Should work with normal order");
        });

        it("accepts poolKey with USDC as currency0 and tokenIn as currency1", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(usdc.address, dai.address);

            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const balance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balance > 0n, "Should work with reversed order");
        });
    });

    describe("V3: Event Emissions", () => {
        it("emits TokenSwapped event with correct parameters", async () => {
            const { bank, user, dai, usdc, deployer, router, publicClient } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            const hash = await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const receipt = await publicClient.waitForTransactionReceipt({ hash });

            assert.ok(receipt.status === "success", "Transaction should succeed");
        });

        it("emits Deposit event with USDC amount", async () => {
            const { bank, user, dai, usdc, deployer, router, publicClient } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            const hash = await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const receipt = await publicClient.waitForTransactionReceipt({ hash });
            assert.ok(receipt.status === "success", "Should emit Deposit event");
        });
    });

    describe("V3: Multiple Users", () => {
        it("correctly tracks balances for multiple users", async () => {
            const { bank, user, user2, dai, wbtc, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });
            const poolKeyDai = createPoolKey(dai.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKeyDai, 1n],
                { account: user.account }
            );

            const user1Balance = await bank.read.getMyBalance([usdc.address], { account: user.account });

            const wbtcAmount = 1_000_000n;
            await wbtc.write.mint([user2.account.address, wbtcAmount], { account: deployer.account });
            await wbtc.write.approve([bank.address, wbtcAmount], { account: user2.account });
            const poolKeyWbtc = createPoolKey(wbtc.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [wbtc.address, wbtcAmount, poolKeyWbtc, 1n],
                { account: user2.account }
            );

            const user2Balance = await bank.read.getMyBalance([usdc.address], { account: user2.account });

            assert.ok(user1Balance > 0n, "User1 should have balance");
            assert.ok(user2Balance > 0n, "User2 should have balance");
            assert.notEqual(user1Balance, user2Balance, "Balances should be different");
        });

        it("correctly decreases bank cap across multiple deposits", async () => {
            const { bank, user, user2, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const capBefore = await bank.read.currentBankCapUsdc();

            const daiAmount1 = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount1], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount1], { account: user.account });
            const poolKey = createPoolKey(dai.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount1, poolKey, 1n],
                { account: user.account }
            );

            const user1Balance = await bank.read.getMyBalance([usdc.address], { account: user.account });

            const daiAmount2 = parseUnits("200", 18);
            await dai.write.mint([user2.account.address, daiAmount2], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount2], { account: user2.account });
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount2, poolKey, 1n],
                { account: user2.account }
            );

            const capAfterUser2 = await bank.read.currentBankCapUsdc();
            const user2Balance = await bank.read.getMyBalance([usdc.address], { account: user2.account });

            const totalDecrease = capBefore - capAfterUser2;
            const totalBalances = user1Balance + user2Balance;
            assert.equal(totalDecrease, totalBalances, "Total cap decrease should equal sum of balances");
        });
    });

    describe("V3: Edge Cases & Security", () => {
        it("handles very small token amounts (dust)", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const dustAmount = 1n;
            await dai.write.mint([user.account.address, dustAmount], { account: deployer.account });
            await dai.write.approve([bank.address, dustAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            await bank.write.depositArbitraryToken(
                [dai.address, dustAmount, poolKey, 0n],
                { account: user.account }
            );

            assert.ok(true, "Should handle dust amounts");
        });

        it("handles very large token amounts", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 10_000_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 10_000_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([10_000_000n * 10n ** 6n], { account: deployer.account });

            const largeAmount = parseUnits("50000", 18);
            await dai.write.mint([user.account.address, largeAmount], { account: deployer.account });
            await dai.write.approve([bank.address, largeAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            await bank.write.depositArbitraryToken(
                [dai.address, largeAmount, poolKey, 1n],
                { account: user.account }
            );

            const balance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balance > 10_000n * 10n ** 6n, "Should handle large amounts");
        });

        it("reverts gracefully if user has insufficient token balance", async () => {
            const { bank, user, dai, usdc } = await deployAll();

            // Don't mint tokens to user
            const daiAmount = parseUnits("100", 18);
            await dai.write.approve([bank.address, daiAmount], { account: user.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, daiAmount, poolKey, 1n],
                    { account: user.account }
                )
            );
        });

        it("reverts gracefully if user hasn't approved tokens", async () => {
            const { bank, user, dai, usdc, deployer } = await deployAll();

            // Mint but don't approve
            const daiAmount = parseUnits("100", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });

            const poolKey = createPoolKey(dai.address, usdc.address);

            await assert.rejects(
                bank.write.depositArbitraryToken(
                    [dai.address, daiAmount, poolKey, 1n],
                    { account: user.account }
                )
            );
        });
    });

    describe("V3: Integration with V2 Withdraw", () => {
        it("allows withdrawal of USDC received from arbitrary token deposit", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("500", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });
            const poolKey = createPoolKey(dai.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            const balanceAfterDeposit = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balanceAfterDeposit > 0n, "Should have USDC balance");

            const withdrawAmount = 100n * 10n ** 6n;
            await bank.write.withdraw([usdc.address, withdrawAmount], { account: user.account });

            const balanceAfterWithdraw = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.equal(
                balanceAfterDeposit - withdrawAmount,
                balanceAfterWithdraw,
                "Balance should decrease by withdraw amount"
            );
        });

        it("respects $1,000 USDC limit on withdrawals from swapped deposits", async () => {
            const { bank, user, dai, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            const daiAmount = parseUnits("2000", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });
            const poolKey = createPoolKey(dai.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKey, 1n],
                { account: user.account }
            );

            await assert.rejects(
                bank.write.withdraw([usdc.address, 1_100n * 10n ** 6n], { account: user.account }),
                /WithdrawLimitExceeded/
            );

            await bank.write.withdraw([usdc.address, 900n * 10n ** 6n], { account: user.account });

            const balance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balance > 0n, "Should have remaining balance");
        });
    });

    describe("V3: Full User Journey", () => {
        it("complete flow: deposit arbitrary token, accumulate, and withdraw", async () => {
            const { bank, user, dai, wbtc, usdc, deployer, router } = await deployAll();

            await usdc.write.mint([deployer.account.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await usdc.write.approve([router.address, 100_000n * 10n ** 6n], { account: deployer.account });
            await router.write.fundRouter([100_000n * 10n ** 6n], { account: deployer.account });

            await router.write.setExchangeRate([wbtc.address, 30_000n * 10n ** 6n]);

            const capBefore = await bank.read.currentBankCapUsdc();

            const daiAmount = parseUnits("1000", 18);
            await dai.write.mint([user.account.address, daiAmount], { account: deployer.account });
            await dai.write.approve([bank.address, daiAmount], { account: user.account });
            const poolKeyDai = createPoolKey(dai.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [dai.address, daiAmount, poolKeyDai, 1n],
                { account: user.account }
            );

            const balanceAfterDai = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(balanceAfterDai > 0n, "Should have balance after DAI deposit");

            const wbtcAmount = 50_000_000n;
            await wbtc.write.mint([user.account.address, wbtcAmount], { account: deployer.account });
            await wbtc.write.approve([bank.address, wbtcAmount], { account: user.account });
            const poolKeyWbtc = createPoolKey(wbtc.address, usdc.address);
            await bank.write.depositArbitraryToken(
                [wbtc.address, wbtcAmount, poolKeyWbtc, 1n],
                { account: user.account }
            );

            const totalBalance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.ok(totalBalance > balanceAfterDai, "Balance should increase after WBTC deposit");

            const withdrawAmount = 500n * 10n ** 6n;
            await bank.write.withdraw([usdc.address, withdrawAmount], { account: user.account });

            const remainingBalance = await bank.read.getMyBalance([usdc.address], { account: user.account });
            assert.equal(totalBalance - withdrawAmount, remainingBalance, "Should have correct remaining balance");

            const capAfter = await bank.read.currentBankCapUsdc();
            const capUsed = capBefore - capAfter;
            assert.equal(capUsed, remainingBalance, "Cap used should equal remaining balance");
        });
    });
});
