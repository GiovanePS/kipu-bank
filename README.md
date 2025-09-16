# KipuBank

A simple Smart Contract for ETH storage.

Here, you can:
- **Deposit** an amount of ETH passed via `msg.value`.
- **Withdraw** an amount of ETH. There is a maximum withdrawal limit per transaction (`ETHER_WITHDRAW_LIMIT`).

## Table of Contents
- [Summary](#summary)
- [Contract Details](#contract-details)
- [How to Deploy (Remix)](#deploy-remix)
- [How to Interact](#how-to-interact)
- [Deployed Address](#deployed-address)

## Summary
- `MAX_BANK_CAP` (`immutable`): global cap defined at deployment.
- `currentBankCap`: remaining capacity, i.e., how much can still be deposited.
- `balances[address]`: individual balance of each account that deposits.
- `ETHER_WITHDRAW_LIMIT` (`constant`): withdrawal limit per transaction.
- Counters: `countDeposits`, `countWithdrawals`.

## Contract Details

### Functions
- `deposit() external payable onlyValidValue(msg.value)`
  Deposits `msg.value` into your balance. Reverts with:
  - `InvalidValue()` if `msg.value <= 0`
  - `BankCapExceeded(requested, available)` if exceeding `currentBankCap`

- `withdraw(uint256 value) external onlyValidValue(value)`
  Withdraws `value` from your balance. Reverts with:
  - `InvalidValue()` if `value <= 0`
  - `WithdrawLimitExceeded(requested, limit)` if `value > ETHER_WITHDRAW_LIMIT`
  - `InsufficientBalance(requested, available)` if `value > balance`

- `getBalance(address account) external onlyOwner view returns (uint256)`
  Returns the balance of `account`.

- `getBalance() external view returns (uint256)`
  Returns the balance of `msg.sender`.

- `updateOwner(address newOwner) external onlyOwner`
  Updates the `owner`. Reverts with `Unauthorized()` if `msg.sender != owner`.

- `countTransactions() private view returns (uint256)`
  Returns the sum of `countDeposits + countWithdrawals`.

- `essentialFunction() private`
  Does nothing. :)

### Events
- `event Deposit(address indexed account, uint256 value)`
- `event Withdraw(address indexed account, uint256 value)`

### Modifiers
- `onlyOwner()`
  Restricts function access to the `owner`.

- `onlyValidValue(uint256 value)`
  Reverts with `InvalidValue()` if `value <= 0`.

### Custom Errors
`InvalidValue()`,
`BankCapExceeded(uint256 requested, uint256 available)`,
`WithdrawLimitExceeded(uint256 requested, uint256 limit)`,
`InsufficientBalance(uint256 requested, uint256 available)`,
`TransferFailed()`,
`Unauthorized()`.

## How to Deploy (Remix)

### Prerequisites
- **MetaMask** (or another wallet) connected to a **testnet** (e.g., **Sepolia**).
- Some **testnet ETH** (use a faucet).
- Access: https://remix.ethereum.org

### Step by Step
1. Open Remix, go to **File Explorer** → **Create New File** → `KipuBank.sol` and paste the contract.
2. In the **Solidity Compiler** tab:
   - Version: any above **0.8.20** (same as the contract pragma).
   - Click **Compile KipuBank.sol**.
3. In the **Deploy & Run Transactions** tab:
   - **Environment**: *Injected Provider – MetaMask* (uses your wallet's network).
   - **Account**: select the account with testnet ETH.
   - **Contract**: `KipuBank – contracts/KipuBank.sol`.
   - Click **Deploy** and confirm in the wallet.
4. Copy the **contract address** after deployment (shown in Remix panel and on the explorer).

## How to Interact

### Via Remix
- **deposit**
  At the top of the **Deploy & Run Transactions** tab, in the **VALUE** field, enter for example `0.1 ether` and call `deposit()`.

- **withdraw**
  Call `withdraw(value)`. Example: `0.05 ether` (or `50000000000000000` wei).

- **getBalance**
  Click to read; returns your balance in **wei**.

- **getBalance(address account)**
  Enter the `address` and click to read (only the `owner` can call).

- **updateOwner**
  Enter `newOwner` (address) and execute (only the current `owner` can call).

## Deployed Address

- **Network:** Sepolia
- **Address:** `0x33902A5646Fdd4e1f1580FeD429CFE022ECF049D`
- **Explorer:** `https://sepolia.etherscan.io/tx/0xa0c969b9dfbd120231e9055f1744ad7daacc35adc35874212b573796cee4d6a3`
