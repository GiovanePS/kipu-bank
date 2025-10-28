// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title Mock Universal Router
/// @notice Simplified mock for testing Uniswap V4 swaps
/// @dev This mock simulates swaps with a fixed exchange rate for testing
contract MockUniversalRouter {
    address public immutable USDC;

    // Mock exchange rates (tokenIn address => USDC per token, scaled by 1e6)
    mapping(address => uint256) public exchangeRates;

    // Default rate: 1:1 for same decimals
    uint256 public constant DEFAULT_RATE = 1e6;

    event SwapExecuted(
        address indexed recipient,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address _usdc) {
        USDC = _usdc;
    }

    /// @notice Set a custom exchange rate for a token
    /// @param token The token address
    /// @param rate The exchange rate (USDC per token, scaled by 1e6)
    /// @dev Example: If 1 DAI = 0.99 USDC, rate = 0.99e6 = 990000
    function setExchangeRate(address token, uint256 rate) external {
        exchangeRates[token] = rate;
    }

    /// @notice Struct for PoolKey (matching KipuBank)
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @notice Execute swap commands
    /// @param commands The encoded commands
    /// @param inputs The encoded inputs for each command
    /// @param deadline The deadline for the swap
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable {
        require(block.timestamp <= deadline, "MockUniversalRouter: expired");
        require(commands.length > 0, "MockUniversalRouter: no commands");

        uint8 command = uint8(commands[0]);
        require(command == 0x10, "MockUniversalRouter: unsupported command");

        (
            address recipient,
            uint256 amountIn,
            uint256 minAmountOut,
            PoolKey memory poolKey,
            bool zeroForOne
        ) = abi.decode(inputs[0], (address, uint256, uint256, PoolKey, bool));

        address tokenIn = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        address tokenOut = zeroForOne ? poolKey.currency1 : poolKey.currency0;

        require(tokenOut == USDC, "MockUniversalRouter: output must be USDC");
        uint256 amountOut = _calculateSwapOutput(tokenIn, amountIn);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(USDC).transfer(recipient, amountOut);

        emit SwapExecuted(recipient, tokenIn, amountIn, amountOut);
    }

    /// @notice Calculate swap output based on exchange rate
    /// @param tokenIn The input token
    /// @param amountIn The input amount
    /// @return amountOut The output amount in USDC
    function _calculateSwapOutput(
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256 amountOut) {
        uint256 rate = exchangeRates[tokenIn];
        if (rate == 0) {
            rate = DEFAULT_RATE;
        }

        uint8 decimalsIn = IERC20Metadata(tokenIn).decimals();
        uint8 decimalsOut = 6; // USDC decimals

        // Convert amountIn to USDC decimals and apply rate (rate is scaled by 1e6)
        if (decimalsIn >= decimalsOut) {
            amountOut = (amountIn * rate) / (10 ** (decimalsIn - decimalsOut)) / 1e6;
        } else {
            amountOut = (amountIn * rate * 10 ** (decimalsOut - decimalsIn)) / 1e6;
        }

        return amountOut;
    }

    /// @notice Fund the router with USDC for testing
    /// @param amount The amount of USDC to add
    function fundRouter(uint256 amount) external {
        IERC20(USDC).transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Get USDC balance of router
    function getUsdcBalance() external view returns (uint256) {
        return IERC20(USDC).balanceOf(address(this));
    }
}
