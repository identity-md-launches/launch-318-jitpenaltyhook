# Sepolia deployment handoff

This contribution supplies source, tests and ABIs. The separate manifest assignment writes
`launch.json`; the independent reviewer checks accepted source and manifest. Source
publication, signed artifact linkage, policy, attestation, admission, factory transactions,
IPFS publication and starting the frontend are responsibilities of the release services.
No later service outcome is assumed to have happened here.

| Parameter | Approved value |
| --- | --- |
| Chain | Sepolia, `11155111`, Cancun support required |
| Token artifact | `src/JITP.sol:JITP` |
| Token constructor | Empty argument bytes; entire fixed supply goes to deploying factory |
| Hook artifact | `src/JITPenaltyHook.sol:JITPenaltyHook` |
| Hook constructor | Exactly one address: `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Hook address mask | Low 14 bits exactly `0x0503` / decimal `1283` |
| currency0 | Native ETH, address zero |
| currency1 | Factory-deployed JITP address, learned from the pool key |
| LP fee | `3000` (0.30%), a static-fee pool |
| tickSpacing | `60` |
| Penalty window | Source constant `10` blocks |
| Owner / recipient / hook fee | None |
| Site label | `lab-jit-penalty-hook` |

Compile with the committed Foundry settings and export the ABIs before mining the hook.
The CREATE2 preimage is `0xff || actualDeployer || salt || keccak256(initCode)` where
`initCode = JITPenaltyHook.creationCode || abi.encode(poolManager)`. Mine until
`uint160(predictedAddress) & 0x3fff == 0x0503`. Any change to the deploying factory,
constructor argument, source, compiler settings or linked dependencies changes that search.
The constructor validates the flags; do not override validation for the production artifact.
Tests contain a working CREATE2 mining example in `test/helpers/HookFixture.sol`.

The deployment service must supply the actual factory address, mined salt, initial price,
seed quantity, tick range and supply allocation from its reviewed launch configuration.
No factory ABI/address or production seed allocation was supplied to this source task.
For the approved one-sided launch, the seed range is below the opening tick: it holds only
currency1, with no ETH. The local rehearsal uses price `2^96` and range `[-600,-60]` as
a test scenario, not an approved economic price. A buy has `zeroForOne = true` and
`amountSpecified < 0` for exact input. It moves into the seeded range; a sell reverses direction.

The hook imposes no initialize, swap or donate callbacks and no minimum deposit. Its
after-add callback accepts the one-sided seed. Factory initialization and liquidity seeding
must remain in the release rehearsal, including zero initial active liquidity and zero ETH.
Use a fresh real PoolManager locally: copying a deployed manager's runtime to another
address is not a valid lifecycle simulation because of core's immutable NoDelegateCall guard.

Before release, the independent reviewer should reconcile constructor args, token supply,
source, ABI exports and these four flags against the generated manifest. Concrete source,
authorization or constructor conflicts are review findings. Policy and signed artifact
linkage belong to services. The release service must verify Sepolia contract code and run a
live fork/factory rehearsal; these offline tests do not verify live contract state.

## Frontend/service integration

After deployment, the frontend contributor needs the actual token/hook addresses, pool key,
deployment block, and reviewed ABI files. The approved Sepolia endpoints are:

| Purpose | Address |
| --- | --- |
| PoolSwapTest | `0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe` |
| StateView | `0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C` |
| V4Quoter | `0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227` |

These are approved inputs, not live-address attestations. Swaps use PoolSwapTest with
explicit `sqrtPriceLimitX96` and hookData; obtain quotes and state from the listed contracts.
The page displays current windows, withheld fees and cumulative donations using the ABI
event/read guide. The later website is a static export with `dist/index.html` and no backend.
Recommend PositionManager for LP ownership, using its tokenId salt, instead of a shared
test router. Operators should monitor donation/waiver events, outstanding withholding and
window resets; there is no admin intervention, rate adjustment, emergency rescue or upgrade.
