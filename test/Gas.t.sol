// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {Base} from "./utils/Base.sol";
import {UpDownVault} from "../src/UpDownVault.sol";

/// @notice Gas for open and settle per call in a batch. Run with `--isolate` so each vault call is its own
///         transaction with cold storage, as on chain: `forge test --match-contract Gas --isolate -vv`.
///         Each player has one open call (the engine's rule), so every call in a batch touches a cold account.
contract GasTest is Base {
    uint256 internal constant MAX = 50;
    uint256[MAX] internal keys;
    address[MAX] internal players;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < MAX; ++i) {
            (address p, uint256 k) = makeAddrAndKey(string.concat("gasPlayer", vm.toString(i)));
            players[i] = p;
            keys[i] = k; // the player's own key doubles as its device key here
            usdt.mint(p, 100 * USDT);
            vm.prank(p);
            usdt.approve(address(vault), type(uint256).max);
            _authorise(_permission(p, p, 1), k);
            _fill(p, p, 50 * USDT);
        }
    }

    function _batch(uint256 n)
        internal
        returns (UpDownVault.OpenItem[] memory items, UpDownVault.SignedReading[] memory rs, Opened[] memory out)
    {
        rs = _one(_reading(MATCH, seq, 600, 1_000));
        items = new UpDownVault.OpenItem[](n);
        out = new Opened[](n);
        for (uint256 i; i < n; ++i) {
            UpDownVault.CallIntent memory it = _intent(players[i], uint8(i % 2), 5 * USDT, 30);
            items[i] = _item(it, keys[i], 190, 100, 0);
            out[i] = Opened({id: vault.hashIntent(it), rec: _record(items[i], rs[0].reading, 0)});
        }
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// A returning player: one call already opened and settled, so their account's storage is no longer empty.
    function _warmUp(uint256 n) internal {
        (UpDownVault.OpenItem[] memory items, UpDownVault.SignedReading[] memory rs, Opened[] memory calls) = _batch(n);
        vm.prank(operator);
        vault.openCalls(items, rs);
        seq += 1;
        UpDownVault.SettleItem[] memory sitems = new UpDownVault.SettleItem[](n);
        for (uint256 i; i < n; ++i) {
            sitems[i] = UpDownVault.SettleItem({id: calls[i].id, call: calls[i].rec, prev: 0, settle: 1});
        }
        UpDownVault.SignedReading[] memory srs =
            _two(_reading(MATCH, seq, 629, 1_000), _reading(MATCH, seq + 1, 630, 1_100));
        seq += 2;
        vm.prank(operator);
        vault.settleCalls(sitems, srs);
    }

    function _measure(uint256 n, bool sharedSettleReading) internal {
        _measure(n, sharedSettleReading, true);
    }

    function _measure(uint256 n, bool sharedSettleReading, bool returning) internal {
        if (returning) _warmUp(n);
        (UpDownVault.OpenItem[] memory items, UpDownVault.SignedReading[] memory rs, Opened[] memory calls) = _batch(n);
        bytes memory openData = abi.encodeCall(UpDownVault.openCalls, (items, rs));
        vm.prank(operator);
        vault.openCalls(items, rs);
        uint256 openExec = vm.lastCallGas().gasTotalUsed;
        seq += 1;

        UpDownVault.SettleItem[] memory sitems = new UpDownVault.SettleItem[](n);
        UpDownVault.SignedReading[] memory srs;
        // Players' entry readings for the warm-up and the measured batch must not collide.
        if (sharedSettleReading) {
            srs = _two(_reading(MATCH, seq, 629, 1_000), _reading(MATCH, seq + 1, 630, 1_200));
            for (uint256 i; i < n; ++i) {
                sitems[i] = UpDownVault.SettleItem({id: calls[i].id, call: calls[i].rec, prev: 0, settle: 1});
            }
        } else {
            // Worst case: every call brings its own pair of readings.
            srs = new UpDownVault.SignedReading[](2 * n);
            for (uint256 i; i < n; ++i) {
                srs[2 * i] = _reading(MATCH, seq + uint64(2 * i), 629, 1_000);
                srs[2 * i + 1] = _reading(MATCH, seq + uint64(2 * i) + 1, 630, 1_200);
                sitems[i] =
                    UpDownVault.SettleItem({id: calls[i].id, call: calls[i].rec, prev: 2 * i, settle: 2 * i + 1});
            }
        }
        bytes memory settleData = abi.encodeCall(UpDownVault.settleCalls, (sitems, srs));
        vm.prank(operator);
        vault.settleCalls(sitems, srs);
        uint256 settleExec = vm.lastCallGas().gasTotalUsed;

        console.log(
            string.concat(
                "batch ",
                vm.toString(n),
                returning ? ", returning players, " : ", first-ever call per player, ",
                sharedSettleReading ? "one shared settle reading pair" : "own settle reading pair per call"
            )
        );
        console.log("  open   execution total / per call", openExec, openExec / n);
        console.log("  open   calldata  total / per call", _calldataGas(openData), _calldataGas(openData) / n);
        console.log("  settle execution total / per call", settleExec, settleExec / n);
        console.log("  settle calldata  total / per call", _calldataGas(settleData), _calldataGas(settleData) / n);
    }

    function test_gas_batch1() public {
        _measure(1, true);
    }

    function test_gas_batch10() public {
        _measure(10, true);
    }

    function test_gas_batch50() public {
        _measure(50, true);
    }

    function test_gas_batch10_firstCall() public {
        _measure(10, true, false);
    }

    function test_gas_batch50_firstCall() public {
        _measure(50, true, false);
    }

    function test_gas_batch10_ownReadings() public {
        _measure(10, false);
    }

    function test_gas_batch50_ownReadings() public {
        _measure(50, false);
    }
}
