// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {LiquidityRouter} from "./helpers/LiquidityRouter.sol";
import {JITP} from "../src/JITP.sol";
import {JITPenaltyHook} from "../src/JITPenaltyHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract AccountingHandler is Test {
    using StateLibrary for IPoolManager;
    IPoolManager public manager;
    JITPenaltyHook public hook;
    LiquidityRouter public router;
    PoolSwapTest public swapper;
    PoolKey[2] internal pools;
    uint128[4][2] public liquidity;
    uint256 public modifications;
    uint256 public trades;

    constructor(IPoolManager m, JITPenaltyHook h, JITP token, PoolKey memory first, PoolKey memory second) {
        manager = m;
        hook = h;
        pools[0] = first;
        pools[1] = second;
        router = new LiquidityRouter(m);
        swapper = new PoolSwapTest(m);
        token.approve(address(router), type(uint256).max);
        token.approve(address(swapper), type(uint256).max);
    }

    function add(uint8 poolSeed, uint8 saltSeed, uint96 size) external {
        uint256 pool = poolSeed % 2;
        uint256 salt = saltSeed % 4;
        uint128 amount = uint128(bound(size, 1e12, 1 ether));
        liquidity[pool][salt] += amount;
        router.modify{value: 1 ether}(
            pools[pool], ModifyLiquidityParams(-600, 600, int256(uint256(amount)), bytes32(salt))
        );
        ++modifications;
        assertAccounting();
    }

    function removeOrPoke(uint8 poolSeed, uint8 saltSeed, uint128 size, bool poke) external {
        uint256 pool = poolSeed % 2;
        uint256 salt = saltSeed % 4;
        uint128 available = liquidity[pool][salt];
        if (available == 0) return;
        uint128 amount = poke ? 0 : uint128(bound(size, 1, available));
        liquidity[pool][salt] -= amount;
        (BalanceDelta paid,) =
            router.modify(pools[pool], ModifyLiquidityParams(-600, 600, -int256(uint256(amount)), bytes32(salt)));
        assertGe(paid.amount0(), 0);
        assertGe(paid.amount1(), 0);
        ++modifications;
        assertAccounting();
    }

    function swap(uint8 poolSeed, bool buy, uint96 size) external {
        uint256 amount = bound(size, 1e6, 1e14);
        swapper.swap{value: buy ? amount : 0}(
            pools[poolSeed % 2],
            SwapParams(buy, -int256(amount), buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        ++trades;
        assertAccounting();
    }

    function advance(uint8 blocks_) external {
        vm.roll(block.number + blocks_ % 15);
    }

    function assertAccounting() public view {
        uint256 sum0;
        uint256 sum1;
        for (uint256 pool; pool < 2; ++pool) {
            for (uint256 salt; salt < 4; ++salt) {
                bytes32 position = Position.calculatePositionKey(address(router), -600, 600, bytes32(salt));
                (uint256 h0, uint256 h1) = hook.withheldFees(pools[pool].toId(), position);
                sum0 += h0;
                sum1 += h1;
                (uint128 actual,,) = manager.getPositionInfo(pools[pool].toId(), position);
                assertEq(actual, liquidity[pool][salt]);
            }
        }
        assertEq(manager.balanceOf(address(hook), pools[0].currency0.toId()), sum0);
        assertEq(manager.balanceOf(address(hook), pools[0].currency1.toId()), sum1);
    }

    receive() external payable {}
}

contract JITPenaltyHookInvariantTest is HookFixture {
    AccountingHandler internal handler;

    function setUp() public override {
        super.setUp();
        PoolKey memory second = key;
        second.fee = 500;
        manager.initialize(second, uint160(1 << 96));
        // Passive liquidity remains as a donation recipient in both pools.
        _modify(passive, key, int256(uint256(L) * 10), 0);
        _modify(passive, second, int256(uint256(L) * 10), 0);
        vm.roll(block.number + 10);
        handler = new AccountingHandler(manager, hook, token, key, second);
        token.transfer(address(handler), 1_000_000 ether);
        vm.deal(address(handler), 1_000_000 ether);
        // Start with live positions and fees; every campaign exercises nonempty state.
        handler.add(0, 0, uint96(L));
        handler.add(1, 0, uint96(L));
        handler.swap(0, true, 1e14);
        handler.add(0, 0, uint96(L));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.add.selector;
        selectors[1] = handler.removeOrPoke.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.advance.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_claimsEqualAllWithheldAcrossPoolsAndPositions() public view {
        handler.assertAccounting();
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
