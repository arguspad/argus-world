// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


// Implements: docs/08-integrate-markets.md §"Fees and bonding" —
// "v4 launch tokens have no transfer tax. The tax is applied by the pool's
// hook on swaps, so a wallet-to-wallet transfer pays nothing."

interface IERC20Events {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract LaunchToken is IERC20Events {
    // --- Metadata, set once in initialize() ---
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    // --- Standard ERC-20 state ---
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- Initialization guard for the clone pattern ---
    bool private _initialized;

    // The Portal that created this token, for reference/downstream events.
    // It has NO special permissions here: no mint, no pause, no blacklist.
    // Consistent with "Tax rates and allocation cannot be changed after
    // launch" and with the absence of any tax logic in the token itself.
    address public immutable factory;

    error AlreadyInitialized();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroAddress();

    constructor() {
        // The constructor only runs on the "implementation" contract
        // deployed once by the Portal, never on the clones (clones don't
        // execute a constructor, by definition of EIP-1167). We set
        // `factory` here so it's known on the implementation itself; the
        // clones read it via delegatecall and will only see the right
        // value if it's also set in initialize() — see below.
        factory = msg.sender;
    }

    /// @notice Initializes a clone freshly deployed by the Portal.
    /// @dev No later minting: the entire supply is minted here, in one go,
    ///      received by the Portal (which then deposits it into the v4
    ///      position — see Portal.sol). This mirrors
    ///      docs/08-integrate-markets.md: "None. No curve contract, no
    ///      virtual reserves. The whole supply sits in one v4 position
    ///      above the opening price."
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        address mintTo_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        name = name_;
        symbol = symbol_;

        totalSupply = initialSupply_;
        balanceOf[mintTo_] = initialSupply_;
        emit Transfer(address(0), mintTo_, initialSupply_);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        // No tax here, deliberately: see the comment at the top of the file.
        emit Transfer(from, to, amount);
    }
}
