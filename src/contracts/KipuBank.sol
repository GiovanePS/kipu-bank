// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title My KipuBank
/// @author Giovane Pimentel de Sousa
/// @notice A simple bank contract with deposit and withdraw functionalities
/// @dev I got 1-2-3-4-5-6-7-8 M`s in my bank account
contract KipuBank is AccessControl {
    /// =========================== STATE VARIABLES ===========================

    /// @notice recovery role constant
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

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

    /// @notice Emitted whenever an admin adjusts a user’s internal balance.
    event BalanceAdjusted(
        address indexed admin,
        address indexed account,
        uint256 previousBalance,
        uint256 newBalance,
        int256 capDelta // +X means cap increased (debited user), -X means cap decreased (credited user)
    );

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

    /// =========================== MODIFIERS ===========================
	modifier onlyAdminRole() {
		_checkRole(DEFAULT_ADMIN_ROLE, msg.sender);
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

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RECOVERY_ROLE, msg.sender);
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
    function getBalance(address account) external view onlyAdminRole returns (uint256) {
        return balances[account];
    }

    /// @notice Function to get the balance of the caller
    function getBalance() external view returns (uint256) {
        return balances[msg.sender];
    }

    function incrementDepositCount() private {
        countDeposits += 1;
    }

    function incrementWithdrawCount() private {
        countWithdraws += 1;
    }

    /// @notice Admin Recovery: set user's internal ETH balance.
    function setInternalBalance(address account, uint256 newBalance) external onlyRole(RECOVERY_ROLE) {
        uint256 oldBalance = balances[account];

        if (newBalance == oldBalance) {
            emit BalanceAdjusted(msg.sender, account, oldBalance, newBalance, 0);
            return;
        }

		if (newBalance > oldBalance) {
			uint256 delta = newBalance - oldBalance;
			if (delta > currentBankCap) {
				revert BankCapExceeded({
					requested: delta,
					available: currentBankCap
				});
			}
			currentBankCap -= delta;
			balances[account] = newBalance;
			emit BalanceAdjusted(msg.sender, account, oldBalance, newBalance, -int256(delta));
		} else {
			uint256 delta = oldBalance - newBalance;
			currentBankCap += delta;
			balances[account] = newBalance;
			emit BalanceAdjusted(msg.sender, account, oldBalance, newBalance, int256(delta));
		}
    }

    /// @notice Grant recovery role to another admin
    function grantRecovery(address admin) external onlyRole(getRoleAdmin(RECOVERY_ROLE)) {
        _grantRole(RECOVERY_ROLE, admin);
    }

    /// @notice Revoke recovery role
    function revokeRecovery(address admin) external onlyRole(getRoleAdmin(RECOVERY_ROLE)) {
        _revokeRole(RECOVERY_ROLE, admin);
    }

	receive() external payable {
		revert("Direct ETH not allowed; use deposit()");
	}
}
