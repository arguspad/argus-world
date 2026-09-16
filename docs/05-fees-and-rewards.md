# Fees & rewards

Understand buy and sell tax, the allocation, and the holder rewards shown on a token
page.

## Tax rate and allocation

The buy or sell tax rate determines the tax on that side of a trade. The allocation
describes how the collected tax is divided. They are different percentages, applied
at different stages.

The launch settings reserve **10%** of collected tax for Argus. The creator's
four-way allocation applies to the remaining **90%**.

Example, with 100 USDC of tax already collected (not a 100 USDC trade):

| Destination | Example split |
|---|---|
| Argus share | 10 USDC (fixed 10% of collected tax) |
| To creator's allocation | 90 USDC, split across the 4 destinations below |

## The four destinations

| Allocation | Purpose in the launch settings |
|---|---|
| Creator funds | USDC directed to the creator's wallet. |
| Buyback and burn | An allocation for buying back and burning tokens. |
| Dividends | An allocation for USDC rewards to token holders. |
| Liquidity | An allocation for adding liquidity to the pool. |

A destination can have a zero allocation. A preset is a starting configuration, so
read the actual rates and split shown for the token you are viewing.

## Read your holder rewards

Dividends are automatic. Your share is updated whenever your balance changes, and
each payout is sent to your wallet. Holding the token is the whole requirement, and
in the normal case there is nothing to claim.

The "Fees and dividends" row tracks the token's whole pot. The "Account" tab tracks
your wallet's part of it.

| Metric | Meaning |
|---|---|
| Funded for holders | Everything moved into this token's dividend tracker, all time. |
| Paid to holders | What the tracker has actually sent out, read live from the tracker rather than from the index. |
| Waiting for holders | Funded but not yet sent. It is already the holders' money and goes out on the next payout. |
| Received | Dividends paid to your wallet since launch. |
| Claimable | Your share that a payout could not deliver. It is normally zero. |

> **When a Claim button appears.** A payout can fail if your address cannot receive
> the asset this launch pays in. The amount is kept rather than lost, and a Claim
> button appears beside Claimable, naming that asset, so you can pull it yourself.
> You can withdraw at any time without waiting for a payout.

> **Creator funds are different.** The creator's share of tax is credited and waits
> to be claimed. That is a separate pot from holder dividends and it belongs to the
> creator alone. Holding a token never puts anything there.

> **No dividends allocation.** If the token allocates 0% to dividends, the page shows
> where its tax goes instead. Holding a token does not by itself imply that a reward
> is available.

See also: [`onchain/pool-math.md`](../onchain/pool-math.md) for how tax and bonding
are actually computed and read on-chain (this page describes the product-level view
only; the enforcement mechanism differs — see that file for the important caveat that
**v4 launch tokens have no transfer tax**, the tax lives in the pool hook).
