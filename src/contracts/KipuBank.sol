// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Chainlink Price Feed Interface
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
		uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
	);
    function decimals() external view returns (uint8);
}

/// @title Uniswap V4 Hook Interface
interface IHooks {}

/// @title Permit2 Interface
/// @notice Uniswap's token approval contract
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @title Universal Router Interface
/// @notice Uniswap's universal router for executing swaps
interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

/// @title Currency Type
/// @notice Type for representing currencies in Uniswap V4
type Currency is address;

/// @notice Helper library for Currency type
library CurrencyLibrary {
    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }
}

/// @title Pool Key Structure
/// @notice Identifies a Uniswap V4 pool
struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
}

/// @title Commands Library
/// @notice Command types for Universal Router
library Commands {
    uint256 constant V4_SWAP = 0x10;
    uint256 constant PERMIT2_PERMIT = 0x0a;
    uint256 constant PERMIT2_TRANSFER_FROM = 0x0b;
}

/// @title Actions Library
/// @notice Action types for Uniswap V4 swaps
library Actions {
    uint256 constant SWAP_EXACT_IN = 0x00;
    uint256 constant SWAP_EXACT_OUT = 0x01;
    uint256 constant SWAP_EXACT_IN_SINGLE = 0x00;
}

/// @title My KipuBank
/// @author Giovane Pimentel de Sousa
/// @notice A simple bank contract with deposit and withdraw functionalities
/// @dev I got 1-2-3-4-5-6-7-8 M`s in my bank account
contract KipuBank is AccessControl, ReentrancyGuard {
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

	/// @notice Minimum output amount for swaps (1 unit = 0.000001 USDC)
    /// @dev Acts as slippage protection - can be overridden per swap
    uint256 public constant DEFAULT_MIN_SWAP_OUTPUT = 1;

    /// @notice Maximum deadline extension for swaps (10 minutes)
    uint256 public constant MAX_SWAP_DEADLINE = 10 minutes;

	/// @notice Chainlink ETH/USD aggregator (immutable) and its decimals
    AggregatorV3Interface public immutable ethUsdFeed;

	/// @notice decimals of the feed
    uint8 private immutable feedDecimals;

	/// @notice Uniswap V4 Universal Router
    IUniversalRouter public immutable universalRouter;

    /// @notice Permit2 contract for token approvals
    IPermit2 public immutable permit2;

	/// @notice ETH token
	/// @dev https://eips.ethereum.org/EIPS/eip-7528
	address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

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

    /// @notice Emitted whenever an admin adjusts a user's internal balance.
    event BalanceAdjusted(
        address indexed admin,
        address indexed account,
		address indexed token,
        uint256 previousBalance,
        uint256 newBalance,
        int256 capDelta // +X means cap increased (debited user), -X means cap decreased (credited user)
    );

    /// @notice Emitted when an arbitrary token is swapped to USDC
    event TokenSwapped(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
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

    /// @notice Slippage tolerance exceeded
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    /// @notice Invalid swap parameters
    error InvalidSwapParams();

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
    /// @param _maxBankCapEthWei The maximum capacity of the bank in ETH
    /// @param _maxBankCapUsdc The maximum capacity of the bank in USDC
    /// @param _ethUsdFeed The Chainlink ETH/USD price feed address
    /// @param _usdc The USDC token address
    /// @param _universalRouter The Uniswap V4 Universal Router address
    /// @param _permit2 The Permit2 contract address
    constructor(
        uint256 _maxBankCapEthWei,
        uint256 _maxBankCapUsdc,
        address _ethUsdFeed,
        address _usdc,
        address _universalRouter,
        address _permit2
    ) {
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

        if (_universalRouter == address(0)) {
            revert InvalidValue();
        }

        if (_permit2 == address(0)) {
            revert InvalidValue();
        }

        MAX_BANK_CAP_ETH = _maxBankCapEthWei;
        currentBankCapEth = MAX_BANK_CAP_ETH;

		MAX_BANK_CAP_USDC = _maxBankCapUsdc;
		currentBankCapUsdc = MAX_BANK_CAP_USDC;

		USDC = _usdc;

		ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
		feedDecimals = ethUsdFeed.decimals();

        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);

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

    /// @notice Deposit any ERC20 token supported by Uniswap V4, swap to USDC, and credit user balance
    /// @param tokenIn The address of the token to deposit
    /// @param amountIn The amount of tokenIn to deposit
    /// @param poolKey The Uniswap V4 pool key for swapping tokenIn to USDC
    /// @param minAmountOut Minimum USDC to receive (slippage protection)
    function depositArbitraryToken(
        address tokenIn,
        uint256 amountIn,
        PoolKey calldata poolKey,
        uint256 minAmountOut
    ) external nonReentrant onlyValidValue(amountIn) {
        if (tokenIn == ETH || tokenIn == address(0)) {
            revert UnsupportedToken(tokenIn);
        }
        if (tokenIn == USDC) {
            revert UnsupportedToken(tokenIn);
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 usdcReceived = _swapExactInputSingle(tokenIn, amountIn, poolKey, minAmountOut);
        if (usdcReceived > currentBankCapUsdc) {
            revert BankCapUsdcExceeded({
                requested: usdcReceived,
                available: currentBankCapUsdc
            });
        }

        currentBankCapUsdc -= usdcReceived;
        balances[msg.sender][USDC] += usdcReceived;
        incrementDepositCount();

        emit TokenSwapped(msg.sender, tokenIn, amountIn, usdcReceived);
        emit Deposit(msg.sender, USDC, usdcReceived);
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

    /// @notice Swap exact input amount of tokenIn for USDC using Uniswap V4
    /// @param tokenIn The input token address
    /// @param amountIn The exact amount of input token to swap
    /// @param poolKey The Uniswap V4 pool key
    /// @param minAmountOut Minimum amount of USDC to receive (slippage protection)
    /// @return amountOut The amount of USDC received
    function _swapExactInputSingle(
        address tokenIn,
        uint256 amountIn,
        PoolKey calldata poolKey,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) revert InvalidValue();
        if (tokenIn == address(0)) revert InvalidSwapParams();

        bool validPool = (
            (Currency.unwrap(poolKey.currency0) == tokenIn && Currency.unwrap(poolKey.currency1) == USDC) ||
            (Currency.unwrap(poolKey.currency0) == USDC && Currency.unwrap(poolKey.currency1) == tokenIn)
        );
        if (!validPool) revert InvalidSwapParams();
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        IERC20(tokenIn).safeIncreaseAllowance(address(universalRouter), amountIn);
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == tokenIn;

        bytes memory swapInput = abi.encode(
            address(this),
            amountIn,
            minAmountOut,
            poolKey,
            zeroForOne
        );

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = swapInput;
        uint256 deadline = block.timestamp + MAX_SWAP_DEADLINE;
        universalRouter.execute(commands, inputs, deadline);
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        amountOut = usdcAfter - usdcBefore;

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        return amountOut;
    }

	/// ========================== FALLBACK FUNCTION ===========================
	/// @notice Fallback function to prevent direct ETH transfers
	receive() external payable {
		revert("Direct ETH not allowed; use depositEth()");
	}
}
