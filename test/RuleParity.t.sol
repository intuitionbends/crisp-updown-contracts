// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Base} from "./utils/Base.sol";
import {UpDownVault} from "../src/UpDownVault.sol";

/// @notice Every outcome, payout and due-time case in crisp-updown/src/rules.rs, run against the contract: first
///         through its pure rule functions, then end to end (open on the entry lead, settle on the settle lead,
///         fee 0) so the money that moves agrees with `rules::returned`.
contract RuleParityTest is Base {
    uint8 constant UP = 0;
    uint8 constant DOWN = 1;

    struct Case {
        uint8 side;
        int64 entry;
        int64 settle;
        UpDownVault.Outcome want;
    }

    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 1_000 * USDT);
    }

    /// rules.rs `up_and_down_and_tie`, in order.
    function _cases() internal pure returns (Case[12] memory c) {
        UpDownVault.Outcome W = UpDownVault.Outcome.Won;
        UpDownVault.Outcome L = UpDownVault.Outcome.Lost;
        UpDownVault.Outcome T = UpDownVault.Outcome.Tied;
        c[0] = Case(UP, 100, 101, W);
        c[1] = Case(UP, 100, 99, L);
        c[2] = Case(DOWN, 100, 99, W);
        // Team B's lead shrinking from 500 to 400 is the line going up: team A gained ground.
        c[3] = Case(UP, -500, -400, W);
        c[4] = Case(DOWN, -500, -400, L);
        c[5] = Case(DOWN, -500, -900, W);
        // A lead that changes hands is the line crossing zero, and is read like any other move.
        c[6] = Case(DOWN, 200, -500, W);
        c[7] = Case(UP, 200, -500, L);
        c[8] = Case(UP, -800, 300, W);
        // The same size of lead on the other side is not a tie: the line moved the whole way across.
        c[9] = Case(DOWN, 400, -400, W);
        c[10] = Case(UP, -500, -500, T);
        c[11] = Case(DOWN, 0, 0, T);
    }

    function test_upAndDownAndTie_pure() public view {
        Case[12] memory c = _cases();
        for (uint256 i; i < c.length; ++i) {
            _checkPure(c[i]);
        }
    }

    function test_upAndDownAndTie_endToEnd() public {
        Case[12] memory c = _cases();
        for (uint256 i; i < c.length; ++i) {
            _checkEndToEnd(c[i]);
        }
        assertEq(_houseLocked(), 0);
    }

    function _checkPure(Case memory c) internal view {
        assertEq(uint8(vault.outcome(c.side, c.entry, c.settle)), uint8(c.want));
    }

    function _checkEndToEnd(Case memory c) internal {
        uint256 stake = 100; // units (cents)
        uint256 floatBefore = _float(alice);
        Opened memory o = _openOne(alice, aliceDeviceKey, c.side, stake * CENT, 190, 0, c.entry);
        _settleOne(o, c.settle);
        uint256 back = vault.returned(c.want, stake, 190);
        assertEq(_float(alice), floatBefore - stake * CENT + back * CENT);
    }

    /// rules.rs `payout_rounds_down_and_never_mints`.
    function test_payoutRoundsDownAndNeverMints() public view {
        assertEq(vault.payout(100, 190), 190);
        assertEq(vault.payout(15, 190), 28); // 28.5 rounds down
        assertEq(vault.returned(UpDownVault.Outcome.Tied, 15, 190), 15);
        assertEq(vault.returned(UpDownVault.Outcome.Lost, 15, 190), 0);
        for (uint256 stake = 1; stake < 2000; ++stake) {
            assertLe(vault.payout(stake, 190), stake * 19 / 10);
            assertLt(vault.liability(stake, 190), stake);
        }
    }

    function test_payoutRoundsDown_endToEnd() public {
        // A 15-cent call at 1.90 that wins pays back 28 cents, not 28.5.
        uint256 before = _float(alice);
        Opened memory o = _openOne(alice, aliceDeviceKey, UP, 15 * CENT, 190, 0, 0);
        _settleOne(o, 1);
        assertEq(_float(alice), before - 15 * CENT + 28 * CENT);
        // Tie returns the stake; a loss returns nothing.
        before = _float(alice);
        o = _openOne(alice, aliceDeviceKey, UP, 15 * CENT, 190, 0, 0);
        _settleOne(o, 0);
        assertEq(_float(alice), before);
        o = _openOne(alice, aliceDeviceKey, UP, 15 * CENT, 190, 0, 0);
        _settleOne(o, -1);
        assertEq(_float(alice), before - 15 * CENT);
    }

    /// rules.rs `settling_waits_then_settles_then_gives_up`: due(630, t, 20).
    function test_settlingWaitsThenSettlesThenGivesUp() public {
        // Entry clock 600 + 30 = settle time 630; max overshoot 20.
        Opened memory a = _openOne(alice, aliceDeviceKey, UP, 1 * USDT, 190, 0, 0);
        // 629: not yet.
        _expectDue(a, 628, 629, UpDownVault.Refusal.NotFirstAtOrAfter);
        // 651: too far past; the engine voids it (late_tick) and so must the operator.
        _expectDue(a, 629, 651, UpDownVault.Refusal.Overshoot);
        // 630 and 650: settle.
        _settleAt(a, 1, 629, 630);
        Opened memory b = _openOne(alice, aliceDeviceKey, UP, 1 * USDT, 190, 0, 0);
        _settleAt(b, 1, 629, 650);
    }

    function _expectDue(Opened memory c, int32 prevClock, int32 settleClock, UpDownVault.Refusal why) internal {
        UpDownVault.SignedReading memory p = _reading(MATCH, seq, prevClock, 0);
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, settleClock, 1);
        UpDownVault.SignedReading[] memory rs = _two(p, q);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.SettleRefused.selector, 0, why));
        vault.settleCalls(items, rs);
    }

    // ------------------------------------------------------------------------------- fuzzed against the rule

    /// rules::outcome restated independently: diff = settle - entry; 0 ties; (diff > 0) == (side == Up) wins.
    function testFuzz_outcomeMatchesRule(bool up, int64 entry, int64 settle) public view {
        int256 diff = int256(settle) - int256(entry);
        UpDownVault.Outcome want = diff == 0
            ? UpDownVault.Outcome.Tied
            : ((diff > 0) == up ? UpDownVault.Outcome.Won : UpDownVault.Outcome.Lost);
        assertEq(uint8(vault.outcome(up ? UP : DOWN, entry, settle)), uint8(want));
    }

    /// rules::payout and rules::liability over the engine's integer range.
    function testFuzz_payoutMatchesRule(uint64 stake, uint16 price) public view {
        price = uint16(bound(price, 101, 500));
        uint256 want = uint256(stake) * price / 100;
        assertEq(vault.payout(stake, price), want);
        assertEq(vault.liability(stake, price), want - stake);
        assertLe(vault.payout(stake, price) * 100, uint256(stake) * price, "never mints");
    }
}
