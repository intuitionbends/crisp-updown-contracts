// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {UpDownVault} from "../../src/UpDownVault.sol";

/// @notice An account whose isValidSignature answers with a megabyte of data.
contract ReturnBombAccount {
    fallback() external {
        assembly {
            return(0, 1000000)
        }
    }
}

/// @notice An account whose isValidSignature burns all the gas it is given.
contract GasBurnAccount {
    fallback() external {
        while (true) {}
    }
}

/// @notice An account that says yes to every signature.
contract YesAccount {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

/// @notice A token whose transfer and transferFrom return nothing (Ethereum mainnet USDT's shape).
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        require(balanceOf[msg.sender] >= a);
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        require(allowance[f][msg.sender] >= a && balanceOf[f] >= a);
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}

/// @notice A token that keeps 1% of every transfer.
contract FeeOnTransferToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        balanceOf[f] -= a;
        balanceOf[to] += a - a / 100;
    }
}

interface IHook {
    function onTokenReceived(uint256 amount) external;
}

/// @notice A token that calls the recipient after every transfer, so a recipient can re-enter the vault.
contract HookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (to.code.length != 0) IHook(to).onTokenReceived(a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @notice A player account that tries to re-enter `recall` or `exit` whenever it receives the token.
contract ReentrantPlayer {
    UpDownVault public vault;
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    uint8 public mode; // 1 = recall again, 2 = exit again
    uint256 public reentries;
    uint256 public reentrySucceeded;

    function setVault(UpDownVault v) external {
        vault = v;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function approve(address token, address spender) external {
        HookToken(token).approve(spender, type(uint256).max);
    }

    function recall(uint256 amount) external {
        vault.recall(address(this), amount);
    }

    function exit() external {
        vault.exit();
    }

    function onTokenReceived(uint256) external {
        if (reentries != 0) return;
        reentries++;
        if (mode == 1) {
            try vault.recall(address(this), type(uint256).max) {
                reentrySucceeded++;
            } catch {}
        } else if (mode == 2) {
            try vault.exit() {
                reentrySucceeded++;
            } catch {}
        }
    }
}
