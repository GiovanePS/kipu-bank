// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title My KipuBank
/// @author Giovane Pimentel de Sousa
/// @notice A simple bank contract with deposit and withdraw functionalities
/// @dev I got 1-2-3-4-5-6-7-8 M`s in my bank account
contract KipuBank {
    /// =========================== STATE VARIABLES ===========================

    /// @notice address of the contract owner
    address private owner;

    /// @notice Maximum value of Ether that can be withdrawn in a single transaction
    uint256 public constant ETHER_WITHDRAW_LIMIT = 10 ether;

    /// @notice Maximum bank capacity
    uint256 public immutable MAX_BANK_CAP;

    /// @notice Current bank capacity
    uint256 public currentBankCap;

    /// @notice Total number of deposits made to the bank
    uint256 public countDeposits = 0;

    /// @notice Total number of withdraws made from the bank
    uint256 public countWithdraws = 0;

    /// @notice Mapping to store the balance of each account
    mapping(address => uint256) private balances;

    /// =========================== EVENTS ===========================

    /// @notice Event emitted when a deposit is made
    /// @param account The address of the account making the deposit
    /// @param value The amount of Ether deposited in wei
    event Deposit(address indexed account, uint256 value);

    /// @notice Event emitted when a withdraw is made
    /// @param account The address of the account making the withdrawal
    /// @param value The amount of Ether withdrawn in wei
    event Withdraw(address indexed account, uint256 value);

    /// =========================== ERRORS ===========================

    /// @notice Invalid value transaction request
    error InvalidValue();

    /// @notice Bank capacity exceeded
    /// @param requested The amount requested to deposit
    /// @param available The available capacity in the bank
    error BankCapExceeded(uint256 requested, uint256 available);

    /// @notice Insufficient balance for withdraw
    /// @param requested The amount requested to withdraw
    /// @param available The available balance of the account
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Withdraw limit exceeded
    /// @param requested The value requested to withdraw
    /// @param limit The maximum withdraw limit
    error WithdrawLimitExceeded(uint256 requested, uint256 limit);

    /// @notice Error for failed transfer
    error TransferFailed();

    /// @notice Unauthorized access
    error Unauthorized();

    /// =========================== MODIFIERS ===========================

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyValidValue(uint256 value) {
        if (value <= 0) {
            revert InvalidValue();
        }
        _;
    }

    /// =========================== FUNCTIONS ===========================

    /// @notice Contract constructor
    /// @param _maxBankCap The maximum capacity of the bank
    constructor(uint256 _maxBankCap) {
        MAX_BANK_CAP = _maxBankCap;
        currentBankCap = MAX_BANK_CAP;
        owner = msg.sender;
    }

    /// @notice The actual deposit function
    function deposit() external payable onlyValidValue(msg.value) {
        if (msg.value > currentBankCap) {
            revert BankCapExceeded({
                requested: msg.value,
                available: currentBankCap
            });
        }

        currentBankCap -= msg.value;
        balances[msg.sender] += msg.value;
        incrementDepositCount();

        emit Deposit(msg.sender, msg.value);
    }

    /// @notice The actual withdraw function
    /// @param _value The amount of Ether to withdraw in wei
    function withdraw(uint256 _value) external onlyValidValue(_value) {
        if (_value > ETHER_WITHDRAW_LIMIT) {
            revert WithdrawLimitExceeded({
                requested: _value,
                limit: ETHER_WITHDRAW_LIMIT
            });
        }

        if (_value > balances[msg.sender]) {
            revert InsufficientBalance({
                requested: _value,
                available: balances[msg.sender]
            });
        }

        balances[msg.sender] -= _value;
        currentBankCap += _value;
        incrementWithdrawCount();

        (bool success, ) = msg.sender.call{value: _value}("");
        if (!success) {
            revert TransferFailed();
        }

        emit Withdraw(msg.sender, _value);
    }

    /// @notice Function to get the balance of a specific account
    /// @param account The address of the account to check the balance
    function getBalance(address account) external view onlyOwner returns (uint256) {
        return balances[account];
    }

    /// @notice Function to get the balance of the caller
    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    /// @notice Function to update the owner of the contract
    /// @param newOwner The address of the new owner
    function updateOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function incrementDepositCount() private {
        countDeposits += 1;
    }

    function incrementWithdrawCount() private {
        countWithdraws += 1;
    }
}
