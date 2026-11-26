// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UpDownVault} from "../src/UpDownVault.sol";
import {MockUSDT} from "./utils/Mocks.sol";

/// @notice Checks the vault's EIP-712 digests against an independent implementation: the signatures below were
///         made by `cast wallet sign --data` (alloy's EIP-712) from the JSON in test/fixtures/, with Foundry's
///         public anvil test key 0. If the vault hashed a field or the domain differently, recovery would fail.
contract Eip712Test is Test {
    address constant ANVIL0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    UpDownVault vault;

    function setUp() public {
        vm.chainId(97);
        MockUSDT usdt = new MockUSDT();
        vault = new UpDownVault(
            UpDownVault.Config({
                token: address(usdt),
                admin: address(0xA11CE),
                operator: address(0x0BE8A7),
                oracle: ANVIL0,
                guardian: address(0x6A8D),
                feeRecipient: address(0xFEE),
                unit: 1e16,
                feeLimitBps: 500,
                feeRoundsUp: false,
                silenceSeconds: 6 hours,
                dayOffsetSeconds: 8 hours,
                maxPriceX100: 500,
                maxOvershootSeconds: 20,
                maxEntryLag: 3,
                keyChangeDelay: 24 hours
            })
        );
    }

    bytes32 constant MATCH_ID = 0x5aa1b6b3d1c4a1d1c37e2b0f1a7e4b9c2d5e8f0a1b2c3d4e5f60718293a4b5c6;

    function _recover(bytes32 digest, bytes memory sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        return ecrecover(digest, v, r, s);
    }

    function test_deployedWhereFixturesExpect() public view {
        assertEq(address(vault), 0x2e234DAe75C793f67A35089C9d99245E1C58470b, "fixtures' verifyingContract moved");
    }

    function test_permissionMatchesCast() public {
        UpDownVault.Permission memory p = UpDownVault.Permission({
            account: ANVIL0,
            deviceKey: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            floatCap: 200e18,
            perCallMax: 25e18,
            dailyLossLimit: 50e18,
            validUntil: 1_798_000_000,
            nonce: 7
        });
        bytes memory sig =
            hex"3c99416595ca0b90d355da0f2ecd7520ce940f4a51545d397d21f0e917544b9208f2119493db39839ba7a940cd556774b1ea834aa4d94a8f7160c9b3a86805951c";
        assertEq(_recover(vault.hashPermission(p), sig), ANVIL0);
        // And the vault itself accepts it as the account's own (ECDSA) signature.
        vm.warp(1_795_000_000);
        vm.prank(address(0x0BE8A7));
        vault.authorise(p, sig);
    }

    function test_intentMatchesCast() public view {
        UpDownVault.CallIntent memory i = UpDownVault.CallIntent({
            account: 0x1111111111111111111111111111111111111111,
            matchId: MATCH_ID,
            side: 1,
            stake: 2.5e18,
            length: 30,
            minPriceX100: 182,
            maxFeeBps: 100,
            readingSeen: 48_211,
            nonce: 90_210,
            deadline: 1_795_000_060
        });
        bytes memory sig =
            hex"57fe1cef9a6c7f1966db566bd6a7fa4f78162105a9aa27c99344805653ae79aa033481757b5db61a1bf47d836506dc0c8787018d8720739f13690876394dd8bf1b";
        assertEq(_recover(vault.hashIntent(i), sig), ANVIL0);
    }

    function test_readingMatchesCast() public view {
        UpDownVault.Reading memory r = UpDownVault.Reading({matchId: MATCH_ID, seq: 48_212, clock: -17, lead: -12_345});
        bytes memory sig =
            hex"2b75c029402c6a4bc6b0705975de894267241e2ace405c95be3592e4798e35432f33332bf02c190770fd315bea0a970b70098659b8a0eaab89ae135eeb67fa981b";
        assertEq(_recover(vault.hashReading(r), sig), ANVIL0);
    }
}
