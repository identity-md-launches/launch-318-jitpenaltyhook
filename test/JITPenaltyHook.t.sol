// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {LiquidityRouter} from "./helpers/LiquidityRouter.sol";
import {JITPenaltyHook} from "../src/JITPenaltyHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";

contract JITPenaltyHookTest is HookFixture {
    using StateLibrary for IPoolManager;

    function test_permissionsAndMinedAddress() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        Hooks.Permissions memory expected;
        expected.afterAddLiquidity = true;
        expected.afterRemoveLiquidity = true;
        expected.afterAddLiquidityReturnDelta = true;
        expected.afterRemoveLiquidityReturnDelta = true;
        assertEq(abi.encode(p), abi.encode(expected));
        assertEq(HookFlags.flagsOf(address(hook)), 0x0503);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.WINDOW(), 10);
    }

    function test_wrongAddressBitsRefuseDeployment() public {
        vm.expectRevert();
        new JITPenaltyHook(manager);
    }

    function test_bothReturnDeltaCallbacksRejectUnauthorizedCaller() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams(LOWER, UPPER, 1, 0);
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.afterAddLiquidity(address(lp), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(bytes4(keccak256("NotPoolManager()")));
        hook.afterRemoveLiquidity(address(lp), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        _assertClaims(0, 0);
    }

    function test_removeAtElapsed0() public {
        _checkSplit(0);
    }

    function test_removeAtElapsed5() public {
        _checkSplit(5);
    }

    function test_removeAtElapsed9() public {
        _checkSplit(9);
    }

    function test_removeAtElapsed10() public {
        _checkSplit(10);
    }

    function testFuzz_feeSplitAndPrincipal(uint8 elapsed) public {
        _checkSplit(bound(elapsed, 0, 30));
    }

    function _checkSplit(uint256 elapsed) internal {
        _seedTwo();
        _tradeBoth();
        vm.roll(block.number + elapsed);
        // Collect the passive LP's swap fees first. It is already outside its window.
        _modify(passive, key, 0, 0);
        BalanceDelta principal = _principal(key, L);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, -int256(uint256(L)), 0);
        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        uint256 p0 = _ceilPenalty(uint128(fees.amount0()), elapsed);
        uint256 p1 = _ceilPenalty(uint128(fees.amount1()), elapsed);
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + fees.amount0() - int256(p0));
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + fees.amount1() - int256(p1));
        assertEq(address(this).balance - ethBefore, uint128(paid.amount0()));
        assertEq(token.balanceOf(address(this)) - tokenBefore, uint128(paid.amount1()));
        (uint256 d0, uint256 d1) = hook.totalDonated(key.toId());
        assertEq(d0, p0);
        assertEq(d1, p1);
        (BalanceDelta collected,) = _modify(passive, key, 0, 0);
        // v4 fee-growth accounting may leave one unit of rounding dust in the manager.
        assertApproxEqAbs(uint128(collected.amount0()), p0, p0 == 0 ? 0 : 1);
        assertApproxEqAbs(uint128(collected.amount1()), p1, p1 == 0 ? 0 : 1);
        _assertClaims(0, 0);
    }

    function test_withholdOnAddEvenAfterMaturityAndResetWindow() public {
        _seedTwo();
        _tradeBoth();
        vm.roll(block.number + 20);
        bytes32 position = _position(lp, 0);
        vm.expectEmit(true, true, false, true, address(hook));
        emit JITPenaltyHook.WindowStarted(key.toId(), position, address(lp), LOWER, UPPER, 0, block.number + 10);
        (, BalanceDelta fees) = _modify(lp, key, int256(uint256(L)), 0);
        assertGt(fees.amount0(), 0);
        assertGt(fees.amount1(), 0);
        (uint256 held0, uint256 held1) = hook.withheldFees(key.toId(), position);
        assertEq(held0, uint128(fees.amount0()));
        assertEq(held1, uint128(fees.amount1()));
        assertEq(hook.lastAddedBlock(key.toId(), position), block.number);
        _assertClaims(held0, held1);
        vm.roll(block.number + 10);
        BalanceDelta principal = _principal(key, 2 * L);
        (BalanceDelta paid,) = _modify(lp, key, -int256(2 * uint256(L)), 0);
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + int256(held0));
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + int256(held1));
        (held0, held1) = hook.withheldFees(key.toId(), position);
        assertEq(held0 + held1, 0);
        _assertClaims(0, 0);
    }

    function test_withheldPlusNewFeesAreBothPenalized() public {
        _seedTwo();
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        (uint256 h0, uint256 h1) = hook.withheldFees(key.toId(), _position(lp, 0));
        _tradeBoth();
        vm.roll(block.number + 5);
        BalanceDelta principal = _principal(key, 2 * L);
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, -int256(2 * uint256(L)), 0);
        uint256 total0 = h0 + uint128(fees.amount0());
        uint256 total1 = h1 + uint128(fees.amount1());
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + int256(total0 - _ceilPenalty(total0, 5)));
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + int256(total1 - _ceilPenalty(total1, 5)));
        _assertClaims(0, 0);
    }

    function test_lastActiveLiquidityRemovalWaivesIncludingHeldFees() public {
        _modify(lp, key, int256(uint256(L)), 0);
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        (uint256 h0, uint256 h1) = hook.withheldFees(key.toId(), _position(lp, 0));
        assertGt(h0 + h1, 0);
        vm.expectEmit(true, true, false, true, address(hook));
        emit JITPenaltyHook.PenaltyWaived(key.toId(), _position(lp, 0), h0, h1);
        BalanceDelta principal = _principal(key, 2 * L);
        (BalanceDelta paid,) = _modify(lp, key, -int256(2 * uint256(L)), 0);
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + int256(h0));
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + int256(h1));
        assertEq(manager.getLiquidity(key.toId()), 0);
        (uint256 d0, uint256 d1) = hook.totalDonated(key.toId());
        assertEq(d0 + d1, 0);
        _assertClaims(0, 0);
    }

    function test_lastActiveLiquidityRemovalWaivesNewFees() public {
        _modify(lp, key, int256(uint256(L)), 0);
        _tradeBoth();
        BalanceDelta principal = _principal(key, L);
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, -int256(uint256(L)), 0);
        assertGt(fees.amount0() + fees.amount1(), 0);
        assertEq(int256(paid.amount0()), int256(principal.amount0()) + fees.amount0());
        assertEq(int256(paid.amount1()), int256(principal.amount1()) + fees.amount1());
    }

    function test_zeroFeesNoDonationEvenWithZeroLiquidity() public {
        _modify(lp, key, int256(uint256(L)), 0);
        vm.recordLogs();
        BalanceDelta principal = _principal(key, L);
        (BalanceDelta paid,) = _modify(lp, key, -int256(uint256(L)), 0);
        assertEq(BalanceDelta.unwrap(paid), BalanceDelta.unwrap(principal));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 donate = keccak256("Donate(bytes32,address,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != donate);
            assertTrue(logs[i].emitter != address(hook));
        }
        _assertClaims(0, 0);
    }

    function test_pokeAndPartialRemovalDoNotBypassPenaltyOrResetWindow() public {
        _seedTwo();
        _tradeBoth();
        uint256 added = hook.lastAddedBlock(key.toId(), _position(lp, 0));
        vm.roll(block.number + 5);
        (BalanceDelta paid, BalanceDelta fees) = _modify(lp, key, 0, 0);
        assertEq(uint128(paid.amount0()), uint128(fees.amount0()) - _ceilPenalty(uint128(fees.amount0()), 5));
        assertEq(uint128(paid.amount1()), uint128(fees.amount1()) - _ceilPenalty(uint128(fees.amount1()), 5));
        // A poke keeps liquidity in range, so it can accrue a share of its own donation.
        BalanceDelta principal = _principal(key, L / 2);
        (paid, fees) = _modify(lp, key, -int256(uint256(L / 2)), 0);
        assertEq(
            int256(paid.amount0()),
            int256(principal.amount0()) + fees.amount0() - int256(_ceilPenalty(uint128(fees.amount0()), 5))
        );
        assertEq(
            int256(paid.amount1()),
            int256(principal.amount1()) + fees.amount1() - int256(_ceilPenalty(uint128(fees.amount1()), 5))
        );
        assertEq(hook.lastAddedBlock(key.toId(), _position(lp, 0)), added);
    }

    function test_newSaltCannotReleaseOldWithheldFees() public {
        _seedTwo();
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        (uint256 h0, uint256 h1) = hook.withheldFees(key.toId(), _position(lp, 0));
        bytes32 other = bytes32(uint256(1));
        _modify(lp, key, int256(uint256(L)), other);
        _modify(lp, key, -int256(uint256(L)), other);
        (uint256 now0, uint256 now1) = hook.withheldFees(key.toId(), _position(lp, 0));
        assertEq(now0, h0);
        assertEq(now1, h1);
        _assertClaims(h0, h1);
    }

    function test_sharedRouterSameSaltResetsAnotherUsersWindow() public {
        _seedTwo();
        uint256 old = block.number;
        vm.roll(old + 9);
        address otherUser = address(0xBEEF);
        vm.deal(otherUser, 1 ether);
        token.transfer(otherUser, 1 ether);
        vm.startPrank(otherUser);
        token.approve(address(lp), type(uint256).max);
        lp.modify{value: 0.1 ether}(key, ModifyLiquidityParams(LOWER, UPPER, int256(uint256(L)), 0));
        vm.stopPrank();
        assertEq(hook.lastAddedBlock(key.toId(), _position(lp, 0)), old + 9);
    }

    function test_swapsIdenticalToPoolWithoutHook() public {
        PoolKey memory plain = key;
        plain.hooks = IHooks(address(0));
        manager.initialize(plain, uint160(1 << 96));
        _modify(lp, plain, int256(uint256(L)), 0);
        _modify(lp, key, int256(uint256(L)), 0);
        assertEq(
            BalanceDelta.unwrap(_swap(key, true, 0.001 ether)), BalanceDelta.unwrap(_swap(plain, true, 0.001 ether))
        );
        assertEq(
            BalanceDelta.unwrap(_swap(key, false, 0.0005 ether)), BalanceDelta.unwrap(_swap(plain, false, 0.0005 ether))
        );
        (uint160 hookedPrice,,, uint24 hookedFee) = manager.getSlot0(key.toId());
        (uint160 plainPrice,,, uint24 plainFee) = manager.getSlot0(plain.toId());
        assertEq(hookedPrice, plainPrice);
        assertEq(hookedFee, plainFee);
    }

    function test_launchRehearsalFirstBuyIntoEthlessPoolThenSell() public {
        // At tick zero, [-600,-60] is all currency1 (JITP), with no active liquidity yet.
        (BalanceDelta seed,) = lp.modify(key, ModifyLiquidityParams(-600, -60, int256(uint256(L)), 0));
        assertEq(seed.amount0(), 0);
        assertLt(seed.amount1(), 0);
        assertEq(address(manager).balance, 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
        BalanceDelta buy = _swap(key, true, 0.001 ether);
        assertEq(buy.amount0(), -int128(0.001 ether));
        assertGt(buy.amount1(), 0);
        assertGt(address(manager).balance, 0);
        BalanceDelta sell = _swap(key, false, uint128(buy.amount1()) / 2);
        assertGt(sell.amount0(), 0);
        assertLt(sell.amount1(), 0);
        lp.modify(key, ModifyLiquidityParams(-600, -60, -int256(uint256(L)), 0));
        _assertClaims(0, 0);
    }

    function test_invalidRemovalAndFailedSettlementRollBackHookState() public {
        _seedTwo();
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        (uint256 h0, uint256 h1) = hook.withheldFees(key.toId(), _position(lp, 0));
        vm.expectRevert();
        _modify(lp, key, -int256(3 * uint256(L)), 0);
        vm.roll(block.number + 1);
        uint256 added = hook.lastAddedBlock(key.toId(), _position(lp, 0));
        token.approve(address(lp), 0);
        vm.expectRevert();
        _modify(lp, key, int256(uint256(L)), 0);
        assertEq(hook.lastAddedBlock(key.toId(), _position(lp, 0)), added);
        _assertClaims(h0, h1);
        token.approve(address(lp), type(uint256).max);
        _modify(lp, key, -int256(2 * uint256(L)), 0);
        vm.expectRevert();
        _modify(lp, key, -int256(uint256(L)), 0);
    }

    function test_twoPoolsKeepIndependentWindowsAndClaims() public {
        PoolKey memory second = key;
        second.fee = 500;
        manager.initialize(second, uint160(1 << 96));
        _modify(lp, key, int256(uint256(L)), 0);
        _tradeBoth();
        _modify(lp, key, int256(uint256(L)), 0);
        (uint256 h0, uint256 h1) = hook.withheldFees(key.toId(), _position(lp, 0));
        vm.roll(block.number + 7);
        _modify(lp, second, int256(uint256(L)), 0);
        _swap(second, true, 0.001 ether);
        _modify(lp, second, int256(uint256(L)), 0);
        (uint256 s0, uint256 s1) = hook.withheldFees(second.toId(), _position(lp, 0));
        _assertClaims(h0 + s0, h1 + s1);
        assertEq(
            hook.lastAddedBlock(second.toId(), _position(lp, 0)), hook.lastAddedBlock(key.toId(), _position(lp, 0)) + 7
        );
        _modify(lp, second, -int256(2 * uint256(L)), 0);
        _assertClaims(h0, h1);
    }

    function test_roundsPositiveDustUpAtNineBlocks() public {
        _seedTwo();
        // Donation of four units gives this LP two units: ceil(2 * 1/10) = 1.
        donor.donate{value: 4}(key, 4, 4, "");
        vm.roll(block.number + 9);
        (, BalanceDelta fees) = _modify(lp, key, -int256(uint256(L)), 0);
        assertGt(fees.amount0(), 0);
        assertLt(fees.amount0(), 10);
        (uint256 d0, uint256 d1) = hook.totalDonated(key.toId());
        assertEq(d0, 1);
        assertEq(d1, 1);
    }

    function _ceilPenalty(uint256 amount, uint256 elapsed) private pure returns (uint256) {
        if (elapsed >= 10) return 0;
        uint256 product = amount * (10 - elapsed);
        return product / 10 + (product % 10 == 0 ? 0 : 1);
    }
}
