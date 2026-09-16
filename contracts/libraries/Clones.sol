// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Equivalent to OpenZeppelin's Clones.clone() — rewritten here to keep this
// folder free of external dependencies to install.

library Clones {
    error CloneDeploymentFailed();

    function clone(address implementation) internal returns (address instance) {
        assembly {
            // Builds in memory:
            // 3d602d80600a3d3981f3 363d3d373d3d3d363d73 <addr> 5af43d82803e903d91602b57fd5bf3
            // The first 10 bytes (3d602d80600a3d3981f3) are the standard
            // "creation prefix" that then RETURNS exactly the 45 bytes of
            // runtime code observed on-chain.
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d730000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf3000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneDeploymentFailed();
    }
}
