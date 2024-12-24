// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDSwaps {
    event Swapped(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount
    );

    event FeeUpdated(uint256 newFeePercent);
    event FeeCollectorUpdated(address newFeeCollector);

    function swap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut);


    function setFeePercent(uint256 _feePercent) external;

    function setFeeCollector(address _feeCollector) external;

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);

    function feePercent() external view returns (uint256);

    function feeCollector() external view returns (address);

    error DSwaps__ZeroAddress();
    error DSwaps__InvalidAmount();
    error DSwaps__SlippageError();
    error DSwaps__SwapFailed();
    error DSwaps__InvalidFee();
    error DSwaps__InsufficientAllowance();
    error DSwaps__PoolNotFound();
    error DSwaps__InvalidFeePercent();
}