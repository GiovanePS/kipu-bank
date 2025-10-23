# KipuBank

A minimal ETH vault smart contract with **bank capacity**, **per-tx withdrawal limit**, and **role-based Admin Recovery**.

Here, you can:
- **Deposit** ETH via `msg.value`.
- **Withdraw** ETH (subject to a per-transaction limit).
- **(Admins)** Inspect arbitrary user balances.
- **(Recovery admins)** Adjust a user’s internal balance while preserving the bank-cap invariant.

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
- `MAX_BANK_CAP` (`immutable`): global capacity defined at deployment (in wei).
- `currentBankCap`: remaining capacity that can still be deposited (in wei).
- `balances[address]`: per-account ETH balances (in wei).
- `ETHER_WITHDRAW_LIMIT` (`constant`): withdrawal limit per transaction (in wei).
- Counters: `countDeposits`, `countWithdraws`.

---

## Roles
- `DEFAULT_ADMIN_ROLE` (`bytes32(0)`): top-level admin.
- `RECOVERY_ROLE`: allowed to call `setInternalBalance`.

**Bootstrap:** On deployment, `msg.sender` is granted both `DEFAULT_ADMIN_ROLE` and `RECOVERY_ROLE`.

**Admin rotation:** Use `grantRole(DEFAULT_ADMIN_ROLE, newAdmin)` then `revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin)`.

---

## Contract Details

### Functions

- **`deposit() external payable onlyValidValue(msg.value)`**
  Deposits `msg.value` into the caller’s balance. Reverts if:
  - `InvalidValue()` when `msg.value == 0`
  - `BankCapExceeded(requested, available)` when exceeding `currentBankCap`

- **`withdraw(uint256 value) external onlyValidValue(value)`**
  Withdraws `value` from the caller’s balance. Reverts if:
  - `InvalidValue()` when `value == 0`
  - `WithdrawLimitExceeded(requested, limit)` when `value > ETHER_WITHDRAW_LIMIT`
  - `InsufficientBalance(requested, available)` when `value > balance`

- **`getBalance() external view returns (uint256)`**
  Returns the caller’s balance (in wei).

- **`getBalance(address account) external view onlyAdminRole returns (uint256)`**
  Returns `account` balance. Restricted to `DEFAULT_ADMIN_ROLE`.

- **`setInternalBalance(address account, uint256 newBalance) external onlyRole(RECOVERY_ROLE)`**
  **Admin Recovery**: sets `account`’s internal ETH balance.
  - If `newBalance > oldBalance`, consumes `currentBankCap` by the delta.
  - If `newBalance < oldBalance`, increases `currentBankCap` by the delta.
  Emits `BalanceAdjusted`.

- **`grantRecovery(address admin) external onlyRole(getRoleAdmin(RECOVERY_ROLE))`**
  Grants `RECOVERY_ROLE` to `admin`.

- **`revokeRecovery(address admin) external onlyRole(getRoleAdmin(RECOVERY_ROLE))`**
  Revokes `RECOVERY_ROLE` from `admin`.

> Note: There is **no** `updateOwner` anymore; role management is done via `grantRole` / `revokeRole`.

### Events
- `event Deposit(address indexed account, uint256 value)`
- `event Withdraw(address indexed account, uint256 value)`
- `event BalanceAdjusted(address indexed admin, address indexed account, uint256 previousBalance, uint256 newBalance, int256 capDelta)`

### Modifiers
- `onlyAdminRole()` → caller must have `DEFAULT_ADMIN_ROLE`.
- `onlyValidValue(uint256 value)` → reverts with `InvalidValue()` if `value == 0`.

### Custom Errors
- `InvalidValue()`
- `BankCapExceeded(uint256 requested, uint256 available)`
- `WithdrawLimitExceeded(uint256 requested, uint256 limit)`
- `InsufficientBalance(uint256 requested, uint256 available)`
- `TransferFailed()`
- `Unauthorized()` *(currently unused)*

---

## Security Notes
- **Checks-Effects-Interactions**: state updated before external calls.
- **ETH transfers** use low-level `call` and revert on failure.
- **Reentrancy**: current flow is safe by design; when features grow, consider `ReentrancyGuard`.
- **Direct ETH**: `receive()` reverts to avoid accidental sends (ETH can still be *forced* via `selfdestruct`; acceptable here).

---

## How to Deploy (Remix)

### Prerequisites
- **MetaMask** (or similar) connected to a **testnet** (e.g., **Sepolia**).
- **Testnet ETH** (via faucet).
- https://remix.ethereum.org

### Step by Step
1. Open Remix → create `KipuBank.sol` and paste the contract.
2. **Solidity Compiler**:
   - Version `^0.8.20` (or higher compatible with your pragma).
   - Click **Compile KipuBank.sol**.
3. **Deploy & Run**:
   - **Environment**: *Injected Provider – MetaMask*.
   - **Account**: one with testnet ETH.
   - **Contract**: `KipuBank`.
   - **Constructor arg**: `_maxBankCap` (wei), e.g. `100 ether`.
   - Click **Deploy** and confirm.
4. Post-deploy (optional): grant roles to other admins
   - `grantRole(DEFAULT_ADMIN_ROLE, <newAdmin>)`
   - `grantRecovery(<recoveryAdmin>)`

---

## How to Interact

### Via Remix
- **deposit**
  In **VALUE**, input e.g. `0.1 ether`, then call `deposit()`.

- **withdraw**
  Call `withdraw(value)`, e.g. `0.05 ether` (or `50000000000000000` in wei).

- **getBalance()**
  Read your own balance (returns wei).

- **getBalance(address)** *(admin only)*
  Enter the target `address` and read (requires `DEFAULT_ADMIN_ROLE`).

- **setInternalBalance** *(recovery only)*
  Enter `account` and `newBalance` (wei).
  - If raising the balance, ensure `currentBankCap >= delta` or it will revert.

---

## Deployed Address

> TODO: update this after finish all requirements.

- **Network:** Sepolia
- **Address:** `TBD`
- **Explorer:** `TBD`

