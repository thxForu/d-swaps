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

    event MultiSwapped(address indexed user, bytes path, uint256 amountIn, uint256 amountOut, uint256 feeAmount);

    event SwappedNative(
        address indexed user, address indexed tokenOut, uint256 nativeAmountIn, uint256 amountOut, uint256 feeAmount
    );

    event SwappedToNative(
        address indexed user, address indexed tokenIn, uint256 amountIn, uint256 nativeAmountOut, uint256 feeAmount
    );

    event MultiSwappedNative(address indexed user, bytes path, uint256 amountIn, uint256 amountOut, uint256 feeAmount);

    event FeeUpdated(uint256 newFeePercent);
    event FeeCollectorUpdated(address newFeeCollector);

    function swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut);

    function swapExactInput(bytes memory path, uint256 amountIn, uint256 amountOutMinimum)
        external
        returns (uint256 amountOut);

    function swapExactNativeForTokens(address tokenOut, uint24 fee, uint256 amountOutMin)
        external
        payable
        returns (uint256 amountOut);

    function swapExactTokensForNative(address tokenIn, uint24 fee, uint256 amountIn, uint256 nativeAmountMin)
        external
        returns (uint256 nativeAmountOut);

    function swapExactNativeForTokensMultihop(bytes memory path, uint256 amountOutMinimum)
        external
        payable
        returns (uint256 amountOut);

    function calculateAmountOutMin(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 amountOutMin);

    function calculateAmountOutMinMultihop(bytes memory path, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 amountOutMin);

    function calculateNativeToTokenAmountOutMin(address tokenOut, uint24 fee, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 amountOutMin);

    function calculateTokenToNativeAmountOutMin(address tokenIn, uint24 fee, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 nativeAmountMin);

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
    error DSwaps__InvalidPath();
    error DSwaps__UnsupportedOperation();
    error DSwaps__TransferFailed();
    error DSwaps__RefundFailed();
    error DSwaps__FeeTransferFailed();
    error DSwaps__InvalidPathStart();
}
