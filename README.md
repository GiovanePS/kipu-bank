# KipuBank

A minimal multi-token vault with **dual bank capacity pools** — **ETH (wei)** and **USDC (USD6)** — **per‑tx withdrawal limits** (ETH limit in wei **and** global USD $1,000 limit), and **role‑based Admin Recovery** using OpenZeppelin `AccessControl`.

Here, you can:
- **Deposit ETH** via `depositEth()` (value in `msg.value`).
- **Deposit USDC** via `depositUsdc(amount)` (ERC‑20 pull with `safeTransferFrom`).
- **Withdraw ETH or USDC** with USD and ETH limits enforced.
- **(Admins)** Inspect arbitrary user balances.
- **(Recovery admins)** Adjust a user’s internal balance per‑token while preserving the bank‑cap invariants.

---

## Table of Contents
- [Summary](#summary)
- [Roles](#roles)
- [Contract Details](#contract-details)
  - [Functions](#functions)
  - [Events](#events)
  - [Modifiers](#modifiers)
  - [Custom Errors](#custom-errors)
- [Security Notes](#security-notes)
- [How to Deploy (Remix)](#how-to-deploy-remix)
- [How to Interact](#how-to-interact)
- [Deployed Address](#deployed-address)

---

## Summary
- **Dual bank caps**
  - `MAX_BANK_CAP_ETH` / `currentBankCapEth` (**wei**): ETH pool capacity and remaining headroom.
  - `MAX_BANK_CAP_USDC` / `currentBankCapUsdc` (**USD6**): USDC pool capacity and remaining headroom (6‑dec USD units).
- `balances[user][token]`: per‑account balances (**wei** for ETH (`address(0)`), **token units** for USDC).
- `ETHER_WITHDRAW_LIMIT` (`constant`): max ETH per‑transaction (in wei).
- `USDC_WITHDRAW_LIMIT` (`constant`): global **USD6** withdrawal limit per‑tx (default `$1,000 * 1e6`).
- `MAX_ORACLE_DELAY` (`constant`): max Chainlink price staleness (e.g., `3 hours`).
- `ethUsdFeed` (`immutable`): Chainlink **ETH/USD** Aggregator (used to convert ETH→USD6).
- `USDC` (`immutable`): USDC token address.
- Counters: `countDeposits`, `countWithdraws`.

**ETH sentinel:** `address(0)`.

**Cap invariants:**
- Deposit ETH → `currentBankCapEth -= amountWei`
- Withdraw ETH → `currentBankCapEth += amountWei`
- Deposit USDC → `currentBankCapUsdc -= usd6(amountToken)`
- Withdraw USDC → `currentBankCapUsdc += usd6(amountToken)`

---

## Roles
- `DEFAULT_ADMIN_ROLE` (`bytes32(0)`): top‑level admin (manages roles; can read any user balance).
- `RECOVERY_ROLE`: allowed to call `setInternalBalance` (per‑token adjustments).

**Bootstrap:** On deployment, `msg.sender` is granted both `DEFAULT_ADMIN_ROLE` and `RECOVERY_ROLE`.

**Admin rotation:** `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` then `revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin)`.

---

## Contract Details

### Functions

- **`depositEth() external payable`**
  Deposits native ETH (amount in `msg.value`). Reverts if:
  - `InvalidValue()` when `msg.value == 0`
  - `BankCapEthExceeded(requested, available)` when exceeding `currentBankCapEth`

- **`depositUsdc(uint256 amount) external`**
  Pulls USDC from caller (`safeTransferFrom`). Reverts if:
  - `InvalidValue()` when `amount == 0`
  - `BankCapUsdcExceeded(requestedUsd6, availableUsd6)` when USD6 value exceeds `currentBankCapUsdc`

- **`withdraw(address token, uint256 amount) external`**
  Withdraws ETH (`token = 0x000…000`) or USDC (`token = USDC`). Reverts if:
  - `InsufficientBalance(requested, available)` when `amount > balance`
  - `WithdrawLimitExceeded(requested, limit)` when **ETH** `amount > ETHER_WITHDRAW_LIMIT`
  - `WithdrawLimitExceeded(requested, limit)` when **USD6** value `> USDC_WITHDRAW_LIMIT` (applies to both ETH (via oracle) and USDC (via decimals))
  - `TransferFailed()` if ETH transfer fails

- **`getBalance(address account, address token) external view onlyAdminRole returns (uint256)`**
  Returns `account` balance for `token` (admin‑only).

- **`getMyBalance(address token) external view returns (uint256)`**
  Returns caller’s balance for `token`.

- **`previewToUsdc(address token, uint256 amount) external view returns (uint256)`**
  Converts a token `amount` to **USD6**: ETH via Chainlink; USDC via decimals normalization.

- **`setInternalBalance(address account, address token, uint256 newBalance) external onlyRole(RECOVERY_ROLE)`**
  **Admin Recovery** per‑token. Credits consume the matching cap (ETH in wei or USDC in USD6); debits free it. Emits `BalanceAdjusted`.

- **Role helpers**
  - `grantRecovery(address admin)`
  - `revokeRecovery(address admin)`

> Note: There is **no** `updateOwner`; role management is done via `grantRole` / `revokeRole`.

### Events
- `event Deposit(address indexed account, address indexed token, uint256 amount)`
  > `amount` is **wei for ETH**; **token units for USDC**.

- `event Withdraw(address indexed account, address indexed token, uint256 value)`
  > `value` is **wei for ETH**; **token units for USDC**.

- `event BalanceAdjusted(address indexed admin, address indexed account, address indexed token, uint256 previousBalance, uint256 newBalance, int256 capDelta)`
  > `capDelta` is **wei** for ETH; **USD6** for USDC. Positive = cap increased (user debited), negative = cap decreased (user credited).

### Modifiers
- `onlyAdminRole()` → caller must have `DEFAULT_ADMIN_ROLE`.
- `onlyValidValue(uint256 value)` → reverts with `InvalidValue()` if `value == 0`.

### Custom Errors
- `InvalidValue()`
- `BankCapEthExceeded(uint256 requested, uint256 available)`
- `BankCapUsdcExceeded(uint256 requested, uint256 available)`
- `WithdrawLimitExceeded(uint256 requested, uint256 limit)`
- `InsufficientBalance(uint256 requested, uint256 available)`
- `TransferFailed()`
- `OraclePriceInvalid()`
- `OracleStale(uint256 updatedAt, uint256 nowTs)`
- `UnsupportedToken(address token)`

---

## Security Notes
- **Checks‑Effects‑Interactions** respected in `withdraw`.
- **ETH transfers** use low‑level `call` and revert on failure.
- **Oracle checks**: reverts if Chainlink price is invalid or stale beyond `MAX_ORACLE_DELAY`.
- **Reentrancy**: present design is safe; consider `ReentrancyGuard` if adding token callbacks in the future.
- **Direct ETH**: `receive()` reverts to avoid accidental sends (ETH can still be force‑sent via `SELFDESTRUCT`).

---

## How to Deploy (Remix)

### Prerequisites
- **MetaMask** (or similar) on a **testnet** (e.g., **Sepolia**).
- **Testnet ETH** (via faucet).
- https://remix.ethereum.org

### Step by Step
1. Open Remix → create `KipuBank.sol` and paste the contract.
2. **Solidity Compiler**:
   - Version `^0.8.20` (or higher compatible).
   - Click **Compile KipuBank.sol**.
3. **Deploy & Run**:
   - **Environment**: *Injected Provider – MetaMask*.
   - **Contract**: `KipuBank`.
   - **Constructor args**:
     - `_maxBankCapEthWei` (e.g., `100 ether`)
     - `_maxBankCapUsdc` (USD6, e.g., `$100,000 * 1e6`)
     - `_ethUsdFeed` (Chainlink ETH/USD). **Sepolia example**: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
     - `_usdc` (USDC token address on the same network)
   - Click **Deploy** and confirm.
4. Post‑deploy (optional): grant roles
   - `grantRole(DEFAULT_ADMIN_ROLE, <newAdmin>)`
   - `grantRecovery(<recoveryAdmin>)`

---

## How to Interact

### Via Remix
- **depositEth**
  Set **VALUE** to e.g. `0.1 ether`, then call `depositEth()`.

- **depositUsdc**
  First, `approve` the contract to spend `amount`, then call `depositUsdc(amount)`.

- **withdraw**
  - ETH: `withdraw(0x0000000000000000000000000000000000000000, amountWei)`
  - USDC: `withdraw(<USDC_ADDRESS>, amountTokenUnits)`
  Reverts if USD6 value `> USDC_WITHDRAW_LIMIT` ($1,000 * 1e6), or if ETH `amount > ETHER_WITHDRAW_LIMIT`, or if balance is insufficient.

- **getMyBalance / getBalance**
  Read balances (remember: wei for ETH; token units for USDC).

- **setInternalBalance** *(recovery only)*
  Enter `account`, `token`, and `newBalance`.
  Credits consume the matching cap; debits free it.

- **previewToUsdc**
  Enter `token` and `amount` to preview the USD6 value (handy to check the USD limit).

---

## Deployed Address

> TODO: update after deployment & verification.

- **Network:** Sepolia
- **Address:** `TBD`
- **Explorer:** `TBD`
