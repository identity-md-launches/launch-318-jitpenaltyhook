# JIT Guard — JITP and JITPenaltyHook

Contract-stage implementation for the approved Sepolia `univ4_hook` launch, site label
`lab-jit-penalty-hook`. Solidity **0.8.26**, Cancun EVM, optimizer 200 runs,
`bytecode_hash = "none"`. All Solidity dependencies are ordinary vendored files in `lib/`;
no network, submodules, FFI, filesystem cheatcodes, or environment variables are needed by the tests.

```sh
forge build
forge test
forge fmt --check
python3 scripts/export_abis.py
```

`src/JITP.sol` is an OpenZeppelin ERC-20 named **JIT Guard**, symbol **JITP**, 18 decimals.
Its argument-free constructor mints exactly **1,000,000,000 JITP** (`10^27` base units) to
`msg.sender`. There is no subsequent mint, burn entrypoint, owner, tax, pause, or upgrade.

`src/JITPenaltyHook.sol` extends the vendored v4-periphery `BaseHook`. Its sole constructor
argument is `IPoolManager`. It has no owner, admin, upgrade, configurable rate, or hook fee.
Every external callback inherits the PoolManager caller check. Its four permissions are
`afterAddLiquidity`, `afterRemoveLiquidity`, `afterAddLiquidityReturnDelta`, and
`afterRemoveLiquidityReturnDelta`, giving an address mask of **0x0503 (1283)**.

## Fee lifecycle

Accounting is isolated by `PoolId` and
`Position.calculatePositionKey(sender, tickLower, tickUpper, salt)`. Any pool may attach
the hook; neither the token nor a particular pool is hardcoded.

1. Each positive liquidity addition resets the position's window to `block.number + 10`.
   All fees auto-collected by that addition are withheld as the hook's PoolManager ERC-6909
   claims, including additions after an earlier window expired.
2. A negative liquidity change **or zero-delta fee poke** releases the position's withheld
   claims and considers them together with newly earned fees. At elapsed blocks `e < 10`,
   each currency's penalty is `ceil(totalFees * (10 - e) / 10)`. At `e >= 10`, it is zero.
3. The penalty is donated to the pool's remaining in-range liquidity in that callback.
   If active liquidity is zero, the penalty is waived and every fee is paid to the LP.
   Zero total fees cause neither a donation nor a waiver event.
4. Withheld state is cleared on each removal/poke. Principal is unaffected. Principal here
   means the amounts due for the removed liquidity at the current AMM price, which can
   differ from the originally deposited currency amounts after trades.

The hook never transfers underlying currencies to a user. It mints/burns claims and returns
deltas; the user's liquidity router settles or takes the resulting PoolManager balance.
There is no separate `claim()` or withdrawal administrator. A removal cannot fail because
there is no donation recipient; ordinary core validation, settlement, token failures and
v4 arithmetic limits still apply.

## Validation delivered

Tests deploy an actual `v4-core` PoolManager and CREATE2-mine the production hook without
overriding address validation. They cover the 0/5/9/10-block splits, independently calculated
principal, passive LP donation collection, dust rounding, accumulated withholding, fee pokes,
partial removals, salt/pool isolation, window resets, callback access, transaction rollback,
ERC-20 success/failure paths and forbidden runtime opcodes.

The launch rehearsal seeds JITP-only liquidity below the opening price, checks that the
manager holds no ETH, executes the first exact-input buy, sells back, and removes liquidity.
An equivalent unhooked pool produces exactly the same swap deltas and price. “Same swap
cost” means the input/output amounts and LP fee; identical EVM gas usage is not promised.

The stateful invariant campaign runs 64 sequences of 64 calls across two pools and four
position salts, with additions, swaps, pokes, partial withdrawals and block advances.
After every operation, claim balances equal the sum of withheld balances, and tracked
liquidity matches core. Fuzz tests run 256 cases each.

Independent review and a live Sepolia fork rehearsal belong to later release work; this
local suite is not an independent audit or evidence of deployment. The supplied protected
checks were read; their environment-driven attestation harness is not copied into this suite.

See [deployment parameters and responsibilities](docs/DEPLOYMENT.md),
[ABI documentation](docs/ABI.md), [review notes and assumptions](docs/REVIEW-NOTES.md),
and [dependency attribution](docs/ATTRIBUTION.md).
