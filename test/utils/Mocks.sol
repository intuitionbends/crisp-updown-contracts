// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @notice 18-decimal token shaped like BSC USDT: plain ERC-20, no permit, returns bool.
contract MockUSDT {
    string public constant name = "Tether USD";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// When set, transfers and transferFrom return false instead of moving anything.
    bool public returnFalse;
    /// Everything `from` has ever sent to `to`, and in all: lets invariant tests see where money left to.
    mapping(address from => mapping(address to => uint256)) public sent;
    mapping(address from => uint256) public totalSent;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        sent[from][to] += amount;
        totalSent[from] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice A smart account that answers ERC-1271 for signatures by its owner key, standing in for Kernel 0.3.1.
/// @dev    Real Kernel wraps the digest in its own EIP-712 domain before its ECDSA validator checks it; the
///         ZeroDev SDK's signTypedData does that wrapping. The vault only ever passes its own digest, so this mock
///         exercises the vault's side of the check, not Kernel's.
contract MockSmartAccount {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice A contract account that does not implement ERC-1271 at all.
contract NoSigAccount {}
