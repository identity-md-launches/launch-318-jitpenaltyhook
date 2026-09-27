// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {JITP} from "../src/JITP.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @dev Setup is excluded from forge snapshot. The report additionally extracts individual
/// call frames with --isolate, so assertions, cold/warm reads and setup cannot bias comparisons.
abstract contract GasFeesFixture is HookFixture {
    function setUp() public virtual override {
        super.setUp();
        _seedTwo();
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        _tradeBoth();
    }
}

contract LiquidityGasTest is GasFeesFixture {
    function test_gas_afterAddLiquidity_newPosition() public {
        bytes32 salt = bytes32(uint256(1));
        (, BalanceDelta fees) = _modify(lp, key, int256(uint256(L)), salt);
        assertEq(BalanceDelta.unwrap(fees), 0);
        assertEq(hook.lastAddedBlock(key.toId(), _position(lp, salt)), block.number);
    }

    function test_gas_afterAddLiquidity_withholdBothCurrencies() public {
        vm.roll(block.number + 1);
        (uint256 held0, uint256 held1) = hook.withheldFees(key.toId(), _position(lp, 0));
        (, BalanceDelta fees) = _modify(lp, key, int256(uint256(L)), 0);
        (uint256 now0, uint256 now1) = hook.withheldFees(key.toId(), _position(lp, 0));
        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        assertEq(now0, held0 + uint128(fees.amount0()));
        assertEq(now1, held1 + uint128(fees.amount1()));
        _assertClaims(now0, now1);
    }

    function test_gas_afterRemoveLiquidity_elapsed0_donate() public {
        _remove(0, 2 * L);
    }

    function test_gas_afterRemoveLiquidity_elapsed5_donate() public {
        _remove(5, 2 * L);
    }

    function test_gas_afterRemoveLiquidity_elapsed9_donate() public {
        _remove(9, 2 * L);
    }

    function test_gas_afterRemoveLiquidity_elapsed10_release() public {
        _remove(10, 2 * L);
    }

    function test_gas_afterRemoveLiquidity_elapsed11_release() public {
        _remove(11, 2 * L);
    }

    function test_gas_afterRemoveLiquidity_elapsed5_partial() public {
        _remove(5, L);
    }

    function test_gas_afterRemoveLiquidity_elapsed5_poke() public {
        _remove(5, 0);
    }

    function _remove(uint256 elapsed, uint128 liquidity) private {
        vm.roll(block.number + elapsed);
        (uint256 held0, uint256 held1) = hook.withheldFees(key.toId(), _position(lp, 0));
        BalanceDelta principal = _principal(key, liquidity);
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, -int256(uint256(liquidity)), 0);
        uint256 total0 = held0 + uint128(fees.amount0());
        uint256 total1 = held1 + uint128(fees.amount1());
        assertGt(held0, 0);
        assertGt(held1, 0);
        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        uint256 penalty0 = elapsed < 10 ? (total0 * (10 - elapsed) + 9) / 10 : 0;
        uint256 penalty1 = elapsed < 10 ? (total1 * (10 - elapsed) + 9) / 10 : 0;
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + int256(total0 - penalty0));
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + int256(total1 - penalty1));
        (uint256 donated0, uint256 donated1) = hook.totalDonated(key.toId());
        assertEq(donated0, penalty0);
        assertEq(donated1, penalty1);
        (held0, held1) = hook.withheldFees(key.toId(), _position(lp, 0));
        assertEq(held0 + held1, 0);
        _assertClaims(0, 0);
    }
}

contract FirstWithholdGasTest is HookFixture {
    function setUp() public override {
        super.setUp();
        _seedTwo();
        _tradeBoth();
    }

    function test_gas_afterAddLiquidity_firstWithholdBothCurrencies() public {
        vm.roll(block.number + 1);
        (, BalanceDelta fees) = _modify(lp, key, int256(uint256(L)), 0);
        (uint256 held0, uint256 held1) = hook.withheldFees(key.toId(), _position(lp, 0));
        assertGt(held0, 0);
        assertGt(held1, 0);
        assertEq(held0, uint128(fees.amount0()));
        assertEq(held1, uint128(fees.amount1()));
        _assertClaims(held0, held1);
    }
}

contract NoFeesGasTest is HookFixture {
    function setUp() public override {
        super.setUp();
        _seedTwo();
    }

    function test_gas_afterRemoveLiquidity_zeroFees() public {
        BalanceDelta principal = _principal(key, L);
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, -int256(uint256(L)), 0);
        assertEq(BalanceDelta.unwrap(paid), BalanceDelta.unwrap(principal));
        assertEq(BalanceDelta.unwrap(fees), 0);
        (uint256 donated0, uint256 donated1) = hook.totalDonated(key.toId());
        assertEq(donated0 + donated1, 0);
    }
}

contract WaiverGasTest is HookFixture {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _modify(lp, key, int256(uint256(L)), 0);
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        _tradeBoth();
    }

    function test_gas_afterRemoveLiquidity_lastActiveLP_waive() public {
        (uint256 held0, uint256 held1) = hook.withheldFees(key.toId(), _position(lp, 0));
        BalanceDelta principal = _principal(key, 2 * L);
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, -int256(2 * uint256(L)), 0);
        assertGt(held0 + held1, 0);
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + fees.amount0() + int256(held0));
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + fees.amount1() + int256(held1));
        assertEq(manager.getLiquidity(key.toId()), 0);
        (uint256 donated0, uint256 donated1) = hook.totalDonated(key.toId());
        assertEq(donated0 + donated1, 0);
        _assertClaims(0, 0);
    }
}

contract SwapGasTest is HookFixture {
    PoolKey internal plain;

    function setUp() public override {
        super.setUp();
        plain = key;
        plain.hooks = IHooks(address(0));
        manager.initialize(plain, uint160(1 << 96));
        _modify(lp, key, int256(uint256(L)), 0);
        _modify(lp, plain, int256(uint256(L)), 0);
    }

    function test_gas_swap_buy_withHook() public {
        _checkSwap(key, true);
    }

    function test_gas_swap_buy_withoutHook() public {
        _checkSwap(plain, true);
    }

    function test_gas_swap_sell_withHook() public {
        _checkSwap(key, false);
    }

    function test_gas_swap_sell_withoutHook() public {
        _checkSwap(plain, false);
    }

    function _checkSwap(PoolKey memory pool, bool buy) private {
        BalanceDelta delta = _swap(pool, buy, 0.001 ether);
        assertEq(buy ? delta.amount0() : delta.amount1(), -int128(0.001 ether));
        assertGt(buy ? delta.amount1() : delta.amount0(), 0);
    }
}

contract HookViewsGasTest is GasFeesFixture {
    function test_gas_WINDOW() public view {
        assertEq(hook.WINDOW(), 10);
    }

    function test_gas_poolManager() public view {
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_gas_getHookPermissions() public view {
        Hooks.Permissions memory expected;
        expected.afterAddLiquidity = true;
        expected.afterRemoveLiquidity = true;
        expected.afterAddLiquidityReturnDelta = true;
        expected.afterRemoveLiquidityReturnDelta = true;
        assertEq(abi.encode(hook.getHookPermissions()), abi.encode(expected));
    }

    function test_gas_lastAddedBlock() public view {
        assertEq(hook.lastAddedBlock(key.toId(), _position(lp, 0)), block.number);
    }

    function test_gas_withheldFees() public view {
        (uint256 held0, uint256 held1) = hook.withheldFees(key.toId(), _position(lp, 0));
        assertGt(held0, 0);
        assertGt(held1, 0);
    }

    function test_gas_totalDonated() public view {
        (uint256 donated0, uint256 donated1) = hook.totalDonated(key.toId());
        assertEq(donated0 + donated1, 0);
    }
}

/// @dev Disabled ABI callbacks have no successful user path. These benchmarks explicitly
/// measure HookNotImplemented reverts from the authorized manager, not an enabled callback.
contract DisabledCallbacksGasTest is HookFixture {
    function _expectDisabled() private {
        vm.expectRevert(bytes4(keccak256("HookNotImplemented()")));
        vm.prank(address(manager));
    }

    function test_gas_beforeInitialize_disabled() public {
        _expectDisabled();
        hook.beforeInitialize(address(lp), key, uint160(1 << 96));
    }

    function test_gas_afterInitialize_disabled() public {
        _expectDisabled();
        hook.afterInitialize(address(lp), key, uint160(1 << 96), 0);
    }

    function test_gas_beforeAddLiquidity_disabled() public {
        _expectDisabled();
        hook.beforeAddLiquidity(address(lp), key, ModifyLiquidityParams(LOWER, UPPER, 1, 0), "");
    }

    function test_gas_beforeRemoveLiquidity_disabled() public {
        _expectDisabled();
        hook.beforeRemoveLiquidity(address(lp), key, ModifyLiquidityParams(LOWER, UPPER, -1, 0), "");
    }

    function test_gas_beforeSwap_disabled() public {
        _expectDisabled();
        hook.beforeSwap(address(swapper), key, SwapParams(true, -1, uint160(1 << 95)), "");
    }

    function test_gas_afterSwap_disabled() public {
        _expectDisabled();
        hook.afterSwap(address(swapper), key, SwapParams(true, -1, uint160(1 << 95)), BalanceDelta.wrap(0), "");
    }

    function test_gas_beforeDonate_disabled() public {
        _expectDisabled();
        hook.beforeDonate(address(donor), key, 1, 1, "");
    }

    function test_gas_afterDonate_disabled() public {
        _expectDisabled();
        hook.afterDonate(address(donor), key, 1, 1, "");
    }
}

contract TokenGasTest is Test {
    JITP internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new JITP();
        token.transfer(BOB, 1 ether);
        token.approve(ALICE, 10 ether);
        token.approve(BOB, type(uint256).max);
    }

    function test_gas_name() public view {
        assertEq(token.name(), "JIT Guard");
    }

    function test_gas_symbol() public view {
        assertEq(token.symbol(), "JITP");
    }

    function test_gas_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_gas_totalSupply() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function test_gas_balanceOf() public view {
        assertEq(token.balanceOf(BOB), 1 ether);
    }

    function test_gas_allowance() public view {
        assertEq(token.allowance(address(this), ALICE), 10 ether);
    }

    function test_gas_approve_new() public {
        assertTrue(token.approve(address(0xCAFE), 1 ether));
        assertEq(token.allowance(address(this), address(0xCAFE)), 1 ether);
    }

    function test_gas_approve_update() public {
        assertTrue(token.approve(ALICE, 1 ether));
        assertEq(token.allowance(address(this), ALICE), 1 ether);
    }

    function test_gas_transfer_newRecipient() public {
        assertTrue(token.transfer(ALICE, 1 ether));
        assertEq(token.balanceOf(ALICE), 1 ether);
    }

    function test_gas_transfer_existingRecipient() public {
        assertTrue(token.transfer(BOB, 1 ether));
        assertEq(token.balanceOf(BOB), 2 ether);
    }

    function test_gas_transferFrom_finiteAllowance() public {
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), address(0xCAFE), 1 ether));
        assertEq(token.allowance(address(this), ALICE), 9 ether);
        assertEq(token.balanceOf(address(0xCAFE)), 1 ether);
    }

    function test_gas_transferFrom_infiniteAllowance() public {
        vm.prank(BOB);
        assertTrue(token.transferFrom(address(this), address(0xCAFE), 1 ether));
        assertEq(token.allowance(address(this), BOB), type(uint256).max);
        assertEq(token.balanceOf(address(0xCAFE)), 1 ether);
    }
}
