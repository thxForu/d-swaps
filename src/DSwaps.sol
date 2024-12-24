// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IDSwaps.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DSwaps is IDSwaps, Ownable {
    address public immutable FACTORY; // V3 Factory
    address public immutable SWAP_ROUTER; // V3 Swap router
    
    uint256 public override feePercent;
    address public override feeCollector;
    uint256 public constant MAX_FEE = 1000;
    uint256 public constant MAX_DEADLINE = 300;

    event Swapped(
        address indexed user, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    constructor(address initialOwner, address _factory, address _router) Ownable(initialOwner) {
        if (_factory == address(0) || _router == address(0)) {
            revert DSwaps__ZeroAddress();
        }

        FACTORY = _factory;
        SWAP_ROUTER = _router;
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
        if (fee != 100 && fee != 500 && fee != 3000 && fee != 10000) {
            revert DSwaps__InvalidFee();
        }

        address pool = IUniswapV3Factory(FACTORY).getPool(tokenIn, tokenOut, fee);
        if (pool == address(0)) {
            revert DSwaps__PoolNotFound();
        }

        if (IERC20(tokenIn).allowance(msg.sender, address(this)) < amountIn) {
            revert DSwaps__InsufficientAllowance();
        }

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: msg.sender,
            deadline: block.timestamp + MAX_DEADLINE,
            amountIn: amountIn,
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

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);

        return amountOut;
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
