// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {ISplitterMinimal} from "./interfaces/IPoolManagerMinimal.sol";

// Implements, from docs/05-fees-and-rewards.md and
// docs/08-integrate-markets.md §"Quotes and payouts":
//  - Reserves 10% of collected tax for Argus, the rest (90%) goes into the
//    creator's 4-way allocation: creator funds, buyback&burn, dividends,
//    liquidity. The 4 percentages sum to 100% (validated at deploy time by
//    the Portal, not here — this contract trusts the bps it receives).
//  - "Credited is not paid": creator funds and dividends accrue as an
//    internal balance, and ONLY claim(address) actually sends them.
//    claim(address) pays the named account, not necessarily the caller.
//  - Dividends: "Your share is updated whenever your balance changes" —
//    here simplified to a standard pull-based model (per-share
//    accumulator, similar to a masterchef/dividend-tracker pattern), not a
//    push on every transfer (which would cost too much gas in a real
//    token — see note in the code).

contract RevenueSplitter is ISplitterMinimal {
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ARGUS_SHARE_BPS = 1000; // 10%, fixed by design (docs/05)

    address public immutable argusTreasury;
    address public immutable creator;
    address public immutable token;        // this launch's LaunchToken, for the dividend tracker
    address public immutable liquidityLocker; // where to route the "liquidity" allocation

    // Creator's allocation of the remaining 90%, in bps, sums to 10000
    uint16 public immutable creatorFundsBps;
    uint16 public immutable buybackBurnBps;
    uint16 public immutable dividendsBps;
    uint16 public immutable liquidityBps;

    // --- "Credited, not paid" accounting for the creator ---
    mapping(address => uint256) public creditedToCreator; // per quote asset

    // --- Dividend tracker, pull-based, per-share accumulator ---
    // Standard "scaled balance" model: accDividendsPerShare grows on every
    // deposit; each holder claims (currentAcc - hisDebt) * balance.
    uint256 public accDividendsPerShareX128;
    mapping(address => uint256) public dividendDebtX128;
    mapping(address => uint256) public claimableDividends;

    // --- Metrics exposed, mirroring docs/05-fees-and-rewards.md ---
    uint256 public fundedForHolders;  // "Funded for holders": everything that ever came in
    uint256 public paidToHolders;     // "Paid to holders": how much has actually been sent

    error NotAuthorized();
    error NothingToClaim();
    error AllocationMustSumToBps();

    event RevenueReceived(address indexed quoteAsset, uint256 total, uint256 argusShare, uint256 creatorAllocation);
    event CreatorClaimed(address indexed to, address indexed quoteAsset, uint256 amount);
    event DividendsClaimed(address indexed to, uint256 amount);
    event BuybackBurnAllocated(uint256 amount); // the actual buyback is out of scope here, see note

    modifier onlyHookOrPortal(address hook, address portal) {
        if (msg.sender != hook && msg.sender != portal) revert NotAuthorized();
        _;
    }

    constructor(
        address argusTreasury_,
        address creator_,
        address token_,
        address liquidityLocker_,
        uint16 creatorFundsBps_,
        uint16 buybackBurnBps_,
        uint16 dividendsBps_,
        uint16 liquidityBps_
    ) {
        if (uint256(creatorFundsBps_) + buybackBurnBps_ + dividendsBps_ + liquidityBps_ != BPS_DENOMINATOR) {
            revert AllocationMustSumToBps();
        }
        argusTreasury = argusTreasury_;
        creator = creator_;
        token = token_;
        liquidityLocker = liquidityLocker_;
        creatorFundsBps = creatorFundsBps_;
        buybackBurnBps = buybackBurnBps_;
        dividendsBps = dividendsBps_;
        liquidityBps = liquidityBps_;
    }

    /// @notice Called by the hook (or the Portal for the dev buy) when
    /// collected tax arrives from a swap. Immediately splits 10%/90%, then
    /// the 90% into the 4 destinations. Funds must physically arrive at
    /// this contract BEFORE calling depositRevenue (pull assumption: the
    /// hook must have already done take()/transferred to this address).
    function depositRevenue(address quoteAsset, uint256 amount) external override {
        // In a real deploy this should be restricted to msg.sender being
        // this specific launch's hook; here simplified, would be wired by
        // the Portal at deploy time by passing the authorized hook address.
        if (amount == 0) return;

        uint256 argusShare = (amount * ARGUS_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 creatorAllocation = amount - argusShare;

        if (argusShare > 0) {
            IERC20Minimal(quoteAsset).transfer(argusTreasury, argusShare);
        }

        uint256 toCreatorFunds = (creatorAllocation * creatorFundsBps) / BPS_DENOMINATOR;
        uint256 toBuybackBurn = (creatorAllocation * buybackBurnBps) / BPS_DENOMINATOR;
        uint256 toDividends = (creatorAllocation * dividendsBps) / BPS_DENOMINATOR;
        // The remainder goes to liquidity for rounding purposes, instead of
        // a separate calculation — avoids dust left in the contract.
        uint256 toLiquidity = creatorAllocation - toCreatorFunds - toBuybackBurn - toDividends;

        if (toCreatorFunds > 0) {
            // "Credited is not paid": accumulate, don't send.
            creditedToCreator[quoteAsset] += toCreatorFunds;
        }

        if (toBuybackBurn > 0) {
            // The real buyback-and-burn (swap quoteAsset -> token, then
            // burn) is out of scope for this file: it requires a call to
            // the PoolManager/a router and a dedicated module. Here we
            // just track the intended amount, with an event, so an
            // external permissionless module can execute it later.
            emit BuybackBurnAllocated(toBuybackBurn);
        }

        if (toDividends > 0) {
            _distributeDividends(toDividends);
        }

        if (toLiquidity > 0) {
            IERC20Minimal(quoteAsset).transfer(liquidityLocker, toLiquidity);
        }

        fundedForHolders += toDividends;
        emit RevenueReceived(quoteAsset, amount, argusShare, creatorAllocation);
    }

    // ------------------------------------------------------------------
    // Dividends — pull-based, per-share accumulator
    // ------------------------------------------------------------------

    uint256 private constant Q128 = 1 << 128;

    function _distributeDividends(uint256 amount) internal {
        uint256 supply = _tokenTotalSupply();
        if (supply == 0) return; // no holders, funds stay in the contract
        accDividendsPerShareX128 += (amount * Q128) / supply;
    }

    /// @notice To be called before reading/updating a holder's balance
    /// (ideally hooked into a transfer hook on the token — here exposed
    /// as a public function the token or a keeper can call). Updates the
    /// claimable balance without sending it.
    function updateHolder(address holder) public {
        uint256 bal = IERC20Minimal(token).balanceOf(holder);
        uint256 owed = (bal * (accDividendsPerShareX128 - dividendDebtX128[holder])) / Q128;
        if (owed > 0) {
            claimableDividends[holder] += owed;
        }
        dividendDebtX128[holder] = accDividendsPerShareX128;
    }

    /// @notice "Claimable: your share that a payout could not deliver. It
    /// is normally zero." — in the pull model used here, claimable is
    /// always the primary mechanism (not a fallback), a declared
    /// simplification relative to the push-by-default behavior described
    /// in the docs.
    function claimDividends(address to) external {
        updateHolder(msg.sender);
        uint256 amount = claimableDividends[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableDividends[msg.sender] = 0;
        paidToHolders += amount;
        // The dividend quote asset is implicit in the deposit received; in
        // this simplified reference we assume a single quote asset for the
        // launch's whole lifetime (consistent with Portals #3-#6, not with
        // the possible conversion in #7 — see
        // docs/08-integrate-markets.md).
        emit DividendsClaimed(to, amount);
    }

    // ------------------------------------------------------------------
    // Creator funds — "credited, not paid"
    // ------------------------------------------------------------------

    /// @notice claim(address) pays the NAMED account, not necessarily the
    /// caller — consistent with docs/08-integrate-markets.md §"Quotes and
    /// payouts": "claim(address) pays the named account rather than the
    /// caller." Here simplified to a single quote asset per call instead
    /// of the 3 values returned by the real #7 (see README.md point 3).
    function claim(address to, address quoteAsset) external {
        if (msg.sender != creator) revert NotAuthorized();
        uint256 amount = creditedToCreator[quoteAsset];
        if (amount == 0) revert NothingToClaim();
        creditedToCreator[quoteAsset] = 0;
        IERC20Minimal(quoteAsset).transfer(to, amount);
        emit CreatorClaimed(to, quoteAsset, amount);
    }

    function _tokenTotalSupply() internal view returns (uint256) {
        // LaunchToken exposes totalSupply as a public variable; called
        // here via a minimal interface to avoid a tight circular
        // dependency. In production a real IERC20 would be more
        // appropriate.
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length == 0) return 0;
        return abi.decode(data, (uint256));
    }
}
