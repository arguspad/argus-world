# Launch record layout, by Portal version

Source: `argus.world/docs/integrate` §"Decode the launch record".

Select the Portal by address first, then query `LAUNCH_STRUCT_WORDS()` and
validate the exact returned length. Word count alone cannot separate #6 from
#7, nor legacy v3 from a ten-word v4 record.

| Portal | Record | How to tell it apart |
|---|---|---|
| #7 | 11 words, 352 bytes | `registry()` exists. Use #7's launch/payout ABI. |
| #6 | 11 words, 352 bytes | No #7 routing discriminator. |
| #5 and #4 | 10 words, 320 bytes | Hooked record with no `quoteAsset`; the quote is USDC. |
| #3 | 9 words, 288 bytes | No `tickBond` and no `quoteAsset`; read bonding from the hook. |
| #2 and #1 | 10 words, 320 bytes | Legacy v3 record, entirely different fields. |

## Eleven-word hooked record (Portal #6 and #7)

```
0  address creator          6  uint16  buyTaxBps
1  int24   tickStart        7  uint16  sellTaxBps
2  bool    tokenIsToken0    8  uint256 positionId
3  address locker           9  int24   tickBond
4  address hook            10  address quoteAsset
5  address splitter
```

For Portal #4 and #5: read only indices 0–9 and treat the quote as USDC
(fixed). For Portal #3: read only indices 0–8.

## Legacy v3 record (Portal #1 and #2), in order

```
creator, tickStart, tickBond, tokenIsToken0, bonded,
pool, processor, tracker, locker, positionId
```

> Always use the versioned ABI from the bundle for the exact Solidity types —
> the table above is for orientation only, not an ABI to paste into
> production. Never decode an eleven-word result with a ten-output ABI just
> because the decoder tolerates trailing data.
