# Contract interfaces

Compiler-generated ABI arrays are exported at `docs/abi/JITP.json` and
`docs/abi/JITPenaltyHook.json`. Regenerate with `python3 scripts/export_abis.py` after
source or compiler-setting changes. The script requires only Python's standard library and
the locally installed Forge/compiler; it does not use a network API.

## JITP

Constructor: `constructor()` (no arguments). Standard ERC-20 `name`, `symbol`, `decimals`,
`totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, `transferFrom`, `Transfer`
and `Approval` are provided. Amounts are integer base units; 1 JITP = `10^18` units.
Supply is `1000000000000000000000000000` units. Errors follow OpenZeppelin ERC-6093.

## JITPenaltyHook

Constructor: `constructor(IPoolManager poolManager_)` ABI-encoded as one `address`.
All callback entrypoints follow the pinned v4 `IHooks` ABI. Only the two after-liquidity
callbacks are implemented; others revert with `HookNotImplemented` if called by the manager.
All callbacks reject other callers with `NotPoolManager`.

| Read method | Result |
| --- | --- |
| `poolManager()` | Immutable manager address |
| `WINDOW()` | Constant uint256 `10` blocks |
| `getHookPermissions()` | Fourteen booleans, exactly the four documented liquidity flags true |
| `lastAddedBlock(bytes32 poolId, bytes32 positionKey)` | uint256 last positive-add block, initially zero |
| `withheldFees(bytes32 poolId, bytes32 positionKey)` | `(uint256 amount0, uint256 amount1)` pending fees |
| `totalDonated(bytes32 poolId)` | `(uint256 amount0, uint256 amount1)` cumulative penalties actually donated |

Amounts are raw units of the relevant currencies, with native ETH measured in wei. The
hook does not assume ERC-20 decimals. `PoolId` is `keccak256(abi.encode(poolKey))`;
the struct fields are currency0, currency1, fee, tickSpacing and hooks. The position key is
`keccak256(abi.encodePacked(sender, tickLower, tickUpper, salt))`, using int24 tick widths.
`sender` is the address calling `modifyLiquidity`, usually a router or PositionManager.

Every hook event indexes `poolId` and `positionKey`:

| Event | Remaining fields and meaning |
| --- | --- |
| `WindowStarted` | `address sender, int24 tickLower, int24 tickUpper, bytes32 salt, uint256 windowEndsBlock`; emitted on every add |
| `FeesWithheld` | `uint256 amount0, uint256 amount1`; fees newly added to withholding, not the running balance |
| `PenaltyDonated` | `uint256 amount0, uint256 amount1`; actual donation amounts |
| `PenaltyWaived` | `uint256 amount0, uint256 amount1`; penalty that would have applied, but was waived |

For a window display, replay `WindowStarted` from the hook's deployment block, retain the
latest event per `(poolId, positionKey)`, and select `windowEndsBlock > currentBlock`.
Read `withheldFees` and `totalDonated` at the same block. A completed withdrawal does not
erase the last window event: read position liquidity from core/StateView to distinguish a
closed position. Fees can accrue without an event until the position next modifies liquidity.
No `hookData` schema is required by this hook; it ignores those bytes and does not identify
swappers. Router-provided hookData is unauthenticated.
