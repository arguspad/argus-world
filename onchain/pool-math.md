# Formulas: pool id, price, tax, bonding

## Pool id (Uniswap v4)

```
PoolKey = (currency0, currency1, fee, tickSpacing, hooks)
  currencies sorted numerically by address

poolId = keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))
  Ethereum Keccak-256, full ABI encoding.
  NOT SHA3-256. NOT abi.encodePacked.

This family uses fee 10000 (1% in v4 units) and tickSpacing 200.
Validate the observed key rather than assuming these constants.
```

Don't derive the pool id from the token pair alone: the hook address is part
of the key. Prefer the emitted `TokenCreated.poolId` or `hook.poolId()`, then
cross-check against the key you computed.

## Price

```
r = sqrtPriceX96^2 / 2^192     exact arithmetic; raw currency1 per raw currency0

quote per token = r            if the launch token is currency0
                = 1 / r        if the launch token is currency1

human units     = that value * 10^(tokenDecimals - quoteDecimals)
```

Read `decimals()` for both tokens and the launch's quote asset. Keep exact
integers/rationals until you format for display.

Arc USDC has two representations: ERC-20 interface at 6 decimals, native gas
accounting at 18 decimals. Don't add them together as two separate assets.

## Tax and bonding (read from the hook, not the token)

**v4 launch tokens have no transfer tax.** The tax is applied by the pool's
hook on swaps: a wallet-to-wallet transfer pays nothing.

| Hook getter | What it returns |
|---|---|
| `buyTaxBps()` / `sellTaxBps()` | Per-leg tax of that launch, in bps, fixed for the hook's lifetime |
| `poolFee()` | Pool fee in v4 units (10000 = 1%) |
| `totalFeeBps()` | Base schedule per leg: pool fee converted to bps + launch tax |
| `currentSnipeTaxBps()` | Current opening surcharge for an ordinary trader |
| `bonded()` | Whether the bonding milestone has latched |
| `bondBound()` / `bondTick()` | Whether the milestone is bound, and its threshold tick |

Each side of creator tax is at most 1000 bps. One side may be zero; both zero
is rejected at launch. The opening surcharge lasts three seconds, has its own
exemptions, and a cap on the combined rate — simulate at the relevant block
rather than summing displayed percentages.

```
progress = (tick - tickStart) / (tickBond - tickStart)

Direction is preserved for either token order.
Guard a zero span. Clamp only for display.
A tick retreat does NOT clear an already latched bonded state.
```

Bonding does not migrate the pool: the hook latches it during swap
processing, the pool stays the same before and after. Read `hook.bonded()`,
don't infer it from the current tick.

## Quote vs payout asset

They diverge starting with Portal #7:

| Portal | Quote/payout handling |
|---|---|
| #3–#5 | Fixed historical USDC quote |
| #6 | Quote = launch word 10; the quote-leg payout pays in the launch's quote ERC-20 |
| #7 | Quote = word 10 (unchanged), but the splitter may selectively convert to USDC — read `splitter.converts()`, `quoteAsset()`, `defaultQuoteAsset()` |

"Credited" ≠ paid, "queued" ≠ delivered: three distinct lifecycle stages, to
be reported separately from contract events/state — never summed as if they
were earnings.
