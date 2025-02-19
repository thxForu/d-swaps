// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IDSwaps.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract DSwaps is IDSwaps, Ownable {
    address public immutable FACTORY; // V3 Factory
    address public immutable SWAP_ROUTER; // V3 Swap router
    address public immutable WRAPPED_NATIVE; // Wrapped native token (WDMONAD)

    uint256 public feePercent;
    address public feeCollector;
    uint256 public constant MAX_FEE = 1000;
    uint256 public constant MAX_DEADLINE = 300;

    // Allow contract to receive native tokens during unwrapping
    receive() external payable {
        if (msg.sender != WRAPPED_NATIVE) {
            revert DSwaps__UnsupportedOperation();
        }
    }

    constructor(address initialOwner, address _factory, address _router, address _wrappedNative)
        Ownable(initialOwner)
    {
        if (_factory == address(0) || _router == address(0) || _wrappedNative == address(0)) {
            revert DSwaps__ZeroAddress();
        }

        FACTORY = _factory;
        SWAP_ROUTER = _router;
        WRAPPED_NATIVE = _wrappedNative;
    }

    function swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMin)
        external
        returns (uint256 amountOut)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) {
            revert DSwaps__ZeroAddress();
        }
        if (amountIn == 0) {
            revert DSwaps__InvalidAmount();
        }

        address pool = IUniswapV3Factory(FACTORY).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) {
            revert DSwaps__PoolNotFound();
        }

        if (IERC20(tokenIn).allowance(msg.sender, address(this)) < amountIn) {
            revert DSwaps__InsufficientAllowance();
        }

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 feeAmount = (amountIn * feePercent) / 10000;
        uint256 amountToSwap = amountIn - feeAmount;

        IERC20(tokenIn).transfer(feeCollector, feeAmount);

        IERC20(tokenIn).approve(SWAP_ROUTER, amountToSwap);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: msg.sender,
            deadline: block.timestamp + MAX_DEADLINE,
            amountIn: amountToSwap,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });

        try ISwapRouter(SWAP_ROUTER).exactInputSingle(params) returns (uint256 amount) {
            amountOut = amount;
        } catch {
            revert DSwaps__SwapFailed();
        }

        if (amountOut < amountOutMin) {
            revert DSwaps__SlippageError();
        }

        IERC20(tokenIn).approve(SWAP_ROUTER, 0);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut, feeAmount);
        return amountOut;
    }

    function swapExactInput(bytes memory path, uint256 amountIn, uint256 amountOutMinimum)
        external
        returns (uint256 amountOut)
    {
        // Minimum path length (20 + 3 + 20 bytes) [tokenIn (20 bytes)] [fee (3 bytes)] [tokenOut (20 bytes)]
        if (path.length < 43) {
            revert DSwaps__InvalidPath();
        }
        if (amountIn == 0) {
            revert DSwaps__InvalidAmount();
        }

        // Extract the first token from the path
        address tokenIn;
        assembly {
            tokenIn := mload(add(path, 20))
        }

        if (IERC20(tokenIn).allowance(msg.sender, address(this)) < amountIn) {
            revert DSwaps__InsufficientAllowance();
        }

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 feeAmount = (amountIn * feePercent) / 10000;
        uint256 amountToSwap = amountIn - feeAmount;

        IERC20(tokenIn).transfer(feeCollector, feeAmount);

        IERC20(tokenIn).approve(SWAP_ROUTER, amountToSwap);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp + MAX_DEADLINE,
            amountIn: amountToSwap,
            amountOutMinimum: amountOutMinimum
        });

        try ISwapRouter(SWAP_ROUTER).exactInput(params) returns (uint256 amount) {
            amountOut = amount;
        } catch {
            revert DSwaps__SwapFailed();
        }

        if (amountOut < amountOutMinimum) {
            revert DSwaps__SlippageError();
        }

        IERC20(tokenIn).approve(SWAP_ROUTER, 0);

        emit MultiSwapped(msg.sender, path, amountIn, amountOut, feeAmount);
        return amountOut;
    }

    /**
     * @notice Swaps native tokens (DMonad) for ERC20 tokens
     * @param tokenOut The token to receive
     * @param fee The pool fee
     * @param amountOutMin The minimum amount of tokens to receive
     * @return amountOut The amount of tokens received
     */
    function swapExactNativeForTokens(address tokenOut, uint24 fee, uint256 amountOutMin)
        external
        payable
        returns (uint256 amountOut)
    {
        if (msg.value == 0) {
            revert DSwaps__InvalidAmount();
        }
        if (tokenOut == address(0)) {
            revert DSwaps__ZeroAddress();
        }

        uint256 feeAmount = (msg.value * feePercent) / 10000;
        uint256 amountToSwap = msg.value - feeAmount;

        // Handle fee in native token
        if (feeAmount > 0 && feeCollector != address(0)) {
            (bool success,) = feeCollector.call{value: feeAmount}("");
            if (!success) {
                revert DSwaps__FeeTransferFailed();
            }
        }

        // Wrap native token
        IWETH(WRAPPED_NATIVE).deposit{value: amountToSwap}();

        address pool = IUniswapV3Factory(FACTORY).getPool(WRAPPED_NATIVE, tokenOut, fee);
        if (pool == address(0)) {
            revert DSwaps__PoolNotFound();
        }

        // Approve router to spend wrapped tokens
        IERC20(WRAPPED_NATIVE).approve(SWAP_ROUTER, amountToSwap);

        // Swap wrapped tokens for tokenOut
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WRAPPED_NATIVE,
            tokenOut: tokenOut,
            fee: fee,
            recipient: msg.sender,
            deadline: block.timestamp + MAX_DEADLINE,
            amountIn: amountToSwap,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });

        try ISwapRouter(SWAP_ROUTER).exactInputSingle(params) returns (uint256 amount) {
            amountOut = amount;
        } catch {
            // If swap fails, unwrap tokens and return to sender
            // TODO: check and remove becouse of revert
            IWETH(WRAPPED_NATIVE).withdraw(amountToSwap);
            (bool success,) = msg.sender.call{value: amountToSwap}("");
            if (!success) {
                revert DSwaps__RefundFailed();
            }
            revert DSwaps__SwapFailed();
        }

        if (amountOut < amountOutMin) {
            revert DSwaps__SlippageError();
        }

        // Reset approval
        IERC20(WRAPPED_NATIVE).approve(SWAP_ROUTER, 0);

        emit SwappedNative(msg.sender, tokenOut, msg.value, amountOut, feeAmount);
        return amountOut;
    }

    /**
     * @notice Swaps tokens for native tokens (DMonad)
     * @param tokenIn The token to swap
     * @param fee The pool fee
     * @param amountIn The amount of tokens to swap
     * @param nativeAmountMin The minimum amount of native tokens to receive
     * @return nativeAmountOut The amount of native tokens received
     */
    function swapExactTokensForNative(address tokenIn, uint24 fee, uint256 amountIn, uint256 nativeAmountMin)
        external
        returns (uint256 nativeAmountOut)
    {
        if (tokenIn == address(0) || amountIn == 0) {
            revert DSwaps__InvalidAmount();
        }

        address pool = IUniswapV3Factory(FACTORY).getPool(tokenIn, WRAPPED_NATIVE, fee);
        if (pool == address(0)) {
            revert DSwaps__PoolNotFound();
        }

        if (IERC20(tokenIn).allowance(msg.sender, address(this)) < amountIn) {
            revert DSwaps__InsufficientAllowance();
        }

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 feeAmount = (amountIn * feePercent) / 10000;
        uint256 amountToSwap = amountIn - feeAmount;

        if (feeAmount > 0 && feeCollector != address(0)) {
            IERC20(tokenIn).transfer(feeCollector, feeAmount);
        }

        IERC20(tokenIn).approve(SWAP_ROUTER, amountToSwap);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: WRAPPED_NATIVE,
            fee: fee,
            recipient: address(this), // Send to this contract to unwrap
            deadline: block.timestamp + MAX_DEADLINE,
            amountIn: amountToSwap,
            amountOutMinimum: nativeAmountMin,
            sqrtPriceLimitX96: 0
        });

        uint256 wrappedAmount;
        try ISwapRouter(SWAP_ROUTER).exactInputSingle(params) returns (uint256 amount) {
            wrappedAmount = amount;
        } catch {
            // If swap fails, return tokens to sender
            IERC20(tokenIn).transfer(msg.sender, amountToSwap);
            revert DSwaps__SwapFailed();
        }

        if (wrappedAmount < nativeAmountMin) {
            // If slippage too high, return wrapped tokens to sender 
            // TODO: check and remove becouse of revert
            IERC20(WRAPPED_NATIVE).transfer(msg.sender, wrappedAmount);
            revert DSwaps__SlippageError();
        }

        // Unwrap native tokens
        IWETH(WRAPPED_NATIVE).withdraw(wrappedAmount);

        // Send native tokens to user
        (bool success,) = msg.sender.call{value: wrappedAmount}("");
        if (!success) {
            revert DSwaps__TransferFailed();
        }

        // Reset approval
        IERC20(tokenIn).approve(SWAP_ROUTER, 0);

        emit SwappedToNative(msg.sender, tokenIn, amountIn, wrappedAmount, feeAmount);
        return wrappedAmount;
    }

    /**
     * @notice Swaps native tokens for tokens using a multi-hop path
     * @param path The swap path (must start with wrapped native token)
     * @param amountOutMinimum The minimum amount of output tokens
     * @return amountOut The amount of tokens received
     */
    function swapExactNativeForTokensMultihop(bytes memory path, uint256 amountOutMinimum)
        external
        payable
        returns (uint256 amountOut)
    {
        if (msg.value == 0) {
            revert DSwaps__InvalidAmount();
        }
        if (path.length < 43) {
            revert DSwaps__InvalidPath();
        }

        address firstToken;
        assembly {
            firstToken := mload(add(path, 20))
        }
        if (firstToken != WRAPPED_NATIVE) {
            revert DSwaps__InvalidPathStart();
        }

        uint256 feeAmount = (msg.value * feePercent) / 10000;
        uint256 amountToSwap = msg.value - feeAmount;

        if (feeAmount > 0 && feeCollector != address(0)) {
            (bool success,) = feeCollector.call{value: feeAmount}("");
            if (!success) {
                revert DSwaps__FeeTransferFailed();
            }
        }

        // Wrap native tokens
        IWETH(WRAPPED_NATIVE).deposit{value: amountToSwap}();

        IERC20(WRAPPED_NATIVE).approve(SWAP_ROUTER, amountToSwap);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: msg.sender,
            deadline: block.timestamp + MAX_DEADLINE,
            amountIn: amountToSwap,
            amountOutMinimum: amountOutMinimum
        });

        try ISwapRouter(SWAP_ROUTER).exactInput(params) returns (uint256 amount) {
            amountOut = amount;
        } catch {
            // If swap fails, unwrap tokens and return to sender
            // TODO: check and remove becouse of revert
            IWETH(WRAPPED_NATIVE).withdraw(amountToSwap);
            (bool success,) = msg.sender.call{value: amountToSwap}("");
            if (!success) {
                revert DSwaps__RefundFailed();
            }
            revert DSwaps__SwapFailed();
        }

        if (amountOut < amountOutMinimum) {
            revert DSwaps__SlippageError();
        }

        IERC20(WRAPPED_NATIVE).approve(SWAP_ROUTER, 0);

        emit MultiSwappedNative(msg.sender, path, msg.value, amountOut, feeAmount);
        return amountOut;
    }

    /**
     * @notice Calculates native token to tokens output amount
     * @param tokenOut Output token address
     * @param fee Pool fee
     * @param amountIn Native token input amount
     * @param slippageBps Slippage tolerance in basis points
     * @return amountOutMin Minimum output amount
     */
    function calculateNativeToTokenAmountOutMin(address tokenOut, uint24 fee, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 amountOutMin)
    {
        return calculateAmountOutMin(WRAPPED_NATIVE, tokenOut, fee, amountIn, slippageBps);
    }

    /**
     * @notice Calculates tokens to native token output amount
     * @param tokenIn Input token address
     * @param fee Pool fee
     * @param amountIn Token input amount
     * @param slippageBps Slippage tolerance in basis points
     * @return nativeAmountMin Minimum native token output amount
     */
    function calculateTokenToNativeAmountOutMin(address tokenIn, uint24 fee, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 nativeAmountMin)
    {
        return calculateAmountOutMin(tokenIn, WRAPPED_NATIVE, fee, amountIn, slippageBps);
    }

    function calculateAmountOutMin(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint24 slippageBps)
        public
        view
        returns (uint256 amountOutMin)
    {
        address pool = IUniswapV3Factory(FACTORY).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) {
            revert DSwaps__PoolNotFound();
        }

        uint256 feeAmount = (amountIn * feePercent) / 10000;
        uint256 amountAfterFee = amountIn - feeAmount;

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        uint256 amountOut;
        if (tokenIn < tokenOut) {
            amountOut = _calculateAmount1Out(amountAfterFee, sqrtPriceX96);
        } else {
            amountOut = _calculateAmount0Out(amountAfterFee, sqrtPriceX96);
        }

        amountOutMin = (amountOut * (10000 - slippageBps)) / 10000;
    }

    function _calculateAmount1Out(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return (amount0 * price) / (1 << 192);
    }

    function _calculateAmount0Out(uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return (amount1 * (1 << 192)) / price;
    }

    /*
        NOT WORKING. Switching to use Quoter.  
    */
    function calculateAmountOutMinMultihop(bytes memory path, uint256 amountIn, uint24 slippageBps)
        external
        view
        returns (uint256 amountOutMin)
    {
        // Minimum path length check (20 + 3 + 20 bytes for single hop)
        if (path.length < 43) {
            revert DSwaps__InvalidPath();
        }

        uint256 feeAmount = (amountIn * feePercent) / 10000;
        uint256 amountAfterFee = amountIn - feeAmount;

        address currentToken;
        uint24 currentFee;
        address nextToken;
        uint256 currentAmountIn = amountAfterFee;

        // Process path in steps of 23 bytes (20 bytes address + 3 bytes fee)
        for (uint256 i = 0; i < path.length - 20; i += 23) {
            assembly {
                currentToken := mload(add(add(path, 32), i))
                currentFee := mload(add(add(path, 52), i))
                nextToken := mload(add(add(path, 55), i))
            }

            currentFee = uint24((currentFee >> 232) & 0xFFFFFF);

            address pool = IUniswapV3Factory(FACTORY).getPool(currentToken, nextToken, currentFee);
            if (pool == address(0)) {
                revert DSwaps__PoolNotFound();
            }

            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

            if (currentToken < nextToken) {
                currentAmountIn = _calculateAmount1Out(currentAmountIn, sqrtPriceX96);
            } else {
                currentAmountIn = _calculateAmount0Out(currentAmountIn, sqrtPriceX96);
            }
        }

        amountOutMin = (currentAmountIn * (10000 - slippageBps)) / 10000;
    }

    function setFeePercent(uint256 _feePercent) external override onlyOwner {
        if (_feePercent > MAX_FEE) {
            revert DSwaps__InvalidFeePercent();
        }
        feePercent = _feePercent;
        emit FeeUpdated(_feePercent);
    }

    function setFeeCollector(address _feeCollector) external override onlyOwner {
        if (_feeCollector == address(0)) {
            revert DSwaps__ZeroAddress();
        }
        feeCollector = _feeCollector;
        emit FeeCollectorUpdated(_feeCollector);
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return IUniswapV3Factory(FACTORY).getPool(tokenA, tokenB, fee);
    }
}
