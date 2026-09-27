# Sources and licenses

The fee-withholding/claim-settlement pattern is reimplemented from OpenZeppelin's
[LiquidityPenaltyHook](https://github.com/OpenZeppelin/uniswap-hooks/blob/39b52d1e5aacd45c2880e28f97d6ae3dd500672c/src/general/LiquidityPenaltyHook.sol),
revision `39b52d1e5aacd45c2880e28f97d6ae3dd500672c`, under MIT.
The original [MIT notice](licenses/OpenZeppelin-uniswap-hooks-MIT.txt) is included.
Our implementation always withholds fees on addition, uses a fixed ten-block window,
rounds penalties upward, waives donations without active liquidity, and adds the approved
events and read interfaces. It extends Uniswap v4-periphery's BaseHook directly.

The exact vendored upstream revisions are listed in `dependencies.json`. Files retain
their upstream SPDX headers and license notices. Vendored source is a subset needed by
this project and its tests; `dependency-files.sha256` records the delivered files.

| Dependency | Purpose |
| --- | --- |
| Uniswap v4-core | Core interfaces, libraries, actual PoolManager and test swap/donation routers |
| Uniswap v4-periphery | BaseHook and immutable manager base; pinned before BaseHook moved upstream |
| OpenZeppelin Contracts 5.1.0 | Standard ERC-20 and its dependencies |
| forge-std | Foundry tests, assertions and cheatcode interface |
| Solmate | Core's Owned dependency |

Original project source in `src/`, project tests and documentation are MIT licensed.
Upstream components retain their own licenses (including BUSL-1.1 in v4 core and
test-only UNLICENSED files); the project license does not relicense upstream files.
