# Market data & payouts

Index pools by pool id, price a launch in its own quote, and read fees, bonding and
creator payouts correctly.

## Pool identity

The launch's hook address is part of the pool key, so a pool id cannot be derived
from the token pair alone. Prefer the emitted `TokenCreated.poolId` or
`hook.poolId()`, then cross-check the key you computed.

```
PoolKey = (currency0, currency1, fee, tickSpacing, hooks)
  currencies sorted numerically by address

poolId = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))
  Ethereum Keccak-256, full ABI encoding.
  Not SHA3-256. Not abi.encodePacked.

This family uses fee 10000 (1% in v4 units) and tickSpacing 200.
Validate the observed key rather than assuming those constants.
```

Index by the triple `(chain id, PoolManager address, pool id)`. Read `Initialize` to
map a pool to its currencies, fee, spacing and hook, then index `Swap`,
`ModifyLiquidity` and `Donate` from the same manager, where the pool id is indexed in
topic 1. Deduplicate by chain, transaction hash and log index, and keep canonical
block hashes so a reorg stays recoverable.

> **Manager balances are not pool reserves.** The PoolManager holds token balances
> across every pool it serves. Use `StateView.getSlot0(poolId)` and
> `getLiquidity(poolId)` for one launch's price and active liquidity. A positive
> `ModifyLiquidity` is liquidity units, not the principal deposited, and its sender
> can be a position manager rather than the owner.

## Price and units

```
r = sqrtPriceX96^2 / 2^192     exact arithmetic; raw currency1 per raw currency0

quote per token = r            if the launch token is currency0
                = 1 / r        if the launch token is currency1

human units     = that value * 10^(tokenDecimals - quoteDecimals)
```

Read both tokens' `decimals()` and the launch's quote asset. Keep exact integers or
rationals until you format for display. A price denominated in an arbitrary quote is
not a USD price, and a site's default supply is not a contract-wide guarantee, so
read `totalSupply()`.

> **Arc USDC has two representations.** The deployment uses USDC's ERC-20 interface
> at 6 decimals, while native gas accounting is 18 decimals. Do not add the two as
> separate assets, do not assume every approved quote shares USDC's decimals, and do
> not deduplicate native against ERC-20 records by amount alone, which collapses
> legitimate repeated transfers.

## Classify buys and sells

> **v3 and v4 use opposite sign conventions.** v4 swap amounts are from the
> swapper's perspective: on the launch token leg, positive means tokens received (a
> buy) and negative means tokens paid (a sell). v3 uses the opposite, pool-oriented
> convention. Do not share one side classifier between them without a version
> branch.

- **`Swap.sender` is usually a router** — It is the immediate caller. Even `tx.from`
  need not be the end user once relayers or account abstraction are involved.
- **Do not double count a dev buy** — A Portal `DevBuy` event can describe the same
  trade as a PoolManager `Swap`. Count it once.
- **Pool deltas are not user execution** — With hooks, router fees or bundled calls,
  core deltas do not equal the user's final debits and credits. Inspect the whole
  execution before reporting an execution price.

## Fees and bonding

**v4 launch tokens have no transfer tax.** The tax is applied by the pool's hook on
swaps, so a wallet-to-wallet transfer pays nothing. Read every rate from the launch's
own hook.

| Hook getter | What it returns |
|---|---|
| `buyTaxBps()` / `sellTaxBps()` | That launch's per-leg tax in basis points, fixed for the life of the hook. |
| `poolFee()` | Pool fee in v4 units, where 10000 is 1%. |
| `totalFeeBps()` | The base schedule per leg: pool fee converted to bps, plus that leg's launch tax. |
| `currentSnipeTaxBps()` | The current opening surcharge for an ordinary trader. |
| `bonded()` | Whether the bonding milestone has latched. |
| `bondBound()` / `bondTick()` | Whether the milestone is bound, and its threshold tick. |

Each creator tax leg is at most 1000 bps. One leg may be zero; both zero is rejected
at launch. The base schedule excludes router and service fees, gas, and the opening
surcharge, which runs for three seconds and has its own exemptions and a
combined-rate cap. Simulate at the relevant block rather than promising that adding
displayed percentages predicts a route's execution.

```
progress = (tick - tickStart) / (tickBond - tickStart)

Direction is preserved for either token order.
Guard a zero span. Clamp only for display.
A tick retreat does NOT clear an already latched bonded state.
```

> **Bonding does not migrate the pool.** The hook latches bonding during swap
> processing. The pool does not move to another venue, and the locker keeps holding
> the launch's position. Read `hook.bonded()` for status rather than inferring it
> from the current tick.

## Quotes and payouts

The pair's quote asset and the payout asset are separate concepts, and they diverge
on Portal #7. Do not infer the payout asset from the eleventh launch word or from the
Portal's current quote registry.

| Portal | Quote and payout handling |
|---|---|
| #3 to #5 | Fixed historical USDC quote. Use that launch's historical splitter ABI; #5 claims pay the quote leg in native USDC. |
| #6 | Quote is launch word 10. The creator share is credited for claim; the quote leg pays in the launch quote ERC-20. |
| #7 | Quote is launch word 10 and does not change, but the splitter may convert selected revenue to USDC. Read `splitter.converts()`, `quoteAsset()` and `defaultQuoteAsset()`. |

> **Credited is not paid, and queued is not delivered.** On #6 and #7 creator
> revenue is credited rather than pushed on every distribution, and `claim(address)`
> pays the named account rather than the caller. On #7 a queued conversion is not a
> completed payout. Accrued, actual payout events and conversion events are three
> different lifecycle stages: report them from contract state and events, and never
> add them together as earnings.
>
> `claim(address)` on #7 returns three values; earlier versions return different
> shapes behind the same selector. Read claimable quote, launch-token and USDC
> balances separately with the #7 ABI. Allocation basis points are shares of
> collected revenue, not extra percentages charged on a trade.

## Before you go live (integrator checklist)

1. Discovery from every supported Portal, including #7 from the bundle's separate
   section. A failed lookup must not become a false absence.
2. Exact 9, 10 and 11 word decoding, with legacy v3 kept separate, and the #6 and #7
   launch selectors kept separate.
3. Token → Portal → hook → pool id binding. Two different hooks from one
   implementation version must both be accepted without requiring identical runtime
   bytecode. Hooks are not clones, and constructor immutables differ per launch.
4. Two pools indexed through one manager, without mixing their events or volume,
   with restart and backfill deduplication working.
5. Correct ordering, scaling and side classification, with non-USDC quotes handled
   in their own units.
6. Hook-aware buy and sell simulation, with slippage limits, accurate fee
   disclosure, and no double-counted dev buy. The Portal is a launch contract, not
   the swap router.
7. Bonded state read independently of tick. Unavailable data must not render as a
   false unbonded or zero state.
8. Asset-specific payout accounting for every splitter version you support,
   including #7 conversion, pending and fallback outcomes, if you display payouts at
   all.

> **Treat launch metadata as untrusted.** Names, symbols, links and images are
> written by whoever launched the token. A quote asset being approved for launching
> is not issuer verification and not a backing guarantee.
