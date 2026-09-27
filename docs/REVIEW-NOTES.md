# Implementation review notes

These are author notes to support the separate independent review, not an independent
audit. Local tests use real v4 core, without an RPC or mainnet/Sepolia fork.

## Delta signs and custody

Let `P` be core's principal delta, `F` the nonnegative newly accrued fees, `W` previously
withheld fees and `Q` the actual penalty (zero if waived). Core starts with `P + F` and
subtracts the hook's returned delta from the LP. Each equation applies per currency.

| Callback | Hook manager operations | Returned hook delta | Final LP delta |
| --- | --- | --- | --- |
| Add | Mint claims `F`, debiting hook by `F` | `+F` | `P` |
| Remove/poke | Burn claims `W` (credit); donate `Q` (debit) | `Q - W` | `P + F + W - Q` |

In both rows the hook's transient balance finishes at zero. No calculation takes `P` as
an input. Since `0 <= Q <= F + W`, principal is not penalized and fees are not overpaid.
Withheld state is cleared before manager calls; reverts roll back state and claims together.
The hook only calls its immutable manager (`mint`, `burn`, `donate`, and `extsload`). Claims
operations do not call receivers, and no donation callbacks are enabled on attached pools.
There is no hook-originated token transfer or untrusted recipient call to reenter its state.
The tests explicitly cover access to both return-delta callbacks and failed final settlement.

Claims exactly back all recorded withholding after each hook-managed transaction. ERC-6909
allows anyone to send unsolicited claims to any address, including this hook; those surplus
claims cannot be rejected and have no withdrawal path. Under such forced transfers the
strict universal equality becomes `claimBalance >= sum(withheld)`; the stateful invariant
tests exact equality for protocol operations without unsolicited transfers. Forced native ETH
or ERC-20 donations likewise create inaccessible surplus and are not credited to an LP.

## Withdrawal, rounding and arithmetic

Core has updated active liquidity before the removal callback. If it is zero, skip donate
and emit `PenaltyWaived` with the forgone penalty. An out-of-range position does not count
as a donation recipient. This exception intentionally allows a sole active LP to exit early
with all fees; it trades strict JIT deterrence for withdrawal liveness.

Penalty rounding is upward per currency; even one fee unit is penalized while in the window.
Core's distribution of a donation uses fixed-point fee-growth rounding. The recipient LP
may collect one unit less than the donation in the unit-test scenario; it remains rounding
dust in PoolManager. `totalDonated` measures the exact amount donated, not the amount
subsequently collected by each LP.

Core `BalanceDelta` uses signed 128-bit currency amounts. Withheld accumulation and the
sum of fresh plus withheld fees must fit that range, as must the final core caller delta.
Safe packed-delta addition reverts on overflow rather than wrapping. Extremely large or
nonstandard pools can therefore reach core/arithmetic limits; “any pool may attach” does
not remove v4's amount bounds. JITP's entire `10^27` supply is far below `int128.max`.
The penalty multiplication promotes to uint256 before multiplying by at most ten.
Block numbers are stored as uint256 and assumed monotonically increasing.

## Identity, resets and avoidance strategies

- **Shared router:** `sender` is the router, not the LP wallet. Two users with the same
  router/ticks/salt share core position state, withheld fees and a window. An addition by
  either resets it for both. The test reproduces this from a second wallet. Router-level
  custody is also shared in PoolModifyLiquidityTest and this repository's test router,
  which are not suitable production LP custody contracts. Recommend PositionManager and
  its position tokenId salt with proper NFT authorization.
- **Adding:** even a small top-up resets the whole position's window and withholds all
  auto-collected fees. It cannot extract mature fees through the add callback. A holder
  can choose to poke after maturity before making a new addition; those mature fees are
  legitimately free of penalty.
- **Pokes and partial removals:** both assess all fees currently collected, including
  all withholding; the clock is unchanged. A partial removal or poke leaves some of the
  position in range, so that liquidity earns a share of the donation. Repeated pokes can
  recapture and re-penalize donated fees. This is an inherent economic limitation of pool
  donations, not a claim that JIT profitability is eliminated.
- **New salts/pools:** new positions have independent clocks and cannot access an old
  position's withholding. A second mature position or colluding LP can receive penalties;
  this mechanism is not Sybil resistant. In low liquidity pools a participant may control
  most remaining active liquidity, or move the price into a self-controlled range.
- **No swapper identity:** swaps are not intercepted. hookData is ignored and unauthenticated;
  neither wallets nor routers receive credits through it. There is no router allowlist.

The deployment review should assess these economic limits, the intended LP router and
production range/price choices. The ten-block constant is an approved rule, not a universal
guarantee against JIT or other MEV. Standard v4-compatible currencies and an authentic
PoolManager are assumed; fee-on-transfer/rebasing tokens are not made compatible by this hook.
