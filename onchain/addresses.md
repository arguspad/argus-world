## Network

| Field | Value |
|---|---|
| Network | Arc mainnet |
| Chain ID (from Argus docs) | **5042** (`0x13b2`) |
| Gas token | USDC (native on Arc) |

## The factories — Portal registry

The "Portal" is the factory: it creates launches and records the token, hook,
locker, splitter and pool relationship. **There is no single Argus pool
contract and no single Argus hook** — every launch has its own hook.

| Portal | Address | Family | Words in record | Start block |
|---|---|---|---|---|
| **#7 — current target for new launches** | `0xB021Be536808f551b31789422Fd28a6c9c6e97Da` | hooked v4 | 11 | 20,395,275 |
| #6 | `0xA5628A11c412596E1f63b75a2C0284F843C549d6` | hooked v4 | 11 | 20,240,260 |
| #5 | `0x07a688a001f416cC433c68Ff56Aa26bC5131Cc6E` | hooked v4 | 10 | 20,081,606 |
| #4 | `0xa36c443A797771Df82533B8B4A86F0AFfd970862` | hooked v4 | 10 | 19,690,658 |
| #3 | `0x7A17Ab0106C46C0be30623F3EB7F299CC0058338` | hooked v4 | 9 | 19,674,154 |
| #2 | `0xBed9880A0ba12722ba4b8791c0B6F8c74338246C` | legacy v3 | 10 | 19,056,397 |
| #1 | `0x0F1C7Cb26D6cD36BD4189E41947658b39437587A` | legacy v3 | 10 | 18,817,867 |

Rule: **index every Portal, never just the current one.** A newer Portal never
replaces the contracts of tokens already launched by an earlier Portal.

## Shared v4 infrastructure

| Contract | Address | Notes |
|---|---|---|
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | Shared storage/execution for all v4 pools. Index by pool id, never by manager address alone. |
| StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` | `getSlot0(poolId)`, `getLiquidity(poolId)` |
| PositionManager | `0x6049c9a0e26405C0985f9E3685C87d0aE917f82B` | |
| UniversalRouter | `0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1` | |
| USDC (ERC-20) | `0x3600000000000000000000000000000000000000` | 6 decimals. Careful: native gas accounting uses 18 decimals — they are not the same "asset" for accounting purposes. |

## Per-launch contracts (no fixed address — one per token)

| Role | Where to find it |
|---|---|
| Hook | Emitted in `PartsDeployed(token, locker, hook, splitter)` by the Portal |
| Locker | Same — holds the launch's liquidity position, is not a pool address |
| Splitter | Same — accounts for revenue and payouts, version-specific per Portal |


## Published ABI/addresses bundle

```
https://arguspad.io/argus-v4.json           v4 hooked family, version 3, generated 2026-09-12
https://arguspad.io/argus-abi.json          legacy v3 launches
https://arguspad.io/argus-v4-example.mjs    partial example (hardcodes only Portals #6, #5, #4 — missing #7)

sha256(argus-v4.json) = 94f7e126fd2f0a9fe34f1c4b82d7f8082eef9757a5822895f3c0a6d1c9d3da1f
```
