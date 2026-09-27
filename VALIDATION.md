# Local validation

These are contributor-run checks, not independent admission or release approval. No transaction was broadcast and no fork or RPC was used.

Toolchain: Foundry 1.7.1 (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`), Solidity 0.8.26, Cancun, optimizer 200 runs. The configuration pins `solc = "0.8.26"`, disables FFI, grants no filesystem permissions, and contains no compiler executable path.

| Check | Local result |
| --- | --- |
| Clean `forge build --offline` | Pass |
| `forge test --offline` | 34 passed, 0 failed, 0 skipped |
| `forge test --offline --fuzz-runs 1000` | 34 passed, 0 failed, 0 skipped; 1,000 cases per fuzz property |
| Stateful accounting invariant | 128 runs × 64 calls = 8,192 successful calls, 0 reverts |
| `forge fmt --check` | Pass |
| Supplied protected token checks | 6 passed, 0 failed, 0 skipped |
| Supplied protected hook checks | 3 passed, 0 failed, 0 skipped |
| Vendored dependency provenance | Compared file-for-file with archives fetched from pinned upstream commits; 97 delivered source/license file hashes recorded |

The protected files were copied without modification into `test/scratch/protected/`, executed against the compiled creation bytecode, and removed from scratch afterward. The original provided inputs were not edited. The protected hook run declared flags 68 and encoded test PoolManager address `0x0000000000000000000000000000000000001000`; the token run declared 18 decimals. These values were passed through the subprocess environment, not `vm.setEnv`. The protected suite's relocated manager is used only for its deployment/admission checks. All delivered integration tests deploy and use a real manager at its original address.

Delivered test coverage:

- `Parcel.t.sol`: fixed supply and metadata; factory allocation; fuzzed exact transfers and allowances; infinite approvals and self-transfers; invalid receivers, insufficient balances/allowances, and absent administrative selectors.
- `ParcelHook.t.sol`: real CREATE2 constructor validation, callback authorization, all four swap modes against hookless references, actual ETH/token wallet changes, identical AMM prices, threshold boundary, capped payouts, empty pots, zero-msg.value subsidized buys, rounding/events, partial fills, separate token pools, nonnative pools, liquidity withdrawal, and rollback after slippage or insufficient funding.
- `ParcelAdversarial.t.sol`: fee evasion, incorrect fee sizes, payment debited to another account, attempted reentrant swaps, custody observed within the untrusted fee callback, and failed ETH refunds.
- `ParcelInvariant.t.sol`: randomized sequences across two ETH pools and all swap modes, checked against reference pools and independent cumulative fee/payout counters. Every completed step has zero outstanding PoolManager deltas, no router ETH leftovers, and custody equal to the sum of tracked pots.

Self-review traced each settlement path: a sell's ETH deposit is recorded on receipt; an unspecified-ETH fee pairs a hook take with its positive delta; an unspecified-ETH rebate pairs hook settlement with its negative delta; specified-ETH adjustments modify the router's live ledger and are reflected in final settlement. Router fee authorization ends before token settlement and refunds, while its swap guard remains active through refunds. The sole configurable deployment trust is the immutable PoolManager address.

Runtime sizes under the checked settings: Parcel 1,709 bytes, ParcelHook 3,334 bytes, ParcelRouter 4,513 bytes. All are below EIP-170's 24,576-byte limit. The protected scans found no `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT` in the token or hook runtime. Compiler lint advisories concerning explicit casts and deadline timestamps are not Solidity compilation errors; casts follow sign/range checks or bounded manager deltas, and timestamps are used only for the caller's deadline.

Limitations: full support requires the documented settlement adapter protocol; arbitrary generic routers are not automatically compatible. Forced ETH is outside the closed custody invariant and cannot be prevented by a receive guard; it does not fund a pot. No independent audit, fork rehearsal, live factory integration, gas-budget certification, or formal proof was performed. Deployment parameters and remaining operational responsibilities are in `README.md`.
