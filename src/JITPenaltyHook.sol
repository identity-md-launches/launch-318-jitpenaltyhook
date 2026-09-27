// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Redistributes fees collected within ten blocks of the last liquidity addition.
/// @dev Reimplementation of OpenZeppelin's MIT LiquidityPenaltyHook; see docs/ATTRIBUTION.md.
/// Changes: always withhold on add, round penalties up, waive when active liquidity is zero.
/// All external callbacks inherit BaseHook's onlyPoolManager check. No token transfers or user calls.
contract JITPenaltyHook is BaseHook {
    using StateLibrary for IPoolManager;
    using SafeCast for int128;
    using SafeCast for uint256;

    uint256 public constant WINDOW = 10;

    mapping(PoolId => mapping(bytes32 => uint256)) public lastAddedBlock;
    mapping(PoolId => mapping(bytes32 => BalanceDelta)) private _withheld;

    struct Amounts {
        uint256 amount0;
        uint256 amount1;
    }
    mapping(PoolId => Amounts) public totalDonated;

    event WindowStarted(
        PoolId indexed poolId,
        bytes32 indexed positionKey,
        address sender,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint256 windowEndsBlock
    );
    event FeesWithheld(PoolId indexed poolId, bytes32 indexed positionKey, uint256 amount0, uint256 amount1);
    event PenaltyDonated(PoolId indexed poolId, bytes32 indexed positionKey, uint256 amount0, uint256 amount1);
    event PenaltyWaived(PoolId indexed poolId, bytes32 indexed positionKey, uint256 amount0, uint256 amount1);

    constructor(IPoolManager poolManager_) BaseHook(poolManager_) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.afterAddLiquidity = true;
        p.afterRemoveLiquidity = true;
        p.afterAddLiquidityReturnDelta = true;
        p.afterRemoveLiquidityReturnDelta = true;
    }

    /// @notice Outstanding ERC-6909 backed fees in raw currency units.
    function withheldFees(PoolId poolId, bytes32 positionKey) external view returns (uint256 amount0, uint256 amount1) {
        BalanceDelta fees = _withheld[poolId][positionKey];
        return (fees.amount0().toUint128(), fees.amount1().toUint128());
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        lastAddedBlock[poolId][positionKey] = block.number;
        // The only callee in these callbacks is the immutable manager; no receiver is invoked.
        // forge-lint: disable-next-line(reentrancy-events)
        emit WindowStarted(
            poolId, positionKey, sender, params.tickLower, params.tickUpper, params.salt, block.number + WINDOW
        );

        // Core reports nonnegative earned fees separately from principal. Minting claims debits
        // the hook; returning +feeDelta credits it and subtracts precisely those fees from the LP.
        if (BalanceDelta.unwrap(feeDelta) != 0) {
            _withheld[poolId][positionKey] = _withheld[poolId][positionKey] + feeDelta;
            uint256 amount0 = feeDelta.amount0().toUint128();
            uint256 amount1 = feeDelta.amount1().toUint128();
            if (amount0 != 0) poolManager.mint(address(this), key.currency0.toId(), amount0);
            if (amount1 != 0) poolManager.mint(address(this), key.currency1.toId(), amount1);
            // ERC-6909 mint invokes no receiver callback.
            // forge-lint: disable-next-line(reentrancy-events)
            emit FeesWithheld(poolId, positionKey, amount0, amount1);
        }
        return (this.afterAddLiquidity.selector, feeDelta);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta feeDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, params.tickLower, params.tickUpper, params.salt);
        BalanceDelta held = _withheld[poolId][positionKey];
        _withheld[poolId][positionKey] = BalanceDelta.wrap(0);

        // Burning our claims credits the hook. These credits fund the LP's returned withheld fees
        // and/or the donation. No external recipient is called during the hook's execution.
        if (held.amount0() != 0) poolManager.burn(address(this), key.currency0.toId(), held.amount0().toUint128());
        if (held.amount1() != 0) poolManager.burn(address(this), key.currency1.toId(), held.amount1().toUint128());

        BalanceDelta penalty = _applyPenalty(key, positionKey, feeDelta + held);

        // callerDelta = principal + feeDelta - (penalty - held).
        // Therefore the LP gets principal + total - penalty; principal is never an input to this hook.
        return (this.afterRemoveLiquidity.selector, penalty - held);
    }

    function _applyPenalty(PoolKey calldata key, bytes32 positionKey, BalanceDelta total)
        private
        returns (BalanceDelta)
    {
        PoolId poolId = key.toId();
        BalanceDelta penalty = BalanceDelta.wrap(0);
        uint256 elapsed = block.number - lastAddedBlock[poolId][positionKey];
        if (elapsed < WINDOW && BalanceDelta.unwrap(total) != 0) {
            uint256 amount0 = _penalty(total.amount0().toUint128(), WINDOW - elapsed);
            uint256 amount1 = _penalty(total.amount1().toUint128(), WINDOW - elapsed);
            // Core has already removed the requested liquidity before this callback. Donating with
            // zero remaining active liquidity would revert, so release every fee to the LP instead.
            if (poolManager.getLiquidity(poolId) == 0) {
                // getLiquidity only reads manager storage.
                // forge-lint: disable-next-line(reentrancy-events)
                emit PenaltyWaived(poolId, positionKey, amount0, amount1);
            } else {
                totalDonated[poolId].amount0 += amount0;
                totalDonated[poolId].amount1 += amount1;
                penalty = toBalanceDelta(amount0.toInt128(), amount1.toInt128());
                // Core's return is exactly (-amount0, -amount1); the accounting uses those inputs.
                // forge-lint: disable-next-line(unused-return)
                poolManager.donate(key, amount0, amount1, "");
                // donate has no enabled before/after callbacks on a pool using this hook.
                // forge-lint: disable-next-line(reentrancy-events)
                emit PenaltyDonated(poolId, positionKey, amount0, amount1);
            }
        }

        return penalty;
    }

    function _penalty(uint256 amount, uint256 remaining) private pure returns (uint256) {
        // amount <= int128.max, remaining <= 10, so multiplication and rounding cannot overflow.
        return (amount * remaining + WINDOW - 1) / WINDOW;
    }
}
