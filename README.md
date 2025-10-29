# KipuBankV3

A **DeFi-integrated multi-token vault** with **Uniswap V4 swap capabilities**, dual bank capacity pools (ETH and USDC), per-transaction withdrawal limits, and role-based admin recovery using OpenZeppelin `AccessControl`.

## Core Capabilities

- **Deposit ETH** via `depositEth()` (value in `msg.value`)
- **Deposit USDC** via `depositUsdc(amount)` (ERC-20 pull with `safeTransferFrom`)
- **Deposit Any Token** via `depositArbitraryToken()` (swaps to USDC via Uniswap V4)
- **Withdraw ETH or USDC** with USD and ETH limits enforced
- **(Admins)** Inspect arbitrary user balances
- **(Recovery admins)** Adjust user internal balances per-token while preserving bank-cap invariants

---

## Table of Contents
- [Core Capabilities](#core-capabilities)
- [Summary](#summary)
- [Roles](#roles)
- [Contract Details](#contract-details)
  - [Functions](#functions)
  - [Events](#events)
  - [Modifiers](#modifiers)
  - [Custom Errors](#custom-errors)
- [Security Notes](#security-notes)
- [How to Deploy](#how-to-deploy)
- [How to Interact](#how-to-interact)
- [Testing](#testing)
- [Deployed Address](#deployed-address)

---

## Summary
- **Dual bank caps**
  - `MAX_BANK_CAP_ETH` / `currentBankCapEth` (**wei**): ETH pool capacity and remaining headroom
  - `MAX_BANK_CAP_USDC` / `currentBankCapUsdc` (**USDC**): USDC pool capacity and remaining headroom (6-decimal USD units)
- `balances[user][token]`: per-account balances (**wei** for ETH, **token units** for USDC)
- `ETHER_WITHDRAW_LIMIT` (`constant`): max ETH per-transaction (10 ether in wei)
- `USDC_WITHDRAW_LIMIT` (`constant`): global **USDC** withdrawal limit per-tx ($1,000 * 1e6)
- `MAX_ORACLE_DELAY` (`constant`): max Chainlink price staleness (3 hours)
- `DEFAULT_MIN_SWAP_OUTPUT` (`constant`): minimum swap output for slippage protection (1 USDC unit = 0.000001 USDC)
- `MAX_SWAP_DEADLINE` (`constant`): maximum deadline extension for swaps (10 minutes)
- `ethUsdFeed` (`immutable`): Chainlink **ETH/USD** Aggregator for ETH→USD conversion
- `USDC` (`immutable`): USDC token address
- `universalRouter` (`immutable`): Uniswap V4 Universal Router instance
- `permit2` (`immutable`): Permit2 contract for token approvals
- Counters: `countDeposits`, `countWithdraws`

**ETH sentinel:** `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` (EIP-7528)

**Cap invariants:**
- Deposit ETH → `currentBankCapEth -= amountWei`
- Withdraw ETH → `currentBankCapEth += amountWei`
- Deposit USDC → `currentBankCapUsdc -= usdc(amountToken)`
- Withdraw USDC → `currentBankCapUsdc += usdc(amountToken)`
- Swap to USDC → `currentBankCapUsdc -= swapOutput`

---

## Roles
- `DEFAULT_ADMIN_ROLE` (`bytes32(0)`): top-level admin (manages roles; can read any user balance)
- `RECOVERY_ROLE`: allowed to call `setInternalBalance` for per-token balance adjustments

**Bootstrap:** On deployment, `msg.sender` is granted both `DEFAULT_ADMIN_ROLE` and `RECOVERY_ROLE`

**Admin rotation:** Use `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` then `revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin)`

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
  - `BankCapUsdcExceeded(requestedusdc, availableusdc)` when USDC value exceeds `currentBankCapUsdc`

- **`depositArbitraryToken(address tokenIn, uint256 amountIn, PoolKey calldata poolKey, uint256 minAmountOut) external`**
  Deposits any ERC-20 token, swaps it to USDC via Uniswap V4, and credits user balance. Reverts if:
  - `InvalidValue()` when `amountIn == 0`
  - `UnsupportedToken()` when `tokenIn` is ETH or USDC (use dedicated functions)
  - `InvalidSwapParams()` when `poolKey` is invalid
  - `BankCapUsdcExceeded()` when swap output exceeds capacity
  - `SlippageExceeded()` when output is less than `minAmountOut`
  
  **Parameters:**
  - `tokenIn`: Address of token to deposit
  - `amountIn`: Amount of tokens to deposit
  - `poolKey`: Uniswap V4 pool configuration (currency0, currency1, fee, tickSpacing, hooks)
  - `minAmountOut`: Minimum USDC to receive (slippage protection)

- **`withdraw(address token, uint256 amount) external`**
  Withdraws ETH (`token = 0x000…000`) or USDC (`token = USDC`). Reverts if:
  - `InsufficientBalance(requested, available)` when `amount > balance`
  - `WithdrawLimitExceeded(requested, limit)` when **ETH** `amount > ETHER_WITHDRAW_LIMIT`
  - `WithdrawLimitExceeded(requested, limit)` when **USDC** value `> USDC_WITHDRAW_LIMIT` (applies to both ETH (via oracle) and USDC (via decimals))
  - `TransferFailed()` if ETH transfer fails

- **`getBalance(address account, address token) external view onlyAdminRole returns (uint256)`**
  Returns `account` balance for `token` (admin-only).

- **`getMyBalance(address token) external view returns (uint256)`**
  Returns caller’s balance for `token`.

- **`previewToUsdc(address token, uint256 amount) external view returns (uint256)`**
  Converts a token `amount` to **USDC**: ETH via Chainlink; USDC via decimals normalization.

- **`setInternalBalance(address account, address token, uint256 newBalance) external onlyRole(RECOVERY_ROLE)`**
  **Admin Recovery** per-token. Credits consume the matching cap (ETH in wei or USDC in USDC); debits free it. Emits `BalanceAdjusted`.

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
  > `capDelta` is **wei** for ETH; **USDC** for USDC. Positive = cap increased (user debited), negative = cap decreased (user credited).

- `event TokenSwapped(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOut)`
  > Emitted when an arbitrary token is swapped to USDC. `amountIn` is in source token units; `amountOut` is in USDC units.

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
- `SlippageExceeded(uint256 amountOut, uint256 minAmountOut)`
- `InvalidSwapParams()`

---

## Security Notes
- **Checks-Effects-Interactions** pattern followed in `withdraw` and swap functions
- **ETH transfers** use low-level `call` and revert on failure
- **Oracle checks**: reverts if Chainlink price is invalid or stale beyond `MAX_ORACLE_DELAY`
- **Reentrancy protection**: `ReentrancyGuard` applied to `depositArbitraryToken` to prevent reentrancy attacks during swaps
- **Slippage protection**: swap outputs must meet minimum thresholds
- **Pool validation**: ensures PoolKey contains correct token pairs before swapping
- **Direct ETH**: `receive()` reverts to avoid accidental sends (use `depositEth()` instead)
- **Token approvals**: Uses `safeIncreaseAllowance` for safer ERC-20 interactions
- **SafeERC20**: All token transfers use OpenZeppelin's SafeERC20 library

---

## How to Deploy

### Prerequisites
- **MetaMask** (or similar wallet) on a **testnet** (e.g., **Sepolia**)
- **Testnet ETH** (via faucet)
- Access to [Remix IDE](https://remix.ethereum.org)

### Deployment Steps

1. Open [Remix IDE](https://remix.ethereum.org)

2. Create `KipuBank.sol` and paste the contract code

3. **Solidity Compiler**:
   - Version `^0.8.28` or compatible
   - Enable optimization (200 runs recommended)
   - Click **Compile KipuBank.sol**

4. **Deploy & Run**:
   - Environment: *Injected Provider – MetaMask*
   - Network: Select testnet (e.g., Sepolia)
   - Contract: `KipuBank`
   
   **Constructor Parameters:**
   - `_maxBankCapEthWei`: Maximum ETH capacity in wei (e.g., `100000000000000000000` = 100 ether)
   - `_maxBankCapUsdc`: Maximum USDC capacity (e.g., `100000000000` = $100,000 with 6 decimals)
   - `_ethUsdFeed`: Chainlink ETH/USD aggregator address
     - **Sepolia**: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
   - `_usdc`: USDC token address for your network
   - `_universalRouter`: Uniswap V4 Universal Router address
   - `_permit2`: Permit2 contract address
   
   - Click **Deploy** and confirm transaction

5. **Post-Deployment** (optional):
   - Grant roles: `grantRole(DEFAULT_ADMIN_ROLE, <newAdmin>)`
   - Add recovery admins: `grantRecovery(<recoveryAdmin>)`

---

## How to Interact

### Via Remix
- **depositEth**
  Set **VALUE** to e.g. `0.1 ether`, then call `depositEth()`.

- **depositUsdc**
  First, `approve` the contract to spend `amount`, then call `depositUsdc(amount)`.

- **depositArbitraryToken**
  First, `approve` the contract to spend token amount. Then construct the `poolKey` struct with the token pair information, set `minAmountOut` for slippage protection, and call `depositArbitraryToken(tokenAddress, amount, poolKey, minAmountOut)`.

- **withdraw**
  - ETH: `withdraw(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, amountWei)`
  - USDC: `withdraw(<USDC_ADDRESS>, amountTokenUnits)`
  Reverts if USDC value `> USDC_WITHDRAW_LIMIT` ($1,000 * 1e6), or if ETH `amount > ETHER_WITHDRAW_LIMIT`, or if balance is insufficient.

- **getMyBalance / getBalance**
  Read balances (remember: wei for ETH; token units for USDC).

- **setInternalBalance** *(recovery only)*
  Enter `account`, `token`, and `newBalance`.
  Credits consume the matching cap; debits free it.

- **previewToUsdc**
  Enter `token` and `amount` to preview the USDC value (handy to check the USD limit).

---

## Deployed Address

**Network**: Sepolia Testnet

**Contract Address**: 0x2aa8300Db36788100521837763BD466f0c07005A

**Explorer**: [Sepolia Etherscan Link](https://sepolia.etherscan.io/address/0x2aa8300db36788100521837763bd466f0c07005a)

---

## Testing

You can test with **Hardhat + viem**. The examples below assume:

- Hardhat project with `@nomicfoundation/hardhat-viem` plugin enabled.
- Tests written in TypeScript using Node’s test runner (`node:test`) and `node:assert`.

### 1) Install dependencies

```bash
npm install

```

### 2) Run tests

```bash
npx hardhat test
```
