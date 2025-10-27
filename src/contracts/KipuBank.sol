// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
		uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
	);
    function decimals() external view returns (uint8);
}

/// @title My KipuBank
/// @author Giovane Pimentel de Sousa
/// @notice A simple bank contract with deposit and withdraw functionalities
/// @dev I got 1-2-3-4-5-6-7-8 M`s in my bank account
contract KipuBank is AccessControl {
	using Math for uint256;
	using SafeERC20 for IERC20;

	/// =========================== ROLES ===========================
    /// @notice recovery role constant
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    /// =========================== STATE VARIABLES ===========================

    /// @notice Maximum value of Ether that can be withdrawn in a single transaction
    uint256 public constant ETHER_WITHDRAW_LIMIT = 10 ether;

	/// @notice Per-withdrawal limit in USDC with 6 decimals
    uint256 public constant USDC_WITHDRAW_LIMIT = 1_000 * 1e6;

    /// @notice oracle data freshness guard
    uint256 public constant MAX_ORACLE_DELAY = 3 hours;

	/// @notice Chainlink ETH/USD aggregator (immutable) and its decimals
    AggregatorV3Interface public immutable ethUsdFeed;

	/// @notice decimals of the feed
    uint8 private immutable feedDecimals;

	/// @notice ETH token
	address public constant ETH = address(0);

	/// @notice USDC token
	address public immutable USDC;

    /// @notice Maximum bank capacity
    uint256 public immutable MAX_BANK_CAP_ETH;

	/// @notice Maximum bank capacity in USDC
	uint256 public immutable MAX_BANK_CAP_USDC;

    /// @notice Current bank capacity
    uint256 public currentBankCapEth;

	/// @notice Current bank capacity in USDC
	uint256 public currentBankCapUsdc;

    /// @notice Total number of deposits made to the bank
    uint256 public countDeposits = 0;

    /// @notice Total number of withdraws made from the bank
    uint256 public countWithdraws = 0;

    /// @notice Per-user per-token balances
    mapping(address => mapping(address => uint256)) private balances;

    /// =========================== EVENTS ===========================

    /// @notice Event emitted when a deposit is made
    /// @param account The address of the account making the deposit
	/// @param token The address of the token deposited (ETH address is 0x0)
    /// @param amount The amount of Ether deposited in wei
    event Deposit(address indexed account, address indexed token, uint256 amount);

    /// @notice Event emitted when a withdraw is made
    /// @param account The address of the account making the withdrawal
	/// @param token The address of the token withdrawn (ETH address is 0x0)
    /// @param value The amount of Ether withdrawn in wei
    event Withdraw(address indexed account, address indexed token, uint256 value);

    /// @notice Emitted whenever an admin adjusts a user’s internal balance.
    event BalanceAdjusted(
        address indexed admin,
        address indexed account,
		address indexed token,
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
    error BankCapEthExceeded(uint256 requested, uint256 available);

	/// @notice Bank capacity exceeded for USDC
	/// @param requested The amount requested to deposit
	/// @param available The available capacity in the bank
	error BankCapUsdcExceeded(uint256 requested, uint256 available);

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

	/// @notice Oracle price is invalid
	error OraclePriceInvalid();

	/// @notice Oracle data is stale
	error OracleStale(uint256 updateAt, uint256 nowTs);

	/// @notice Unsupported token error
	error UnsupportedToken(address token);

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
    /// @param _maxBankCapEthWei The maximum capacity of the bank
    constructor(uint256 _maxBankCapEthWei, uint256 _maxBankCapUsdc, address _ethUsdFeed, address _usdc) {
		if (_maxBankCapEthWei == 0) {
			revert InvalidValue();
		}

		if (_maxBankCapUsdc == 0) {
			revert InvalidValue();
		}

		if (_usdc == address(0)) {
			revert InvalidValue();
		}

		if (_ethUsdFeed == address(0)) {
			revert OraclePriceInvalid();
		}

        MAX_BANK_CAP_ETH = _maxBankCapEthWei;
        currentBankCapEth = MAX_BANK_CAP_ETH;

		MAX_BANK_CAP_USDC = _maxBankCapUsdc;
		currentBankCapUsdc = MAX_BANK_CAP_USDC;

		USDC = _usdc;

		ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
		feedDecimals = ethUsdFeed.decimals();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RECOVERY_ROLE, msg.sender);
    }

    /// @notice The actual deposit ether function
    function depositEth() external payable onlyValidValue(msg.value) {
        if (msg.value > currentBankCapEth) {
            revert BankCapEthExceeded({
                requested: msg.value,
                available: currentBankCapEth
            });
        }

        currentBankCapEth -= msg.value;
        balances[msg.sender][ETH] += msg.value;
        incrementDepositCount();

        emit Deposit(msg.sender, ETH, msg.value);
    }

	/// @notice The actual deposit USDC function
	/// @param amount The amount of USDC to deposit
	function depositUsdc(uint256 amount) external onlyValidValue(amount) {
		IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);

		// usdc has 6 decimals. If it has more, convert to 6 decimals
		uint256 usdc = _stableToUsdc(USDC, amount);
		if (usdc > currentBankCapUsdc) {
			revert BankCapUsdcExceeded({
				requested: usdc,
				available: currentBankCapUsdc
			});
		}

		currentBankCapUsdc -= usdc;
		balances[msg.sender][USDC] += amount;
		incrementDepositCount();

		emit Deposit(msg.sender, USDC, amount);
	}

    /// @notice The actual withdraw function
	/// @param token The address of the token to withdraw (ETH address is 0x0)
    /// @param _value The amount of token to withdraw
    function withdraw(address token, uint256 _value) external onlyValidValue(_value) {
		if (token != ETH && token != USDC) {
			revert UnsupportedToken(token);
		}

		uint256 bal = balances[msg.sender][token];

        if (_value > bal) {
            revert InsufficientBalance({
                requested: _value,
                available: bal
            });
        }

        if (token == ETH && _value > ETHER_WITHDRAW_LIMIT) {
            revert WithdrawLimitExceeded({
                requested: _value,
                limit: ETHER_WITHDRAW_LIMIT
            });
        }

		uint256 usdcAmount = _toUsdc(token, _value);
		if (usdcAmount > USDC_WITHDRAW_LIMIT) {
			revert WithdrawLimitExceeded({
				requested: usdcAmount,
				limit: USDC_WITHDRAW_LIMIT
			});
		}

        balances[msg.sender][token] -= _value;

		if (token == ETH) {
			currentBankCapEth += _value;
		} else {
			currentBankCapUsdc += usdcAmount;
		}
		incrementWithdrawCount();

		if (token == ETH) {
			(bool success, ) = msg.sender.call{value: _value}("");
			if (!success) {
				revert TransferFailed();
			}
		} else {
			IERC20(USDC).safeTransfer(msg.sender, _value);
		}

        emit Withdraw(msg.sender, token, _value);
    }

    /// @notice Function to get the balance of a specific account
    /// @param account The address of the account to check the balance
    function getBalance(address account, address token) external view onlyAdminRole returns (uint256) {
        return balances[account][token];
    }

    /// @notice Function to get the balance of the caller
    function getMyBalance(address token) external view returns (uint256) {
        return balances[msg.sender][token];
    }

	function previewToUsdc(address token, uint256 amount) public view returns (uint256) {
		return _toUsdc(token, amount);
	}

    function incrementDepositCount() private {
        countDeposits += 1;
    }

    function incrementWithdrawCount() private {
        countWithdraws += 1;
    }

    /// @notice Admin Recovery: set user's internal ETH balance.
	/// @param account The address of the account to adjust
	/// @param newBalance The new balance to set for the account
    function setInternalBalance(address account, address token, uint256 newBalance) external onlyRole(RECOVERY_ROLE) {
		if (token != ETH && token != USDC) {
			revert UnsupportedToken(token);
		}

        uint256 oldBalance = balances[account][token];

        if (newBalance == oldBalance) {
            emit BalanceAdjusted(msg.sender, account, token, oldBalance, newBalance, 0);
            return;
        }

		if (newBalance > oldBalance) {
			uint256 delta = newBalance - oldBalance;

			if (token == ETH) {
				if (delta > currentBankCapEth) {
					revert BankCapEthExceeded({
						requested: delta,
						available: currentBankCapEth
					});
				}
				currentBankCapEth -= delta;
				balances[account][ETH] = newBalance;
				emit BalanceAdjusted(msg.sender, account, ETH, oldBalance, newBalance, -int256(delta));
			} else {
				uint256 usdc = _stableToUsdc(USDC, delta);
                if (usdc > currentBankCapUsdc) revert BankCapUsdcExceeded(usdc, currentBankCapUsdc);
                currentBankCapUsdc -= usdc;
                balances[account][USDC] = newBalance;
                emit BalanceAdjusted(msg.sender, account, USDC, oldBalance, newBalance, -int256(usdc));
			}

		} else {
			uint256 delta = oldBalance - newBalance;

			if (token == ETH) {
				currentBankCapEth += delta;
				balances[account][ETH] = newBalance;
				emit BalanceAdjusted(msg.sender, account, ETH, oldBalance, newBalance, int256(delta));
			} else {
				uint256 usdc = _stableToUsdc(USDC, delta);
				currentBankCapUsdc += usdc;
				balances[account][USDC] = newBalance;
				emit BalanceAdjusted(msg.sender, account, USDC, oldBalance, newBalance, int256(usdc));
			}
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

	/// ========================== INTERNAL FUNCTIONS ===========================

	/// @notice Internal function to convert ETH amount to USD with 6 decimals
	/// @param token The address of the token (ETH or stablecoin)
	/// @param amount The amount of ETH in wei
    function _toUsdc(address token, uint256 amount) internal view returns (uint256) {
        return (token == ETH) ? _ethToUsdc(amount) : _stableToUsdc(token, amount);
    }

	/// @notice Internal function to convert wei amount to USDC amount using Chainlink oracle
	/// @param weiAmount The amount in wei to convert
	function _ethToUsdc(uint256 weiAmount) internal view returns (uint256 usdc) {
		(, int256 answer, , uint256 updatedAt, ) = ethUsdFeed.latestRoundData();
		if (answer <= 0) {
			revert OraclePriceInvalid();
		}
		if (MAX_ORACLE_DELAY != 0 && block.timestamp - updatedAt > MAX_ORACLE_DELAY) {
			revert OracleStale({
				updateAt: updatedAt,
				nowTs: block.timestamp
			});
		}

		uint256 price = uint256(answer);
		uint256 scaledPrice = price * 1e6;
		uint256 denom = (10 ** uint256(feedDecimals)) * 1e18;

		usdc = Math.mulDiv(weiAmount, scaledPrice, denom);
	}

	/// @notice Internal function to convert stablecoin amount to USDC amount
	/// @param token The address of the stablecoin token
	/// @param amount The amount of stablecoin to convert
	function _stableToUsdc(address token, uint256 amount) internal view returns (uint256 usdc) {
		uint8 d = IERC20Metadata(token).decimals();
		if (d == 6) {
			return amount;
		} else if (d > 6) {
			return amount / (10 ** (d - 6));
		}

		return amount * (10 ** (6 - d));
	}

	/// ========================== FALLBACK FUNCTION ===========================
	/// @notice Fallback function to prevent direct ETH transfers
	receive() external payable {
		revert("Direct ETH not allowed; use depositEth()");
	}
}
