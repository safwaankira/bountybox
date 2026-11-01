// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Test-only 6-decimal ERC-20 with (a) a Circle-USDC-style blocklist and (b) a switchable
///      transferFrom failure mode. Standalone: does not touch the shared MockUSDC.
///      Blocklist semantics mirror Circle USDC: transfer() reverts if the caller (sender) or the
///      recipient is blocklisted; transferFrom() reverts if the spender, the owner or the recipient is.
contract ConfigurableUSDC {
    enum FromMode {
        Normal,
        Revert, // transferFrom always reverts
        ReturnFalse // transferFrom does nothing and returns false
    }

    string public name = "Configurable USDC";
    string public symbol = "cUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    FromMode public fromMode;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocklisted;

    error Blocklisted(address account);
    error TransferFromDisabled();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setBlocklisted(address account, bool on) external {
        blocklisted[account] = on;
    }

    function setFromMode(FromMode m) external {
        fromMode = m;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _notBlocked(msg.sender);
        _notBlocked(to);
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (fromMode == FromMode.Revert) revert TransferFromDisabled();
        if (fromMode == FromMode.ReturnFalse) return false;
        _notBlocked(msg.sender);
        _notBlocked(from);
        _notBlocked(to);
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function _notBlocked(address account) internal view {
        if (blocklisted[account]) revert Blocklisted(account);
    }

    function _move(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
    }
}
