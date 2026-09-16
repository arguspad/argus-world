// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "./libraries/Clones.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {LaunchHook} from "./LaunchHook.sol";
import {RevenueSplitter} from "./RevenueSplitter.sol";
import {Locker} from "./Locker.sol";
import {IPoolManagerMinimal, PoolKey} from "./interfaces/IPoolManagerMinimal.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

// Implements, from docs/07-integrate.md and docs/03-create-token.md:
//  - createLaunch(): clones the LaunchToken, deploys hook/locker/splitter,
//    initializes the v4 pool, opens the position with the full supply,
//    emits the EXACT documented events (same signature as TokenCreated,
//    PartsDeployed, CurveOpened reported in docs/07-integrate.md).
//  - The 4 allocation percentages must sum to 100% (validated here, not in
//    the splitter).
//  - Buy/sell tax: 1%-10% per side, not both zero (validated in the hook,
//    repeated here to fail early and save gas).
//  - launches(token): public registry for discovery (docs: "Select the
//    Portal by address first, then query LAUNCH_STRUCT_WORDS()").
//

contract Portal {
    // --- Events with the SAME signature documented in
    // docs/07-integrate.md "Find the launches", for compatibility with
    // indexers written against that specific spec. ---
    event TokenCreated(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        bytes32 poolId,
        string imageURI,
        string website,
        string twitter,
        string telegram
    );
    event PartsDeployed(address indexed token, address locker, address hook, address splitter);
    event CurveOpened(
        address indexed token,
        bytes32 indexed poolId,
        address locker,
        uint256 positionId,
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper
    );

    struct LaunchRecord {
        address creator;
        int24 tickStart;
        bool tokenIsToken0;
        address locker;
        address hook;
        address splitter;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint256 positionId;
        int24 tickBond;
        address quoteAsset;
    }

    // --- Immutable Portal configuration ---
    address public immutable tokenImplementation; // deployed once, cloned on every launch
    address public immutable poolManager;
    address public immutable positionManager;
    address public immutable argusTreasury;
    uint24 public constant POOL_FEE = 10_000;   // 1%, Argus family (docs)
    int24 public constant TICK_SPACING = 200;   // Argus family (docs)
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether; // see note in createLaunch

    mapping(address => LaunchRecord) public launches;
    address[] public allTokens;

    error InvalidAllocation();
    error InvalidTax();
    error NotCreator();

    constructor(
        address tokenImplementation_,
        address poolManager_,
        address positionManager_,
        address argusTreasury_
    ) {
        tokenImplementation = tokenImplementation_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        argusTreasury = argusTreasury_;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function getTokens(uint256 offset, uint256 limit) external view returns (address[] memory out) {
        uint256 end = offset + limit;
        if (end > allTokens.length) end = allTokens.length;
        if (offset >= end) return new address[](0);
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = allTokens[i];
        }
    }

    function LAUNCH_STRUCT_WORDS() external pure returns (uint256) {
        return 11; // eleven-word hooked record, see onchain/launch-record-layout.md
    }

    struct CreateLaunchParams {
        string name;
        string symbol;
        string imageURI;
        string website;
        string twitter;
        string telegram;
        address quoteAsset;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 creatorFundsBps;
        uint16 buybackBurnBps;
        uint16 dividendsBps;
        uint16 liquidityBps;
        uint160 openingSqrtPriceX96;
        int24 tickStart;
        int24 tickBond;
        uint256 devBuyAmount; // 0 = no dev buy, docs/03
    }

    /// @notice Creates a new launch: clones the token, deploys hook/locker/
    /// splitter, initializes the v4 pool and opens the position with the
    /// full supply. Anyone can call it (permissionless by design,
    /// consistent with "Argus is a permissionless token launchpad" - page
    /// indexed for argus.world).
    function createLaunch(CreateLaunchParams calldata p) external returns (address token) {
        if (p.buyTaxBps == 0 && p.sellTaxBps == 0) revert InvalidTax();
        if (p.buyTaxBps > 1000 || p.sellTaxBps > 1000) revert InvalidTax();
        uint256 allocSum = uint256(p.creatorFundsBps) + p.buybackBurnBps + p.dividendsBps + p.liquidityBps;
        if (allocSum != 10_000) revert InvalidAllocation();

        // 1. Clone the token and mint it entirely to this Portal (which
        //    then deposits it into the v4 position). "None. No curve
        //    contract, no virtual reserves. The whole supply sits in one
        //    v4 position above the opening price." -
        //    docs/08-integrate-markets.md
        token = Clones.clone(tokenImplementation);
        LaunchToken(token).initialize(p.name, p.symbol, TOTAL_SUPPLY, address(this));

        bool tokenIsToken0 = token < p.quoteAsset;
        address currency0 = tokenIsToken0 ? token : p.quoteAsset;
        address currency1 = tokenIsToken0 ? p.quoteAsset : token;

        // 2. Deploy splitter and locker before the hook, since the hook
        //    references them as immutables.
        RevenueSplitter splitter = new RevenueSplitter(
            argusTreasury,
            msg.sender, // creator = whoever calls createLaunch
            token,
            address(0), // locker updated below - see note
            p.creatorFundsBps,
            p.buybackBurnBps,
            p.dividendsBps,
            p.liquidityBps
        );
        // NOTE: RevenueSplitter above takes `address(0)` as
        // liquidityLocker because the actual Locker needs the
        // positionId, only known AFTER opening the position (step 5). In
        // this simplified reference this creates a circular dependency
        // that should be solved with a two-phase pattern
        // (deploy + initialize()), as already done for LaunchToken -
        // instead of an immutable value - flagged here as a known
        // limitation, not silently swept under the rug.

        LaunchHook hook = new LaunchHook(
            poolManager,
            token,
            p.quoteAsset,
            address(splitter),
            address(this), // portal, exempt from snipe tax
            p.buyTaxBps,
            p.sellTaxBps,
            POOL_FEE,
            p.tickStart,
            p.tickBond
        );

        // 3. Initialize the v4 pool.
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        IPoolManagerMinimal(poolManager).initialize(key, p.openingSqrtPriceX96);
        bytes32 poolId = keccak256(abi.encode(currency0, currency1, POOL_FEE, TICK_SPACING, address(hook)));

        // 4. Open the position with the full supply, above the opening
        //    price (docs: "above the opening price, and buys walk the
        //    price up through it").
        IERC20Minimal(token).approve(poolManager, TOTAL_SUPPLY);
        (int128 delta0, int128 delta1) = IPoolManagerMinimal(poolManager).modifyLiquidity(
            key,
            p.tickStart,
            p.tickBond,
            int256(TOTAL_SUPPLY) // positive liquidityDelta = adding, simplified
        );
        uint256 positionId = uint256(poolId); // placeholder: in real v4 the
        // positionId comes from the PositionManager (an NFT), not derived
        // from the poolId. Simplified here because this Portal uses "raw"
        // modifyLiquidity on the PoolManager instead of the peripheral
        // PositionManager.

        // 5. Deploy the Locker with the now-known positionId, and it holds
        //    the position.
        Locker locker = new Locker(positionManager, address(splitter), currency0, currency1, positionId);

        // 6. Optional dev buy, exempt from the opening tax (docs/07:
        //    "Exempt: the Portal (so the creator's in-launch buy)").
        if (p.devBuyAmount > 0) {
            // Left as an explicit TODO: requires a real swap() call on the
            // PoolManager with the Portal as the exempt sender - omitted
            // here to keep the file readable, but the exemption is
            // already wired into the hook (see
            // LaunchHook.beforeSwap/afterSwap, the `sender == portal`
            // check).
        }

        // 7. Register the launch record and emit the EXACT documented
        //    events.
        launches[token] = LaunchRecord({
            creator: msg.sender,
            tickStart: p.tickStart,
            tokenIsToken0: tokenIsToken0,
            locker: address(locker),
            hook: address(hook),
            splitter: address(splitter),
            buyTaxBps: p.buyTaxBps,
            sellTaxBps: p.sellTaxBps,
            positionId: positionId,
            tickBond: p.tickBond,
            quoteAsset: p.quoteAsset
        });
        allTokens.push(token);

        emit TokenCreated(
            token, msg.sender, p.name, p.symbol, poolId, p.imageURI, p.website, p.twitter, p.telegram
        );
        emit PartsDeployed(token, address(locker), address(hook), address(splitter));
        emit CurveOpened(
            token,
            poolId,
            address(locker),
            positionId,
            uint128(uint256(int256(TOTAL_SUPPLY))),
            p.tickStart,
            p.tickBond
        );
    }
}
