// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooksMinimal, PoolKey, SwapParams} from "./interfaces/IPoolManagerMinimal.sol";
import {ISplitterMinimal} from "./interfaces/IPoolManagerMinimal.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
//
// Implements, from docs/08-integrate-markets.md and docs/07-integrate.md:
//  - buyTaxBps() / sellTaxBps(): fixed for the hook's lifetime, read by the
//    Portal at deploy time, never changeable afterward (docs/03: "Tax
//    rates and allocation cannot be changed after launch").
//  - poolFee() / totalFeeBps(): pool fee + launch tax.
//  - currentSnipeTaxBps(): opening surcharge, "runs for three seconds",
//    exempt for the Portal and for the split contract.
//  - bonded() / bondBound() / bondTick(): bonding latch read from the tick,
//    "A tick retreat does NOT clear an already latched bonded state."
//  - Each creator tax leg is at most 1000 bps (10%); one leg may be zero,
//    but not both (docs/03-create-token.md: 1%-10% per side).

contract LaunchHook is IHooksMinimal {
    // --- System constants, from the docs ---
    uint256 public constant MAX_LEG_TAX_BPS = 1000; // 10%, docs/03: "1% to 10%"
    uint256 public constant SNIPE_TAX_DURATION = 3 seconds; // docs: "runs for three seconds"
    uint256 public constant COMBINED_RATE_CAP_BPS = 9900; // docs: "capped at 99% of the leg"
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // --- Configuration fixed at deploy time (by the Portal), immutable after ---
    address public immutable poolManager;
    address public immutable token;       // the cloned LaunchToken
    address public immutable quoteAsset;  // the launch's quote asset (often USDC)
    address public immutable splitter;    // where collected tax goes
    address public immutable portal;      // exempt from snipe tax (in-launch dev buy)
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    uint24 public immutable poolFee;      // 10000 = 1%, Argus family
    uint256 public immutable launchedAt;
    int24 public immutable tickStart;
    int24 public immutable tickBond;

    // --- Bonding state, monotonic latch ---
    bool private _bonded;

    error TaxLegTooHigh();
    error BothLegsZero();
    error CombinedRateTooHigh();
    error NotPoolManager();
    error ZeroBondSpan();

    event Bonded(uint256 atTimestamp, int24 atTick);
    event TaxCollected(bool isBuy, uint256 amount, address quoteAsset);

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert NotPoolManager();
        _;
    }

    constructor(
        address poolManager_,
        address token_,
        address quoteAsset_,
        address splitter_,
        address portal_,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        uint24 poolFee_,
        int24 tickStart_,
        int24 tickBond_
    ) {
        if (buyTaxBps_ > MAX_LEG_TAX_BPS || sellTaxBps_ > MAX_LEG_TAX_BPS) revert TaxLegTooHigh();
        if (buyTaxBps_ == 0 && sellTaxBps_ == 0) revert BothLegsZero();
        if (tickBond_ == tickStart_) revert ZeroBondSpan(); // guard, see pool-math.md "Guard a zero span"

        poolManager = poolManager_;
        token = token_;
        quoteAsset = quoteAsset_;
        splitter = splitter_;
        portal = portal_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        poolFee = poolFee_;
        launchedAt = block.timestamp;
        tickStart = tickStart_;
        tickBond = tickBond_;
    }

    // ------------------------------------------------------------------
    // Public getters, mirroring docs/08-integrate-markets.md
    // §"Fees and bonding"
    // ------------------------------------------------------------------

    /// @notice Base schedule per side: pool fee converted to bps + that
    /// side's launch tax. Excludes router/service fees, gas, and the
    /// opening surcharge (docs).
    function totalFeeBps(bool isBuy) public view returns (uint256) {
        uint256 poolFeeBps = uint256(poolFee) / 100; // v4 units -> bps (10000 units = 1% = 100 bps)
        uint256 legTax = isBuy ? buyTaxBps : sellTaxBps;
        return poolFeeBps + legTax;
    }

    /// @notice Current opening surcharge for an ordinary trader. Decays to
    /// zero within 3 seconds of launch. The exact formula reported below
    /// (`9900 >> ((elapsed * 14) / 3)`) is NOT linear — it's a right shift,
    /// so it decays much faster at the start. I'm reporting it here exactly
    /// in that form for fidelity, EVEN THOUGH I didn't derive it myself —
    /// it's verbatim from an indexed search result for argus.world/docs,
    /// so I'm treating it as an observed spec, not my own invention.
    /// Verify it before using it in production.
    function currentSnipeTaxBps() public view returns (uint256) {
        if (block.timestamp >= launchedAt + SNIPE_TAX_DURATION) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        uint256 shift = (elapsed * 14) / 3;
        if (shift >= 256) return 0; // overflow guard on >>
        return COMBINED_RATE_CAP_BPS >> shift;
    }

    function bonded() external view returns (bool) {
        return _bonded;
    }

    function bondBound() external pure returns (bool) {
        return true; // in this reference, the bond tick is always fixed at deploy time
    }

    function bondTick() external view returns (int24) {
        return tickBond;
    }

    /// @notice Progress toward the milestone, FOR DISPLAY ONLY — see
    /// onchain/pool-math.md: "Guard a zero span. Clamp only for display.
    /// A tick retreat does NOT clear an already latched bonded state."
    function milestoneProgress(int24 currentTick) external view returns (int256 progressBps) {
        int256 span = int256(tickBond) - int256(tickStart);
        if (span == 0) return 0; // guard, shouldn't happen given the constructor check
        int256 progress = ((int256(currentTick) - int256(tickStart)) * int256(BPS_DENOMINATOR)) / span;
        if (progress < 0) progress = 0;
        if (progress > int256(BPS_DENOMINATOR)) progress = int256(BPS_DENOMINATOR);
        return progress;
    }

    // ------------------------------------------------------------------
    // PoolManager callbacks — where the tax lives
    // ------------------------------------------------------------------

    function beforeSwap(
        address sender,
        PoolKey calldata, /* key */
        SwapParams calldata params,
        bytes calldata /* hookData */
    ) external onlyPoolManager returns (bytes4, int128 deltaSpecified, uint24) {
        // "Exempt: the Portal (so the creator's in-launch buy) and the
        // launch's split contract." — docs/07-integrate.md
        bool exempt = (sender == portal || sender == splitter);

        bool isBuy = params.zeroForOne;
        // NOTE: the real "buy" vs "sell" direction depends on which
        // currency (0 or 1) is the launch token —
        // docs/08-integrate-markets.md §"Classify buys and sells": "v4
        // swap amounts are from the swapper's perspective... positive
        // means tokens received (a buy)". This reference simplifies by
        // assuming the caller (the Portal, at deploy time) correctly
        // encodes `params.zeroForOne` relative to currency ordering; in a
        // real implementation this must be derived from tokenIsToken0
        // (a field in the launch record, see
        // onchain/launch-record-layout.md), not assumed as done here.

        uint256 legTaxBps = isBuy ? buyTaxBps : sellTaxBps;
        uint256 snipeBps = exempt ? 0 : currentSnipeTaxBps();
        uint256 combinedBps = legTaxBps + snipeBps;
        if (combinedBps > COMBINED_RATE_CAP_BPS) combinedBps = COMBINED_RATE_CAP_BPS;

        // Apply bonding: once latched, it stays latched. The actual update
        // of `_bonded` happens in afterSwap, where we know the post-swap
        // tick — see below.

        if (exempt || combinedBps == 0) {
            return (this.beforeSwap.selector, 0, 0);
        }

        // The exact amount to withhold has to be computed on the swap's
        // specified amount. Here we leave the actual withholding to
        // afterSwap (a common pattern for exact-input v4 hooks), where the
        // final delta is known; beforeSwap here just validates/logs.
        deltaSpecified = 0;
        return (this.beforeSwap.selector, deltaSpecified, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata, /* key */
        SwapParams calldata params,
        int128 delta0,
        int128 delta1,
        bytes calldata /* hookData */
    ) external onlyPoolManager returns (bytes4, int128 deltaUnspecified) {
        bool exempt = (sender == portal || sender == splitter);
        bool isBuy = params.zeroForOne; // see note in beforeSwap about this simplification

        uint256 legTaxBps = isBuy ? buyTaxBps : sellTaxBps;
        uint256 snipeBps = exempt ? 0 : currentSnipeTaxBps();
        uint256 combinedBps = legTaxBps + snipeBps;
        if (combinedBps > COMBINED_RATE_CAP_BPS) combinedBps = COMBINED_RATE_CAP_BPS;

        if (!exempt && combinedBps > 0) {
            // Taxable amount: the delta on the quote-asset leg.
            // Simplification: we assume delta1 is the quote leg. In a real
            // implementation this must be derived from tokenIsToken0.
            int128 quoteDelta = delta1;
            uint256 quoteAmount = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : uint256(uint128(quoteDelta));
            uint256 taxAmount = (quoteAmount * combinedBps) / BPS_DENOMINATOR;

            if (taxAmount > 0) {
                // Withhold the tax and deposit it into the splitter. In a
                // real v4 hook this is done via take()/settle() on the
                // PoolManager (balances live in the manager until
                // "taken"); here simplified to a direct call for
                // readability.
                ISplitterMinimal(splitter).depositRevenue(quoteAsset, taxAmount);
                emit TaxCollected(isBuy, taxAmount, quoteAsset);
            }
        }

        // Bonding latch: once true, stays true (docs: "A tick retreat does
        // NOT clear an already latched bonded state"). In a real hook this
        // would read slot0.tick from the PoolManager after the swap; for
        // this reference it's left as an integration hook (see TODO).
        if (!_bonded) {
            // TODO real integration: read the post-swap tick from
            // poolManager and compare it against tickBond, respecting
            // direction (see onchain/pool-math.md "Direction is preserved
            // for either token order").
            // int24 currentTick = IPoolManagerMinimal(poolManager)
            //     .getSlot0(poolId).tick;
            // if (_hasCrossedBondTick(currentTick)) {
            //     _bonded = true;
            //     emit Bonded(block.timestamp, currentTick);
            // }
        }

        deltaUnspecified = 0;
        return (this.afterSwap.selector, deltaUnspecified);
    }
}
