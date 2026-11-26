// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {UpDownVault} from "../src/UpDownVault.sol";
import {TestUSDT} from "./TestUSDT.sol";

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// @notice Deploys UpDownVault to BSC mainnet (on BSC USDT) or BSC testnet (on a test USDT this script deploys,
///         unless TEST_TOKEN names one already deployed).
///
/// Role addresses come from the environment; every other setting is written here so it is reviewed in the code:
///   VAULT_ADMIN, VAULT_OPERATOR, VAULT_ORACLE, VAULT_GUARDIAN, VAULT_FEE_RECIPIENT
///
/// Dry run (no signer, nothing sent):
///   forge script script/DeployUpDownVault.s.sol --rpc-url https://bsc-testnet-dataseed.bnbchain.org
/// Broadcast (asks for the keystore password):
///   forge script script/DeployUpDownVault.s.sol --rpc-url https://bsc-testnet-dataseed.bnbchain.org \
///     --keystore <path> --broadcast --slow
contract DeployUpDownVault is Script {
    uint256 internal constant BSC_MAINNET = 56;
    uint256 internal constant BSC_TESTNET = 97;
    address internal constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;

    function config(address token) public view returns (UpDownVault.Config memory c) {
        c = UpDownVault.Config({
            token: token,
            admin: vm.envAddress("VAULT_ADMIN"),
            operator: vm.envAddress("VAULT_OPERATOR"),
            oracle: vm.envAddress("VAULT_ORACLE"),
            guardian: vm.envAddress("VAULT_GUARDIAN"),
            feeRecipient: vm.envAddress("VAULT_FEE_RECIPIENT"),
            unit: 1e16, // one cent: stakes are whole cents; fee and payout round down to the cent
            feeLimitBps: 500, // fixed fee limit, 5%; the ceiling starts at 0 until the admin sets it
            feeRoundsUp: false, // fee rounds down to the cent
            silenceSeconds: 6 hours, // operator silence (or a call this old) before exit opens
            dayOffsetSeconds: 8 hours, // daily loss limit day starts at midnight UTC+8
            maxPriceX100: 500, // price ceiling, 5.00x (the engine's prices run 1.18 to 4.75)
            maxOvershootSeconds: 20, // settle no later than 20 s past the settle time (engine late_tick)
            maxEntryLag: 3, // entry reading at most 3 readings after the one the player saw
            keyChangeDelay: 24 hours // wait before a new operator, oracle or guardian key takes effect
        });
    }

    function run() external returns (UpDownVault vault, address token) {
        require(block.chainid == BSC_MAINNET || block.chainid == BSC_TESTNET, "not BSC mainnet (56) or testnet (97)");

        vm.startBroadcast();
        if (block.chainid == BSC_MAINNET) {
            token = BSC_USDT;
        } else {
            token = vm.envOr("TEST_TOKEN", address(0));
            if (token == address(0)) token = address(new TestUSDT());
        }
        UpDownVault.Config memory c = config(token);
        _checkBefore(c);
        vault = new UpDownVault(c);
        vm.stopBroadcast();

        _checkAfter(vault, c);
        console.log("token          ", token);
        console.log("UpDownVault deployed at", address(vault));
    }

    function _checkBefore(UpDownVault.Config memory c) internal view {
        require(c.token.code.length != 0, "no token at the USDT address");
        require(IERC20Meta(c.token).decimals() == 18, "USDT is not 18 decimals");
        bytes32 sym = keccak256(bytes(IERC20Meta(c.token).symbol()));
        if (block.chainid == BSC_MAINNET) require(sym == keccak256("USDT"), "token symbol is not USDT");
        else require(sym == keccak256("tUSDT") || sym == keccak256("USDT"), "unexpected test token symbol");

        address[5] memory roles = [c.admin, c.operator, c.oracle, c.guardian, c.feeRecipient];
        for (uint256 i; i < roles.length; ++i) {
            require(roles[i] != address(0), "a role address is zero");
            require(roles[i] != c.token, "a role address is the token");
        }
        require(c.operator != c.oracle, "operator and oracle must differ");
        require(c.admin != c.operator && c.admin != c.oracle, "admin must not be the operator or oracle key");

        console.log("chain          ", block.chainid);
        console.log("token          ", c.token, IERC20Meta(c.token).symbol());
        console.log("admin          ", c.admin, c.admin.code.length == 0 ? "(EOA)" : "(contract)");
        console.log("operator       ", c.operator);
        console.log("oracle         ", c.oracle);
        console.log("guardian       ", c.guardian);
        console.log("fee recipient  ", c.feeRecipient);
        if (c.admin.code.length == 0 && block.chainid == BSC_MAINNET) {
            console.log("NOTE: admin is a plain wallet, not a multisig. The plan wants a 2-of-3 Safe for mainnet.");
        }
    }

    function _checkAfter(UpDownVault v, UpDownVault.Config memory c) internal view {
        require(address(v.token()) == c.token, "token");
        require(v.admin() == c.admin, "admin");
        require(v.operator() == c.operator, "operator");
        require(v.oracle() == c.oracle, "oracle");
        require(v.guardian() == c.guardian, "guardian");
        require(v.feeRecipient() == c.feeRecipient, "fee recipient");
        require(v.unit() == c.unit, "unit");
        require(v.feeLimitBps() == c.feeLimitBps, "fee limit");
        require(v.feeRoundsUp() == c.feeRoundsUp, "fee rounding");
        require(v.silenceSeconds() == c.silenceSeconds, "silence");
        require(v.dayOffsetSeconds() == c.dayOffsetSeconds, "day offset");
        require(v.maxPriceX100() == c.maxPriceX100, "max price");
        require(v.maxOvershootSeconds() == c.maxOvershootSeconds, "max overshoot");
        require(v.maxEntryLag() == c.maxEntryLag, "max entry lag");
        require(v.keyChangeDelay() == c.keyChangeDelay, "key change delay");
        (uint128 fees,, uint16 feeBps, bool paused) = v.state();
        require(fees == 0 && feeBps == 0 && !paused, "fresh state");
        (uint128 free, uint128 locked) = v.house();
        require(free == 0 && locked == 0, "empty house");
    }
}
