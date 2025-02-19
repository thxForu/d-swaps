// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/DSwaps.sol";
import "../src/interfaces/IDSwaps.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// TODO: add tests for native swap.
contract DSwapsTest is Test {
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    uint24 constant POOL_FEE = 3000;

    DSwaps public dswaps;
    address public owner;
    address public user;
    address public feeCollector;

    event FeeUpdated(uint256 newFeePercent);
    event FeeCollectorUpdated(address newFeeCollector);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        owner = makeAddr("owner");
        user = makeAddr("user");
        feeCollector = makeAddr("feeCollector");

        dswaps = new DSwaps(owner, FACTORY, ROUTER, WETH);

        vm.startPrank(owner);
        dswaps.setFeeCollector(feeCollector);
        dswaps.setFeePercent(100); // 1% fee
        vm.stopPrank();

        vm.startPrank(user);
        deal(WETH, user, 10 ether);
        deal(USDC, user, 20_000 * 1e6);

        IERC20(WETH).approve(address(dswaps), type(uint256).max);
        IERC20(USDC).approve(address(dswaps), type(uint256).max);
        vm.stopPrank();
    }

    function test_initialSetup() public view {
        assertEq(dswaps.FACTORY(), FACTORY);
        assertEq(dswaps.SWAP_ROUTER(), ROUTER);
        assertEq(dswaps.owner(), owner);
        assertEq(dswaps.feeCollector(), feeCollector);
        assertEq(dswaps.feePercent(), 100);
    }

    function test_swap_exactInput() public {
        uint256 amountIn = 1 ether;
        uint256 minOut = 1500 * 1e6; // min 1500 USDC

        uint256 expectedFee = (amountIn * dswaps.feePercent()) / 10000;

        // setup before swap
        vm.startPrank(user);
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 feeCollectorWethBefore = IERC20(WETH).balanceOf(dswaps.feeCollector());

        // do swap
        uint256 amountOut = dswaps.swap(WETH, USDC, POOL_FEE, amountIn, minOut);

        // check balances after swap
        assertEq(IERC20(WETH).balanceOf(user), wethBefore - amountIn, "incorrect WETH balance");
        assertGt(amountOut, minOut, "output less than minimum");
        assertEq(IERC20(USDC).balanceOf(user), usdcBefore + amountOut, "incorrect USDC balance");

        assertEq(
            IERC20(WETH).balanceOf(dswaps.feeCollector()),
            feeCollectorWethBefore + expectedFee,
            "fee collector did not receive correct fee"
        );

        assertGt(amountOut, minOut, "output less than minimum");

        assertEq(IERC20(WETH).balanceOf(address(dswaps)), 0, "contract should not hold any WETH");
        assertEq(IERC20(USDC).balanceOf(address(dswaps)), 0, "contract should not hold any USDC");

        vm.stopPrank();
    }

    function test_RevertWhen_SwapFailed_ReturnsTokens() public {
        vm.prank(user);

        vm.expectRevert();
        dswaps.swap(WETH, makeAddr("invalidToken"), 3000, 1 ether, 0);
        assertEq(IERC20(WETH).balanceOf(user), 10 ether);
    }

    function test_swap_exactInput_multihop() public {
        uint256 amountIn = 1 ether;
        uint256 minOut = 1500 * 1e6; // min 1500 USDT

        // Create path for WETH -> USDC -> USDT
        bytes memory path = abi.encodePacked(WETH, uint24(3000), USDC, uint24(500), USDT);

        vm.startPrank(user);
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdtBefore = IERC20(USDT).balanceOf(user);

        // Do multi-hop swap
        uint256 amountOut = dswaps.swapExactInput(path, amountIn, minOut);

        // Check balances
        assertEq(IERC20(WETH).balanceOf(user), wethBefore - amountIn, "incorrect WETH balance");
        assertGt(amountOut, minOut, "output less than minimum");
        assertEq(IERC20(USDT).balanceOf(user), usdtBefore + amountOut, "incorrect USDT balance");
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidPath() public {
        bytes memory invalidPath = abi.encodePacked(WETH);

        vm.prank(user);
        vm.expectRevert();
        dswaps.swapExactInput(invalidPath, 1 ether, 0);
    }

    function test_RevertWhen_MultihopSlippageTooHigh() public {
        bytes memory path = abi.encodePacked(WETH, uint24(3000), USDC, uint24(500), makeAddr("randomToken"));

        vm.prank(user);
        vm.expectRevert();
        dswaps.swapExactInput(path, 1 ether, type(uint256).max);
    }

    function test_SetFeePercent() public {
        uint256 newFee = 50; // 0.5%

        vm.prank(owner);
        dswaps.setFeePercent(newFee);
        assertEq(dswaps.feePercent(), newFee);

        // revert if not owner
        vm.prank(user);
        vm.expectRevert();
        dswaps.setFeePercent(75);

        // revert if fee too high
        vm.prank(owner);
        vm.expectRevert();
        dswaps.setFeePercent(1001);
    }

    function test_setFeeCollector() public {
        address newCollector = makeAddr("newCollector");

        vm.prank(owner);
        dswaps.setFeeCollector(newCollector);
        assertEq(dswaps.feeCollector(), newCollector);

        // revert if zero address
        vm.prank(owner);
        vm.expectRevert();
        dswaps.setFeeCollector(address(0));

        // revert if not owner
        vm.prank(user);
        vm.expectRevert();
        dswaps.setFeeCollector(address(1));
    }

    function testFail_SetFeePercent_NonOwner() public {
        vm.prank(user);
        dswaps.setFeePercent(50);
    }

    function testFail_SetFeeCollector_NonOwner() public {
        vm.prank(user);
        dswaps.setFeeCollector(makeAddr("newCollector"));
    }

    function test_RevertWhen_ExceedMaxFee() public {
        vm.prank(dswaps.owner());
        vm.expectRevert();
        dswaps.setFeePercent(1001);
    }

    function test_RevertWhen_ZeroAddressFeeCollector() public {
        vm.prank(dswaps.owner());
        vm.expectRevert();
        dswaps.setFeeCollector(address(0));
    }

    function test_getPool() public view {
        address pool = dswaps.getPool(WETH, USDC, POOL_FEE);
        assertTrue(pool != address(0));
    }

    function test_RevertWhen_PoolNotFound() public {
        address randomToken = makeAddr("randomToken");

        vm.prank(user);
        vm.expectRevert();
        dswaps.swap(randomToken, WETH, 3000, 1 ether, 0);
    }

    function test_RevertWhen_SlippageTooHigh() public {
        uint256 amountIn = 1 ether;
        uint256 unrealisticMinOut = 1_000_000 * 1e6;

        vm.prank(user);
        vm.expectRevert();
        dswaps.swap(WETH, USDC, 3000, amountIn, unrealisticMinOut);
    }

    function test_calculateAmountOutMin() public {
        uint256 amountIn = 1 ether;
        uint24 slippageBps = 100;

        uint256 amountOutMin = dswaps.calculateAmountOutMin(WETH, USDC, POOL_FEE, amountIn, slippageBps);

        vm.startPrank(user);
        uint256 amountOut = dswaps.swap(WETH, USDC, POOL_FEE, amountIn, amountOutMin);
        vm.stopPrank();

        assertGt(amountOut, amountOutMin, "swap output less than calculated minimum");
    }

    function test_RevertWhen_InvalidSlippage() public {
        uint24 invalidSlippage = 10001;

        vm.expectRevert();
        dswaps.calculateAmountOutMin(WETH, USDC, POOL_FEE, 1 ether, invalidSlippage);
    }

    function test_calculateAmountOutMin_WithFee() public {
        uint256 amountIn = 1 ether;
        uint24 slippageBps = 100;

        uint256 amountOutWithFee = dswaps.calculateAmountOutMin(WETH, USDC, POOL_FEE, amountIn, slippageBps);

        vm.startPrank(owner);
        dswaps.setFeePercent(0);
        vm.stopPrank();

        uint256 amountOutNoFee = dswaps.calculateAmountOutMin(WETH, USDC, POOL_FEE, amountIn, slippageBps);

        assertLt(amountOutWithFee, amountOutNoFee, "fee not affecting output amount");
    }
}
