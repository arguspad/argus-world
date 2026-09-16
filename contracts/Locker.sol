// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {ISplitterMinimal} from "./interfaces/IPoolManagerMinimal.sol";

interface IPositionManagerMinimal {
    /// @dev The real v4 PositionManager has a different, richer signature
    /// (uses Actions/unlockData). Reduced here for readability — see
    /// onchain/addresses.md for the real Arc PositionManager address.
    function collect(uint256 positionId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1);
}

contract Locker {
    address public immutable positionManager;
    uint256 public immutable positionId;
    address public immutable splitter;
    address public immutable currency0;
    address public immutable currency1;

    bool private _initialized;

    error AlreadyInitialized();
    error NothingToHarvest();

    event FeesHarvested(uint256 amount0, uint256 amount1, address indexed caller);

    constructor(
        address positionManager_,
        address splitter_,
        address currency0_,
        address currency1_,
        uint256 positionId_
    ) {
        positionManager = positionManager_;
        splitter = splitter_;
        currency0 = currency0_;
        currency1 = currency1_;
        positionId = positionId_;
        // Note: the positionId is passed here by the Portal AFTER opening
        // the position (see Portal.sol, CurveOpened event). There's no
        // separate initialize(): the entire state is immutable from
        // deployment, to respect "no owner, no withdraw, no rescue" to the
        // letter — there isn't even a function that could, in theory, be
        // restricted later.
    }

    /// @notice Anyone can call this. Collects the position's fees and
    /// routes them to the splitter, which divides them using the same
    /// 10%/90% 4-way logic used for the tax — consistent with "harvested
    /// permissionlessly and split like the tax".
    function harvestFees() external {
        (uint256 amount0, uint256 amount1) =
            IPositionManagerMinimal(positionManager).collect(positionId, address(this));

        if (amount0 == 0 && amount1 == 0) revert NothingToHarvest();

        if (amount0 > 0) {
            IERC20Minimal(currency0).approve(splitter, amount0);
            ISplitterMinimal(splitter).depositRevenue(currency0, amount0);
        }
        if (amount1 > 0) {
            IERC20Minimal(currency1).approve(splitter, amount1);
            ISplitterMinimal(splitter).depositRevenue(currency1, amount1);
        }

        emit FeesHarvested(amount0, amount1, msg.sender);
    }

    // Deliberately NO OTHER function. No withdraw, no rescue, no way to
    // modify the position, no admin function of any kind — by
    // construction, not by convention.
}
