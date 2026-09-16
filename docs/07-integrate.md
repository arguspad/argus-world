# Integrate Argus

Source: https://argus.world/docs/integrate

For exchanges, wallets, indexers and analytics: discover launches, decode the Portal
record, and bind a token to its hook and pool.

## How a launch is put together

Argus launches trade in **Uniswap v4**. Every launch shares one PoolManager and gets
its own tax hook, so there is **no single Argus pool contract and no single Argus
hook**. The launch record is what ties the parts together, and it is the only
authority for a given token.

| Component | What it is for |
|---|---|
| **Portal** | Creates launches and records the token, hook, locker, splitter and pool relationship. This is the factory — discover launches here. |
| PoolManager | Shared v4 pool storage and execution. Index its events by pool id, never by manager address alone. |
| Per-launch hook | Applies that launch's buy and sell tax and latches its bonding milestone. Read fees and bonding through it. |
| StateView | Reads PoolManager state for one pool id. Price and active liquidity come from here. |
| Locker | Holds the launch's liquidity position. It is not a pool address. |
| Splitter | Accounts for revenue and credits payouts. Version specific. |

> **Pick your scope and say so.** Indexing market events is not the same as
> supporting launch creation, payouts or swap execution. A smaller scope is fine;
> state which one you built.

## Network, RPC and the ABI bundle

**Arc mainnet, chain ID 5042 (`0x13b2`)** — per the Argus integration docs
(`argus.world/docs/integrate`, fetched 2026-09-16). **See
[`../NOTES-LIMITATIONS.md`](../NOTES-LIMITATIONS.md) — this conflicts with chain IDs
reported by third-party Arc/Circle documentation I found independently (5042002 for
Arc testnet; unrelated projects also use 1243 and 4564 for other "Arc"-named
chains). Verify the chain ID yourself against a trusted RPC before relying on it.**

Verify the chain ID and that each address has non-empty code before you trust any of
it, and never substitute an address copied from another chain because the contract
name matches.

The published ABI and address bundle:

```
https://arguspad.io/argus-v4.json           v4 hooked family, version 3, generated 2026-09-12
https://arguspad.io/argus-abi.json          legacy v3 launches
https://arguspad.io/argus-v4-example.mjs    partial example, see the caveat below

sha256(argus-v4.json) =
  94f7e126fd2f0a9fe34f1c4b82d7f8082eef9757a5822895f3c0a6d1c9d3da1f
```

> I could not download these three files myself (repeated read-timeouts fetching
> `arguspad.io` from this environment — see `NOTES-LIMITATIONS.md`). The hash above
> is copied verbatim from the docs so **you** can verify integrity once you download
> the bundle yourself: `sha256sum argus-v4.json` and compare.

Pin the bundle contents or its hash to your integration release. Its `version` and
`generatedAt` fields are **not** a complete deployment registry: the top-level
`addresses.portal` describes Portal #6, while **Portal #7 is a separate `portal7`
section**. Read both. Any `perLaunch` or `implementation` address in the bundle is a
**sample**, not the hook or token address for every launch.

> **Choose your own RPC, and use more than one.** Public Arc endpoints vary a great
> deal in reliability. Measured on 2026-09-14 over 300 calls at 20 per second,
> `rpc.arc-scan.org` answered 92 of 300 while two alternates answered 300 and 297.
> Endpoints also differ on JSON-RPC batching: arc-scan accepts batches and several
> alternates reject them outright. Configure a primary and at least one fallback, and
> do not turn any one measurement into a permanent assumption.

## The Portal registry (the factories)

Index every Portal, not only the current one. A newer Portal never replaces an
existing token's contracts, so historical launches keep answering from the Portal
that created them. **Preserve the originating Portal permanently.**

| Portal | Address | Family | Record size | Start block |
|---|---|---|---|---|
| **#7 — current launch target** | `0xB021Be536808f551b31789422Fd28a6c9c6e97Da` | hooked v4 | 11 words | 20,395,275 |
| #6 | `0xA5628A11c412596E1f63b75a2C0284F843C549d6` | hooked v4 | 11 words | 20,240,260 |
| #5 | `0x07a688a001f416cC433c68Ff56Aa26bC5131Cc6E` | hooked v4 | 10 words | 20,081,606 |
| #4 | `0xa36c443A797771Df82533B8B4A86F0AFfd970862` | hooked v4 | 10 words | 19,690,658 |
| #3 | `0x7A17Ab0106C46C0be30623F3EB7F299CC0058338` | hooked v4 | 9 words | 19,674,154 |
| #2 | `0xBed9880A0ba12722ba4b8791c0B6F8c74338246C` | legacy v3 | 10 words | 19,056,397 |
| #1 | `0x0F1C7Cb26D6cD36BD4189E41947658b39437587A` | legacy v3 | 10 words | 18,817,867 |

Shared v4 infrastructure on Arc:

```
PoolManager       0x8366a39CC670B4001A1121B8F6A443A643e40951
StateView         0xF3334192D15450CdD385c8B70e03f9A6bD9E673b
PositionManager   0x6049c9a0e26405C0985f9E3685C87d0aE917f82B
UniversalRouter   0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1
USDC (ERC-20)     0x3600000000000000000000000000000000000000   6 decimals
```

> **The bundle says #6, the app launches on #7.** Portal #7 is the current
> new-launch target. The published bundle still names #6 as its top-level `portal`,
> and the example script hardcodes #6, #5 and #4, so a registry built from either
> alone misses #7 entirely. Add #7 from the bundle's `portal7` section and
> deduplicate addresses case-insensitively. **There is no Portal #8; do not infer
> one.**

## Find the launches

For each Portal, backfill from its own deploy block and follow its creation events,
or enumerate `tokenCount()` and `getTokens(offset, limit)` and then read each launch
record. Dispatch on the Portal family **and** the event signature together: a
similarly shaped decode can succeed and return wrong values.

v4 creation events, emitted by the Portal:

```solidity
event TokenCreated(address indexed token, address indexed creator,
    string name, string symbol, bytes32 poolId,
    string imageURI, string website, string twitter, string telegram);

event PartsDeployed(address indexed token, address locker, address hook, address splitter);

event CurveOpened(address indexed token, bytes32 indexed poolId, address locker,
    uint256 positionId, uint128 liquidity, int24 tickLower, int24 tickUpper);
```

```
topic0, v4  0x1d8917231579f8ce39407f0d616f36f357b07329b0ce5164d0754ac15145ce0a
topic0, v3  0x875522b092d9e19a1de359e4bd218090d582fa521c9733889acf1a5ff1941255
```

`TokenCreated.poolId` is in the event **data**, not an indexed topic. The legacy v3
event carries an `address pool` in the fifth position instead.

> **Absence has to be proved, not assumed.** `launches(token).creator ==
> address(0)` means that one Portal has no record for the token. Check the others
> before calling it non-Argus. A timeout, a provider error or an undecodable
> response is an *unresolved lookup*, not an absence. Matching symbols and matching
> hook permission bits prove nothing about origin.

## Decode the launch record

Select the Portal by address first, then query `LAUNCH_STRUCT_WORDS()` and validate
the exact returned length. Word count alone cannot separate #6 from #7, nor legacy v3
from a ten-word v4 record. Never decode an eleven-word result with a ten-output ABI
just because the decoder tolerates trailing data.

| Portal | Record, and how to tell it apart |
|---|---|
| #7 | 11 words, 352 bytes. `registry()` exists. Use the #7 launch and payout ABI. |
| #6 | 11 words, 352 bytes. No #7 routing discriminator. |
| #5 and #4 | 10 words, 320 bytes. Hooked record with no `quoteAsset`; the quote is USDC. |
| #3 | 9 words, 288 bytes. No `tickBond` and no `quoteAsset`; read bonding from the hook. |
| #2 and #1 | 10 words, 320 bytes, but a legacy v3 record with entirely different fields. |

The eleven-word hooked record, by index — see full field table and formats in
[`../onchain/launch-record-layout.md`](../onchain/launch-record-layout.md).

See also: [`../onchain/addresses.md`](../onchain/addresses.md),
[`08-integrate-markets.md`](08-integrate-markets.md)
