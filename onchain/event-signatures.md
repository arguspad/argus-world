# Events for discovering and indexing launches

## Events emitted by the Portal (v4 family)

```solidity
event TokenCreated(address indexed token, address indexed creator,
    string name, string symbol, bytes32 poolId,
    string imageURI, string website, string twitter, string telegram);

event PartsDeployed(address indexed token, address locker, address hook, address splitter);

event CurveOpened(address indexed token, bytes32 indexed poolId, address locker,
    uint256 positionId, uint128 liquidity, int24 tickLower, int24 tickUpper);
```

`TokenCreated.poolId` is in the event **data**, not an indexed topic.

## Topic0

```
v4  0x1d8917231579f8ce39407f0d616f36f357b07329b0ce5164d0754ac15145ce0a
v3  0x875522b092d9e19a1de359e4bd218090d582fa521c9733889acf1a5ff1941255
```

The legacy v3 event carries an `address pool` in the fifth position instead
of the poolId.

## PoolManager events (v4, shared across all pools)

To be indexed by `poolId`, not just by manager address:

- `Initialize` — maps a pool to currencies, fee, spacing, hook
- `Swap`
- `ModifyLiquidity`
- `Donate`

The pool id is indexed in topic 1 of each of these.

## Deduplication / robustness rules

- Deduplicate by (chain, transaction hash, log index); keep canonical block
  hashes so a reorg stays recoverable.
- `launches(token).creator == address(0)` on one Portal only means *that*
  Portal has no record — check the others before concluding "not Argus."
- A timeout, a provider error, or an undecodable response is an **unresolved
  lookup**, not an absence.
- Matching symbols or matching hook permission bits prove nothing about
  origin.
