// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


/// @notice Uniquely identifies a v4 pool. The real v4-core packs these
/// fields in a specific way; here they're kept explicit for readability.
/// See docs/08-integrate-markets.md §"Pool identity" for the real poolId
/// formula: keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks)).
struct PoolKey {
    address currency0; // numerically lower, sorted
    address currency1; // numerically higher, sorted
    uint24 fee;         // 10000 = 1%, for the Argus family (docs)
    int24 tickSpacing;  // 200 for the Argus family (docs)
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // positive = exact input, negative = exact output (v4 convention)
    uint160 sqrtPriceLimitX96;
}

interface IHooksMinimal {
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 deltaSpecified, uint24 lpFeeOverride);

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        int128 delta0,
        int128 delta1,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 deltaUnspecified);
}

interface IPoolManagerMinimal {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24 tick);

    /// @dev In real v4, liquidity is added via an unlock callback +
    /// modifyLiquidity, or more commonly through the peripheral
    /// PositionManager (see onchain/addresses.md). Here exposed as a direct
    /// function for the reference Portal's simplicity.
    function modifyLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external returns (int128 delta0, int128 delta1);

    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick);
}


interface ISplitterMinimal {
    function depositRevenue(address quoteAsset, uint256 amount) external;
}
