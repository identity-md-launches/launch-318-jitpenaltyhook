// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {JITPenaltyHook} from "../../src/JITPenaltyHook.sol";
import {JITP} from "../../src/JITP.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {LiquidityRouter} from "./LiquidityRouter.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    IPoolManager internal manager;
    JITPenaltyHook internal hook;
    JITP internal token;
    LiquidityRouter internal lp;
    LiquidityRouter internal passive;
    PoolSwapTest internal swapper;
    PoolDonateTest internal donor;
    PoolKey internal key;
    uint128 internal constant L = 1 ether;
    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;

    function setUp() public virtual {
        vm.roll(100);
        vm.deal(address(this), 1_000_000 ether);
        manager = IPoolManager(address(new PoolManager(address(this))));
        token = new JITP();
        hook = _deployHook();
        lp = new LiquidityRouter(manager);
        passive = new LiquidityRouter(manager);
        swapper = new PoolSwapTest(manager);
        donor = new PoolDonateTest(manager);
        token.approve(address(lp), type(uint256).max);
        token.approve(address(passive), type(uint256).max);
        token.approve(address(swapper), type(uint256).max);
        token.approve(address(donor), type(uint256).max);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, uint160(1 << 96));
    }

    function _deployHook() internal returns (JITPenaltyHook deployed) {
        bytes32 hash = keccak256(abi.encodePacked(type(JITPenaltyHook).creationCode, abi.encode(manager)));
        for (uint256 i; i < 300_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), salt, hash)))));
            if (HookFlags.matches(predicted, HookFlags.JIT_PENALTY)) return new JITPenaltyHook{salt: salt}(manager);
        }
        revert("salt not found");
    }

    function _position(LiquidityRouter router, bytes32 salt) internal pure returns (bytes32) {
        return Position.calculatePositionKey(address(router), LOWER, UPPER, salt);
    }

    function _modify(LiquidityRouter router, PoolKey memory pool, int256 amount, bytes32 salt)
        internal
        returns (BalanceDelta, BalanceDelta)
    {
        return router.modify{value: amount > 0 ? 1 ether : 0}(pool, ModifyLiquidityParams(LOWER, UPPER, amount, salt));
    }

    function _swap(PoolKey memory pool, bool buy, uint256 amount) internal returns (BalanceDelta) {
        return swapper.swap{value: buy ? amount : 0}(
            pool,
            SwapParams(buy, -int256(amount), buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _tradeBoth() internal {
        _swap(key, true, 0.001 ether);
        _swap(key, false, 0.0005 ether);
    }

    function _seedTwo() internal {
        _modify(passive, key, int256(uint256(L)), 0);
        vm.roll(vm.getBlockNumber() + 10);
        _modify(lp, key, int256(uint256(L)), 0);
    }

    /// @dev Independent principal oracle uses only current price, ticks and removed liquidity.
    function _principal(PoolKey memory pool, uint128 liquidity) internal view returns (BalanceDelta) {
        (uint160 price,,,) = manager.getSlot0(pool.toId());
        uint160 lower = TickMath.getSqrtPriceAtTick(LOWER);
        uint160 upper = TickMath.getSqrtPriceAtTick(UPPER);
        uint256 a0 =
            price >= upper ? 0 : SqrtPriceMath.getAmount0Delta(price > lower ? price : lower, upper, liquidity, false);
        uint256 a1 =
            price <= lower ? 0 : SqrtPriceMath.getAmount1Delta(lower, price < upper ? price : upper, liquidity, false);
        return toBalanceDelta(int128(uint128(a0)), int128(uint128(a1)));
    }

    function _assertClaims(uint256 expected0, uint256 expected1) internal view {
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), expected0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), expected1);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    receive() external payable {}
}
