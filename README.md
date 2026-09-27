# Pass the Parcel

Parcel is a fixed-supply ERC-20 and a Uniswap v4 hook for native ETH pools. Every sell fills that pool's pot with `floor(gross ETH output / 100)`. The next buy spending at least `0.001 ether` before the rebate receives `min(pot, actual ETH input)` as a reduction of its ETH debt, within the same swap. The AMM's execution and token leg match an otherwise identical hookless pool.

## Contracts

- `src/Parcel.sol`: zero-argument constructor, name `Parcel`, symbol `PRCL`, 18 decimals, exactly `10^27` minor units (one billion tokens) minted to the deployer. No external mint, burn, owner, pause, transfer tax, or upgrade mechanism.
- `src/ParcelHook.sol`: one constructor argument, `IPoolManager`. Immutable manager, no administrator, setters, withdrawal, sweep, pause, or upgrade. Only `afterSwap` and `afterSwapReturnDelta` are enabled. All other callback selectors revert. Pool initialization belongs to the factory.
- `src/ParcelRouter.sol`: permissionless single-swap settlement adapter. It handles all four swap modes, verifies net slippage, pays tokens from the caller's allowance, delivers output to the caller, and refunds unused `msg.value`. It has no administrator. Use this adapter, or implement its settlement protocol, for full Parcel support.
- `src/HookFlags.sol`: canonical permission constants and address checks used by admission/deployment tooling.

Pots use the complete `PoolId` (currencies, fee, tick spacing, hook address). The hook does nothing when `currency0 != address(0)`. There is no token allowlist: another ETH/token pool using this hook has its own independently funded pot and identical rules. Wrapped ETH is an ERC-20 and is **not** native ETH.

`ParcelFilled(poolId, added, potAfter)` is emitted on every native-pool sell, including a zero fee after rounding. `ParcelPassed(poolId, paid, potAfter)` is emitted for each nonzero payout. Empty-pot and subthreshold buys emit no payout event. `pot(PoolId)` is denominated in wei.

## Settlement integration

Uniswap v4's `afterSwap` return delta can change only the **unspecified** currency. An ETH-specified swap therefore requires the additional settlement protocol below. A generic router that assumes `manager.swap()`'s returned balance delta always equals its ledger balance is incompatible with these paths.

| Swap | ETH side | Collection / rebate |
| --- | --- | --- |
| Sell, exact token input | Unspecified output | Hook takes the ETH fee; positive after-swap delta deducts it from seller output. |
| Sell, exact gross ETH output | Specified output | Hook calls `IParcelFeePayer(sender).payParcelSellFee(poolId, fee)`. Router calls `manager.take(native, hook, fee)`, debiting its own ETH ledger. Hook verifies the exact receipt and the exact sender-ledger debit. |
| Buy, exact ETH input | Specified input | Hook calls `manager.settleFor{value: paid}(sender)`, reducing the swap caller's ETH debt. |
| Buy, exact token output | Unspecified input | Hook settles ETH and returns a negative after-swap delta to reduce the buyer's debt. |

The hook calls `sync(native)` before native settlement, so an earlier ERC-20 sync cannot misdirect that payment. Sell-fee callbacks are authenticated by the router against its active pool/hook, are limited to one collection, and are capped at 1% of the requested gross output. The hook accepts ETH only during a pending fee collection, in exactly the requested amount, from its PoolManager. A callback that does nothing, underpays, overpays, or debits another account reverts the entire swap. Nested hook callbacks are rejected.

In all modes, `ParcelRouter` reads `manager.currencyDelta(address(this), currency)` after the swap and settles that **net** amount. Its return value reports those net deltas. It does not rely on caller identity embedded in `hookData`, allowlisted routers, or an arbitrary payout recipient. Anyone can implement the same authenticated protocol; there is no router registration or setter.

`SwapParams.amountSpecified` controls the underlying AMM trade. Negative is exact input; positive is exact **gross** output. For an ETH-output sell requesting 1 ETH, the seller receives 0.99 ETH and the pot receives 0.01 ETH. The requested input of an ETH-input buy is its gross AMM spend; its wallet pays that input less the rebate. Exact token input/output remains unchanged. Use `maxInput` and `minOutput` on the router for **net wallet** limits, including sell fees. The deadline is inclusive. Price limits can cause partial fills; fees, qualification, and caps use actual filled amounts, never the requested amount.

For a buy, send sufficient `msg.value` to cover the maximum net input. Supplying the gross input is convenient: all unspent ETH is refunded. Do not rely on a displayed pot remaining available until inclusion. A pot that covers the whole input makes that buy owe zero ETH; any excess pot stays for subsequent qualifying buys. Sellers approve this router for the input token. Refunds and swap outputs go to `msg.sender`, which must be able to receive native ETH. A failed refund, transfer, fee callback, or settlement reverts the full transaction, including the pot update.

## Deployment parameters and responsibilities

Compile with Solidity **0.8.26**, Cancun EVM, optimizer enabled with 200 runs, and no compiler metadata appended to bytecode. `foundry.toml` pins a version, not a local compiler executable. The target chain must support Cancun transient storage, used by the canonical v4 PoolManager.

1. Select and independently verify the canonical PoolManager address on the target chain. The hook rejects zero, but a nonzero address is not proof of canonical code. `ParcelHook` and `ParcelRouter` must use the same manager.
2. The launch factory deploys `Parcel()` and receives the entire supply. Distribution and liquidity allocation belong to that factory; the token gives it no continuing privileges.
3. Construct hook init code as `abi.encodePacked(type(ParcelHook).creationCode, abi.encode(manager))`. Mine a CREATE2 salt for the **actual CREATE2 deployer** and this exact init code. The predicted address must satisfy `uint160(address) & 0x3fff == 0x0044` (decimal flags **68**). The usual formula is the last 20 bytes of `keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode))`. `PoolFixture.deployHook` demonstrates real salt mining and constructor deployment without bypassing address validation.
4. Deploy the hook at that address. Deploy `ParcelRouter(manager)` normally. Verify runtime code, constructor arguments, permissions, and the published addresses against the reviewed build. There is no transaction-broadcasting script in this project.
5. The factory calls `manager.initialize` with currency0 = native ETH (`address(0)`), currency1 = Parcel, the deployed hook, and the chosen fee/tick spacing/initial square-root price. It then supplies liquidity through a v4 liquidity manager. The tests use fee 3000, tick spacing 60, square-root price `2^96`, and range `[-60000, 60000]`; these are test parameters, **not a launch price or allocation recommendation**. Launch price, fee, range, supply allocation, chain, and manager address remain factory deployment decisions. Use a static fee; no dynamic-fee updater is provided.
6. Integrators must route all four modes with the settlement rules above, show fees/rebates separately from AMM quotes, and enforce net slippage and deadlines. Monitor `ParcelFilled`, `ParcelPassed`, and `pot(poolId)` for each pool. There is no keeper, claim transaction, timeout, recovery key, or payout outside a swap.

## Reproducible local checks

Foundry and the standard Solidity 0.8.26 compiler must be available in the checking environment. All Solidity dependencies are vendored as ordinary source files in `lib/`; their upstream commits and archive hashes are in `DEPENDENCIES.json`. No package installation, submodule, RPC, FFI, filesystem cheatcode permission, or network access is needed for a build or test.

```sh
forge build --offline
forge test --offline
forge test --offline --fuzz-runs 1000
forge fmt --check
```

Tests deploy an actual PoolManager and CREATE2-mined hook. They compare all four modes against independently initialized hookless pools, including real wallet balances and matching pool prices; test qualification, fee rounding, payout caps, empty pots, partial fills, pool isolation, nonnative pools, events, and rollback; and attack fee collection, callbacks, and reentrancy. A stateful invariant mixes both pools and all four modes and reconciles cumulative fills/payouts with individual pots, ETH custody, and zero outstanding manager deltas. The token tests cover supply, deployer allocation, metadata, allowances, exact transfers, and invalid operations.

The provided protected floor tests were also run from temporary copies in `test/scratch/` against the actual compiled creation code. Their environment values were passed by the parent process; no test calls `vm.setEnv`. They are verifier inputs, not modified or delivered tests. See `VALIDATION.md` for results and limits.

## Assumptions and limits

- Accounting is exact in integer wei; 1% rounds down, so gross sell outputs below 100 wei add zero. Qualification uses actual gross ETH input including the AMM input fee, before the rebate.
- The manager is trusted canonical v4 code; the currency1 token follows normal ERC-20 behavior. Parcel satisfies this. Fee-on-transfer and rebasing assets are unsupported.
- For normal completed swaps, ETH custody equals the sum of all pots. Ethereum can forcibly credit an address (for example via `SELFDESTRUCT` elsewhere), bypassing `receive`; no contract can prevent that. Such unsolicited surplus is unassigned and permanently inaccessible. It never increases any pot or payout. There is intentionally no sweep. ERC-20s accidentally sent to the hook are likewise inaccessible.
- The next qualifying buy means transaction execution order, with no identity, randomness, or waiting-period protection. Bots, arbitrageurs, sellers buying back, and multiple swaps in one transaction can qualify. The design does not promise fair ordering or resistance to MEV.
- Local tests are evidence of the checked behavior, not a security audit or a deployment approval. No chain fork rehearsal, independent adversarial review, or live transaction was performed here. Those remain release responsibilities.
