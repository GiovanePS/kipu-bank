// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Mock Permit2 Contract
/// @notice Simplified mock for testing token approvals
contract MockPermit2 {
    // Track approvals: owner => token => spender => amount
    mapping(address => mapping(address => mapping(address => uint256))) public allowance;

    event Approval(
        address indexed owner,
        address indexed token,
        address indexed spender,
        uint256 amount,
        uint48 expiration
    );

    event TransferFrom(
        address indexed from,
        address indexed to,
        uint256 amount,
        address indexed token
    );

    /// @notice Approve a spender for a specific token
    /// @param token The token address
    /// @param spender The spender address
    /// @param amount The approval amount
    /// @param expiration The expiration timestamp
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external {
        allowance[msg.sender][token][spender] = amount;
        emit Approval(msg.sender, token, spender, amount, expiration);
    }

    /// @notice Transfer tokens from one address to another
    /// @param from The source address
    /// @param to The destination address
    /// @param amount The amount to transfer
    /// @param token The token address
    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external {
        require(
            allowance[from][token][msg.sender] >= amount,
            "MockPermit2: insufficient allowance"
        );

        allowance[from][token][msg.sender] -= amount;

        // Actually transfer the tokens
        require(
            IERC20(token).transferFrom(from, to, amount),
            "MockPermit2: transfer failed"
        );

        emit TransferFrom(from, to, amount, token);
    }

    /// @notice Get the allowance for a specific owner/token/spender
    function getAllowance(
        address owner,
        address token,
        address spender
    ) external view returns (uint256) {
        return allowance[owner][token][spender];
    }
}
