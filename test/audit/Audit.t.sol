// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Vm} from "forge-std/Test.sol";
import {Base} from "../utils/Base.sol";
import {UpDownVault} from "../../src/UpDownVault.sol";
import {MockUSDT} from "../utils/Mocks.sol";
import {
    ReturnBombAccount,
    GasBurnAccount,
    YesAccount,
    NoReturnToken,
    FeeOnTransferToken,
    HookToken,
    ReentrantPlayer
} from "../utils/AuditMocks.sol";

/// @notice What a stolen operator key can and cannot do. Each test is one attempt; the vault must refuse it or
///         limit it to what the plan accepts (opening only what a device key signed, paying floats only to owners).
contract OperatorCompromiseTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
        _fill(bob, bobDevice, 100 * USDT);
    }

    function test_recallAlwaysPaysTheOwnerNotTheOperator() public {
        uint256 opBefore = usdt.balanceOf(operator);
        uint256 aliceBefore = usdt.balanceOf(alice);
        vm.prank(operator);
        vault.recall(alice, type(uint256).max);
        assertEq(usdt.balanceOf(operator), opBefore);
        assertEq(usdt.balanceOf(alice), aliceBefore + 100 * USDT);
    }

    function test_cannotFillUsingAnotherAccountsPermission() public {
        vm.prank(operator);
        vm.expectRevert(UpDownVault.PermissionExpired.selector);
        vault.fill(alice, bobDevice, 1);
    }

    function test_fillOnlyMovesTheAccountsOwnMoneyIntoItsOwnFloat() public {
        uint256 bobWallet = usdt.balanceOf(bob);
        _fill(alice, aliceDevice, 5 * USDT);
        assertEq(usdt.balanceOf(bob), bobWallet, "another wallet touched");
        assertEq(_float(alice), 105 * USDT);
    }

    function test_cannotOpenACallNobodySigned() public {
        // The operator signs the intent itself.
        (, uint256 opKey) = makeAddrAndKey("operator");
        _openExpectRejected(
            _one(_item(_intent(alice, 0, 1 * USDT, 30), opKey, 190, 0, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.NoPermission
        );
    }

    function test_cannotMoveAnIntentToAnotherAccount() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        o.intent.account = bob; // Alice's device signed for Alice
        _openExpectRejected(_one(o), _one(_reading(MATCH, seq, 600, 0)), 0, UpDownVault.Refusal.NoPermission);
    }

    function test_cannotChargeMoreThanTheUserSigned() public {
        vm.prank(admin);
        vault.setFeeBps(500);
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.maxFeeBps = 100;
        _openExpectRejected(
            _one(_item(it, aliceDeviceKey, 190, 101, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.FeeTooHigh
        );
    }

    function test_cannotPayLessThanTheUserSigned() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.minPriceX100 = 190;
        _openExpectRejected(
            _one(_item(it, aliceDeviceKey, 189, 0, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.PriceBelowMin
        );
    }

    function test_cannotPickAnEntryReadingOutsideTheWindow() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        UpDownVault.OpenItem memory o = _item(it, aliceDeviceKey, 190, 0, 0);
        // Backdated to before what the player saw.
        _openExpectRejected(
            _one(o), _one(_reading(MATCH, it.readingSeen - 1, 600, 0)), 0, UpDownVault.Refusal.EntryOutOfRange
        );
        // Later than the allowed lag (chosen after seeing the line move).
        _openExpectRejected(
            _one(o), _one(_reading(MATCH, it.readingSeen + 4, 600, 0)), 0, UpDownVault.Refusal.EntryOutOfRange
        );
        // Another match's reading.
        _openExpectRejected(
            _one(o), _one(_reading(OTHER_MATCH, it.readingSeen, 600, 0)), 0, UpDownVault.Refusal.WrongMatch
        );
    }

    function test_cannotOpenTheSameIntentTwice() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
        _openExpectRejected(_one(o), _one(r), 0, UpDownVault.Refusal.Duplicate);
        assertEq(_openStake(alice), 1 * USDT);
    }

    function test_cannotSettleOnAnythingButTheFirstReadingAtOrAfter() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        // Skipping a reading to land on one that suits the house.
        _expectSettleRevert(
            items,
            _two(_reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 2, 640, -9)),
            UpDownVault.Refusal.NotConsecutive
        );
        // Settling early.
        _expectSettleRevert(
            items,
            _two(_reading(MATCH, seq, 620, 0), _reading(MATCH, seq + 1, 625, -9)),
            UpDownVault.Refusal.NotFirstAtOrAfter
        );
        // A later pair, once the first at-or-after has passed.
        _expectSettleRevert(
            items,
            _two(_reading(MATCH, seq, 631, 0), _reading(MATCH, seq + 1, 632, -9)),
            UpDownVault.Refusal.NotFirstAtOrAfter
        );
        // Readings from before the call opened.
        _expectSettleRevert(
            items,
            _two(_reading(MATCH, c.rec.entrySeq - 2, 629, 0), _reading(MATCH, c.rec.entrySeq - 1, 630, -9)),
            UpDownVault.Refusal.NotConsecutive
        );
    }

    function test_cannotSettleWithReadingsTheOracleDidNotSign() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        (, uint256 opKey) = makeAddrAndKey("operator");
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, 630, -9);
        q.signature = _sign(opKey, vault.hashReading(q.reading));
        UpDownVault.SignedReading[] memory rs = _two(_reading(MATCH, seq, 629, 0), q);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 1));
        vault.settleCalls(items, rs);
    }

    function test_cannotSettleAForgedRecord() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 0);
        for (uint256 f; f < 9; ++f) {
            UpDownVault.CallRecord memory r = c.rec;
            if (f == 0) r.account = bob;
            if (f == 1) r.matchId = OTHER_MATCH;
            if (f == 2) r.side = 1;
            if (f == 3) r.stakeUnits = 1;
            if (f == 4) r.priceX100 = 101;
            if (f == 5) r.feeBps = 0;
            if (f == 6) r.entryLead = 1;
            if (f == 7) r.settleAt = 700;
            if (f == 8) r.epoch = 1;
            UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
            items[0] = UpDownVault.SettleItem({id: c.id, call: r, prev: 0, settle: 1});
            _expectSettleRevert(
                items,
                _two(
                    _reading(r.matchId, seq, int32(r.settleAt) - 1, 0),
                    _reading(r.matchId, seq + 1, int32(r.settleAt), -1)
                ),
                UpDownVault.Refusal.UnknownCall
            );
            c.rec.epoch = 0;
        }
    }

    function test_cannotVoidForMoreThanTheStake() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 0, 0);
        UpDownVault.CallRecord memory r = c.rec;
        r.stakeUnits = 100_000;
        UpDownVault.VoidItem[] memory items = new UpDownVault.VoidItem[](1);
        items[0] = UpDownVault.VoidItem({id: c.id, call: r, reason: 1});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.VoidRefused.selector, 0, UpDownVault.Refusal.UnknownCall));
        vault.voidCalls(items);
    }

    function test_cannotTouchTheHouseOrFees() public {
        vm.startPrank(operator);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.withdrawHouse(operator, 1);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeRecipient(operator);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeBps(500);
        vm.stopPrank();
    }

    function test_cannotFillPastTheSignedCapEvenAcrossCalls() public {
        _fill(alice, aliceDevice, 900 * USDT); // to the 1,000 cap
        vm.prank(operator);
        vm.expectRevert(UpDownVault.OverFloatCap.selector);
        vault.fill(alice, aliceDevice, 1);
    }

    function _expectSettleRevert(
        UpDownVault.SettleItem[] memory items,
        UpDownVault.SignedReading[] memory rs,
        UpDownVault.Refusal why
    ) internal {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.SettleRefused.selector, 0, why));
        vault.settleCalls(items, rs);
    }
}

/// @notice What one player can do to another player, or to everyone.
contract UserAttackTest is Base {
    uint256 eveKey;
    address eve;
    uint256 eveDeviceKey;
    address eveDevice;

    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        (eve, eveKey) = makeAddrAndKey("eve");
        (eveDevice, eveDeviceKey) = makeAddrAndKey("eveDevice");
        usdt.mint(eve, 1_000 * USDT);
        vm.prank(eve);
        usdt.approve(address(vault), type(uint256).max);
        _authorise(_permission(eve, eveDevice, 1), eveKey);
        _fill(alice, aliceDevice, 100 * USDT);
        _fill(eve, eveDevice, 100 * USDT);
    }

    function test_cannotOpenOnSomeoneElsesAccount() public {
        _openExpectRejected(
            _one(_item(_intent(alice, 0, 1 * USDT, 30), eveDeviceKey, 190, 0, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.NoPermission
        );
    }

    function test_cannotRecallSomeoneElsesFloat() public {
        vm.prank(eve);
        vm.expectRevert(UpDownVault.NotAllowed.selector);
        vault.recall(alice, 1);
    }

    function test_cannotRevokeSomeoneElsesKey() public {
        vm.prank(eve);
        vault.revoke(aliceDevice); // only clears eve's own (empty) entry
        (, uint32 until,,) = vault.permissions(alice, aliceDevice);
        assertGt(until, 0);
    }

    function test_exitOnlyAffectsTheCaller() public {
        _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 0, 0);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(eve);
        vault.exit();
        assertEq(_float(alice), 90 * USDT);
        assertEq(_openStake(alice), 10 * USDT);
    }

    function test_cannotEscapeALosingCallWhileTheOperatorIsActive() public {
        _openOne(eve, eveDeviceKey, 0, 10 * USDT, 190, 0, 0);
        vm.prank(eve);
        vm.expectRevert(UpDownVault.OperatorActive.selector);
        vault.exit();
        // Recall reaches only the free float, never the stake in the call.
        vm.prank(eve);
        vault.recall(eve, type(uint256).max);
        assertEq(_openStake(eve), 10 * USDT);
    }

    /// The fix for batch griefing: a player who empties their float or revokes their key just before the batch
    /// lands only loses their own call; everyone else's opens.
    function test_cannotStopOtherPlayersCalls() public {
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](3);
        items[0] = _item(_intent(eve, 0, 10 * USDT, 30), eveDeviceKey, 190, 0, 0);
        items[1] = _item(_intent(alice, 0, 10 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        items[2] = _item(_intent(eve, 1, 10 * USDT, 30), eveDeviceKey, 190, 0, 0);
        // Eve front-runs: empties her float, then revokes her key.
        vm.prank(eve);
        vault.recall(eve, type(uint256).max);
        vm.recordLogs();
        vm.prank(operator);
        vault.openCalls(items, _one(r));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool f0,, UpDownVault.Refusal w0) =
            _eventFor(logs, UpDownVault.CallRejected.selector, vault.hashIntent(items[0].intent));
        assertTrue(f0);
        assertEq(uint8(w0), uint8(UpDownVault.Refusal.FloatShort));
        assertEq(_openStake(alice), 10 * USDT, "Alice's call opened");

        vm.prank(eve);
        vault.revoke(eveDevice);
        UpDownVault.OpenItem[] memory more = new UpDownVault.OpenItem[](2);
        more[0] = _item(_intent(eve, 0, 1 * USDT, 30), eveDeviceKey, 190, 0, 0);
        more[1] = _item(_intent(alice, 1, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        _openExpectRejected(more, _one(r), 0, UpDownVault.Refusal.NoPermission);
        assertEq(_openStake(alice), 11 * USDT);
    }

    /// Exiting at the last moment cannot stop a settle batch for others either.
    function test_exitCannotStopOtherPlayersSettles() public {
        Opened memory a = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 0, 0);
        seq -= 1;
        Opened memory e = _openOne(eve, eveDeviceKey, 0, 10 * USDT, 190, 0, 0);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(eve);
        vault.exit();
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](2);
        items[0] = UpDownVault.SettleItem({id: e.id, call: e.rec, prev: 0, settle: 1});
        items[1] = UpDownVault.SettleItem({id: a.id, call: a.rec, prev: 0, settle: 1});
        UpDownVault.SignedReading[] memory rs = _two(_reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 630, 5));
        vm.prank(operator);
        vault.settleCalls(items, rs);
        assertEq(_float(alice), 90 * USDT + 19 * USDT);
    }

    function test_cannotReplayAnotherPlayersIntentOntoTheirOwnAccount() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
        o.intent.account = eve;
        _openExpectRejected(_one(o), _one(r), 0, UpDownVault.Refusal.NoPermission);
    }

    function test_aStolenLowLimitKeyIsBoundByItsOwnLimit() public {
        // Alice has a second device with a small daily loss limit; its key is stolen.
        (address laptop, uint256 laptopKey) = makeAddrAndKey("aliceLaptop");
        UpDownVault.Permission memory p = _permission(alice, laptop, 1);
        p.dailyLossLimit = 5 * USDT;
        _authorise(p, aliceKey);
        Opened memory c = _openOne(alice, laptopKey, 0, 5 * USDT, 190, 0, 0);
        _settleOne(c, -1); // lost 5
        _openExpectRejected(
            _one(_item(_intent(alice, 0, 1 * CENT, 30), laptopKey, 190, 0, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.DailyLossLimit
        );
    }
}

/// @notice What the admin and the guardian can and cannot reach.
contract AdminGuardianLimitsTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function test_adminCannotReachFloatsLockedMoneyOrRecall() public {
        _openOne(alice, aliceDeviceKey, 0, 50 * USDT, 190, 0, 0);
        uint256 free = _houseFree();
        vm.startPrank(admin);
        vm.expectRevert(UpDownVault.InsufficientHouse.selector);
        vault.withdrawHouse(admin, free + 1);
        vm.expectRevert(UpDownVault.NotAllowed.selector);
        vault.recall(alice, 1);
        vm.stopPrank();
        assertEq(_float(alice), 50 * USDT);
        assertEq(_houseLocked(), 45 * USDT);
    }

    /// Informational finding: the admin can redirect fees already accrued, not only future ones.
    function test_adminCanRedirectAccruedFees() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 50 * USDT, 190, 100, 0);
        _settleOne(c, -1);
        address elsewhere = makeAddr("elsewhere");
        vm.prank(admin);
        vault.setFeeRecipient(elsewhere);
        vault.withdrawFees();
        assertEq(usdt.balanceOf(elsewhere), 50 * CENT);
        assertEq(usdt.balanceOf(feeRecipient), 0);
    }

    function test_guardianPauseNeverTrapsMoney() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 0);
        Opened memory d = _openOne(alice, aliceDeviceKey, 1, 10 * USDT, 190, 100, 0);
        vm.prank(guardian);
        vault.pause();
        _settleOne(c, -1); // settles while paused
        UpDownVault.VoidItem[] memory v = new UpDownVault.VoidItem[](1);
        v[0] = UpDownVault.VoidItem({id: d.id, call: d.rec, reason: 1});
        vm.prank(operator);
        vault.voidCalls(v); // voids while paused
        vault.withdrawFees(); // fee sweep while paused
        vm.prank(alice);
        vault.recall(alice, type(uint256).max); // recall while paused
        assertEq(_float(alice), 0);
        vm.prank(guardian);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.unpause();
    }

    function test_oldAdminLosesEveryPowerAfterHandover() public {
        address safe = makeAddr("safe");
        vm.prank(admin);
        vault.transferAdmin(safe);
        vm.prank(safe);
        vault.acceptAdmin();
        vm.startPrank(admin);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.withdrawHouse(admin, 1);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.fundHouse(1);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.unpause();
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.transferAdmin(admin);
        vm.stopPrank();
    }
}

/// @notice Signatures moved between messages, vaults and chains.
contract SignatureAttackTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function test_permissionForOneVaultIsRefusedByAnother() public {
        UpDownVault other = new UpDownVault(_config());
        UpDownVault.Permission memory p = _permission(alice, makeAddr("phone2"), 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        other.authorise(p, sig);
    }

    function test_intentForOneVaultIsRefusedByAnother() public {
        UpDownVault other = new UpDownVault(_config());
        // Alice authorises the same device key on the other vault, and funds it.
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        bytes memory psig = _sign(aliceKey, other.hashPermission(p));
        vm.prank(operator);
        other.authorise(p, psig);
        vm.prank(alice);
        usdt.approve(address(other), type(uint256).max);
        vm.prank(operator);
        other.fill(alice, aliceDevice, 10 * USDT);
        vm.startPrank(admin);
        usdt.approve(address(other), type(uint256).max);
        other.fundHouse(100 * USDT);
        vm.stopPrank();
        // An intent signed for the first vault, and a reading signed for it.
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 0));
        other.openCalls(_one(o), _one(r));
        // With a reading signed for the other vault, the intent itself still does not verify there.
        UpDownVault.Reading memory rr = r.reading;
        r.signature = _sign(oracleKey, other.hashReading(rr));
        vm.recordLogs();
        vm.prank(operator);
        other.openCalls(_one(o), _one(r));
        bytes32 otherId = other.hashIntent(o.intent);
        (bool found,, UpDownVault.Refusal why) =
            _eventFor(vm.getRecordedLogs(), UpDownVault.CallRejected.selector, otherId);
        assertTrue(found);
        assertEq(uint8(why), uint8(UpDownVault.Refusal.NoPermission));
    }

    function test_signaturesDoNotSurviveAChainChange() public {
        UpDownVault.Permission memory p = _permission(alice, makeAddr("phone2"), 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.chainId(97);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, sig);
    }

    function test_noMessageCanStandInForAnother() public {
        // The device key signs a reading-shaped digest; used as an intent it recovers someone else.
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        UpDownVault.Reading memory fake = UpDownVault.Reading({matchId: MATCH, seq: 1, clock: 1, lead: 1});
        UpDownVault.OpenItem memory o = _item(it, aliceDeviceKey, 190, 0, 0);
        o.signature = _sign(aliceDeviceKey, vault.hashReading(fake));
        _openExpectRejected(_one(o), _one(_reading(MATCH, seq, 600, 0)), 0, UpDownVault.Refusal.NoPermission);
        // A device key's signature is not an oracle reading.
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        r.signature = _sign(aliceDeviceKey, vault.hashReading(r.reading));
        UpDownVault.OpenItem memory good = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 0));
        vault.openCalls(_one(good), _one(r));
        // The oracle is not a device key.
        _openExpectRejected(
            _one(_item(_intent(alice, 0, 1 * USDT, 30), oracleKey, 190, 0, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.NoPermission
        );
    }

    function test_malformedSignaturesRecoverNobody() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        bytes memory good = o.signature;
        bytes[4] memory bad;
        bad[0] = new bytes(65); // all zero
        bad[1] = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(1))); // 64-byte compact form
        bytes memory v0 = good;
        bad[2] = abi.encodePacked(_slice(v0, 0, 64), uint8(0)); // v = 0
        bad[3] = abi.encodePacked(good, uint8(0)); // 66 bytes
        for (uint256 k; k < 4; ++k) {
            o.signature = bad[k];
            _openExpectRejected(_one(o), _one(_reading(MATCH, seq, 600, 0)), 0, UpDownVault.Refusal.NoPermission);
        }
    }

    function _slice(bytes memory b, uint256 from, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; ++i) {
            out[i] = b[from + i];
        }
    }
}

/// @notice Hostile smart accounts at `authorise`.
contract Erc1271HardeningTest is Base {
    /// A megabyte answer costs the account about 2M gas to produce inside its own frame (memory expansion),
    /// paid from the operator's transaction. The vault reads back only 32 bytes, so it does not pay a second
    /// time to copy it (that copy would add about as much again). The operator simulates `authorise` first.
    function test_returnBombIsNotCopiedAndFails() public {
        address acct = address(new ReturnBombAccount());
        UpDownVault.Permission memory p = _permission(acct, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        uint256 g = gasleft();
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, sig);
        assertLt(g - gasleft(), 2_300_000, "the answer was copied into the vault's memory too");
    }

    function test_gasBurnerFailsInsteadOfStealingTheCall() public {
        address acct = address(new GasBurnAccount());
        UpDownVault.Permission memory p = _permission(acct, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise{gas: 2_000_000}(p, sig);
    }

    function test_anAccountThatApprovesEverythingOnlyAuthorisesItself() public {
        address yes = address(new YesAccount());
        // It can give itself a permission (its own business)...
        UpDownVault.Permission memory p = _permission(yes, aliceDevice, 1);
        vm.prank(operator);
        vault.authorise(p, hex"00");
        // ...but its answer means nothing for anyone else's permission.
        UpDownVault.Permission memory q = _permission(alice, aliceDevice, 1);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(q, hex"00");
    }
}

/// @notice The vault on tokens shaped differently from BSC USDT.
contract TokenBehaviourTest is Base {
    function _vaultOn(address token) internal returns (UpDownVault v) {
        UpDownVault.Config memory c = _config();
        c.token = token;
        v = new UpDownVault(c);
    }

    function test_worksWithATokenThatReturnsNothing() public {
        NoReturnToken t = new NoReturnToken();
        UpDownVault v = _vaultOn(address(t));
        t.mint(alice, 10 * USDT);
        vm.prank(alice);
        t.approve(address(v), type(uint256).max);
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, v.hashPermission(p));
        vm.startPrank(operator);
        v.authorise(p, sig);
        v.fill(alice, aliceDevice, 10 * USDT);
        v.recall(alice, 4 * USDT);
        vm.stopPrank();
        assertEq(t.balanceOf(alice), 4 * USDT);
        assertEq(t.balanceOf(address(v)), 6 * USDT);
    }

    /// Known limitation, documented: a token that keeps part of each transfer leaves the vault short, because
    /// `fill` credits what was asked for, not what arrived. BSC USDT takes no fee; the vault must not be
    /// deployed on a token that does.
    function test_knownLimitation_feeOnTransferLeavesTheVaultShort() public {
        FeeOnTransferToken t = new FeeOnTransferToken();
        UpDownVault v = _vaultOn(address(t));
        t.mint(alice, 100 * USDT);
        vm.prank(alice);
        t.approve(address(v), type(uint256).max);
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, v.hashPermission(p));
        vm.startPrank(operator);
        v.authorise(p, sig);
        v.fill(alice, aliceDevice, 100 * USDT);
        vm.stopPrank();
        assertLt(t.balanceOf(address(v)), v.floatOf(alice));
    }
}

/// @notice A token that calls the recipient back cannot be used to take a float twice.
contract ReentrancyTest is Base {
    HookToken hook;
    UpDownVault v;
    ReentrantPlayer player;
    uint256 ownerKey;

    function setUp() public override {
        super.setUp();
        hook = new HookToken();
        UpDownVault.Config memory c = _config();
        c.token = address(hook);
        v = new UpDownVault(c);
        address owner;
        (owner, ownerKey) = makeAddrAndKey("reentrantOwner");
        player = new ReentrantPlayer(owner);
        player.setVault(v);
        player.approve(address(hook), address(v));
        hook.mint(address(player), 100 * USDT);
        UpDownVault.Permission memory p = _permission(address(player), aliceDevice, 1);
        bytes memory sig = _sign(ownerKey, v.hashPermission(p));
        vm.startPrank(operator);
        v.authorise(p, sig);
        v.fill(address(player), aliceDevice, 100 * USDT);
        vm.stopPrank();
    }

    function test_reenteringRecallTakesOnlyWhatIsLeft() public {
        player.setMode(1);
        player.recall(30 * USDT);
        assertEq(hook.balanceOf(address(player)), 100 * USDT, "never more than the float");
        assertEq(v.floatOf(address(player)), 0);
        assertEq(hook.balanceOf(address(v)), 0);
    }

    function test_reenteringExitGetsNothingMore() public {
        player.setMode(2);
        vm.warp(block.timestamp + 6 hours);
        player.exit();
        assertEq(player.reentrySucceeded(), 0);
        assertEq(hook.balanceOf(address(player)), 100 * USDT);
        assertEq(hook.balanceOf(address(v)), 0);
    }
}

/// @notice Every function against the pause: only `fill` and `openCalls` stop.
contract PauseMatrixTest is Base {
    function test_matrix() public {
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
        Opened memory a = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 0);
        Opened memory b = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 0);
        vm.prank(guardian);
        vault.pause();

        // Stopped.
        vm.prank(operator);
        vm.expectRevert(UpDownVault.IsPaused.selector);
        vault.fill(alice, aliceDevice, 1);
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.IsPaused.selector);
        vault.openCalls(_one(o), _one(r));

        // Still working.
        _authorise(_permission(alice, makeAddr("tablet"), 1), aliceKey);
        _settleOne(a, -1);
        UpDownVault.VoidItem[] memory v = new UpDownVault.VoidItem[](1);
        v[0] = UpDownVault.VoidItem({id: b.id, call: b.rec, reason: 1});
        vm.prank(operator);
        vault.voidCalls(v);
        vm.prank(alice);
        vault.revoke(makeAddr("tablet"));
        vm.prank(alice);
        vault.recall(alice, 1);
        vault.withdrawFees();
        vm.startPrank(admin);
        vault.fundHouse(1);
        vault.withdrawHouse(admin, 1);
        vault.setFeeBps(50);
        vault.setFeeRecipient(feeRecipient);
        vault.transferAdmin(address(0));
        vm.stopPrank();
        vm.warp(block.timestamp + 6 hours);
        vm.prank(alice);
        vault.exit();
        assertEq(_float(alice), 0);
    }
}

/// @notice Fuzzed callers against every role-gated function.
contract AccessControlFuzzTest is Base {
    function testFuzz_onlyTheRoleMayCall(address who) public {
        vm.assume(who != operator && who != admin && who != guardian);
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        vm.startPrank(who);
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.authorise(p, "");
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.fill(alice, aliceDevice, 1);
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.openCalls(new UpDownVault.OpenItem[](0), new UpDownVault.SignedReading[](0));
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.settleCalls(new UpDownVault.SettleItem[](0), new UpDownVault.SignedReading[](0));
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.voidCalls(new UpDownVault.VoidItem[](0));
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.fundHouse(1);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.withdrawHouse(who, 1);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeBps(1);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeRecipient(who);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.transferAdmin(who);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.unpause();
        vm.expectRevert(UpDownVault.NotGuardian.selector);
        vault.pause();
        vm.expectRevert(UpDownVault.NotPendingAdmin.selector);
        vault.acceptAdmin();
        vm.stopPrank();
        if (who != alice) {
            vm.prank(who);
            vm.expectRevert(UpDownVault.NotAllowed.selector);
            vault.recall(alice, 0);
        }
    }
}

/// @notice Every limit at exactly its edge: accepted on the line, refused one past it.
contract BoundaryTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 1_000 * USDT);
    }

    function _opens(UpDownVault.OpenItem memory o, UpDownVault.SignedReading memory r) internal returns (bool) {
        bytes32 id = vault.hashIntent(o.intent);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
        return vault.calls(id) != bytes32(0);
    }

    function test_deadlineIsInclusive() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.deadline = uint64(vm.getBlockTimestamp());
        assertTrue(_opens(_item(it, aliceDeviceKey, 190, 0, 0), _reading(MATCH, seq, 600, 0)));
    }

    function test_permissionValidUntilIsInclusive() public {
        (address d, uint256 k) = makeAddrAndKey("edge");
        uint256 t = vm.getBlockTimestamp();
        UpDownVault.Permission memory p = _permission(alice, d, 1);
        p.validUntil = uint64(t + 100);
        _authorise(p, aliceKey);
        vm.warp(t + 100);
        assertTrue(_opens(_item(_intent(alice, 0, 1 * USDT, 30), k, 190, 0, 0), _reading(MATCH, seq, 600, 0)));
        vm.warp(t + 101);
        seq += 1;
        assertFalse(_opens(_item(_intent(alice, 0, 1 * USDT, 30), k, 190, 0, 0), _reading(MATCH, seq, 600, 0)));
    }

    function test_priceFloorAndCeiling() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        assertTrue(_opens(_item(it, aliceDeviceKey, 101, 0, 0), _reading(MATCH, seq, 600, 0)));
        seq += 1;
        assertTrue(
            _opens(_item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 500, 0, 0), _reading(MATCH, seq, 600, 0))
        );
    }

    function test_feeAtExactlyBothLimits() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.maxFeeBps = 100; // ceiling is also 100
        assertTrue(_opens(_item(it, aliceDeviceKey, 190, 100, 0), _reading(MATCH, seq, 600, 0)));
    }

    function test_stakeAtExactlyPerCallMaxAndOneUnit() public {
        assertTrue(
            _opens(_item(_intent(alice, 0, 100 * USDT, 30), aliceDeviceKey, 190, 0, 0), _reading(MATCH, seq, 600, 0))
        );
        seq += 1;
        assertTrue(_opens(_item(_intent(alice, 0, CENT, 30), aliceDeviceKey, 190, 0, 0), _reading(MATCH, seq, 600, 0)));
    }

    function test_dailyLossExactlyAtLimit() public {
        // Limit 500: five open calls of 100 reach it exactly; one more cent does not fit.
        for (uint256 k; k < 5; ++k) {
            assertTrue(
                _opens(
                    _item(_intent(alice, 0, 100 * USDT, 30), aliceDeviceKey, 190, 0, 0), _reading(MATCH, seq, 600, 0)
                )
            );
            seq += 1;
        }
        assertFalse(_opens(_item(_intent(alice, 0, CENT, 30), aliceDeviceKey, 190, 0, 0), _reading(MATCH, seq, 600, 0)));
    }

    function test_silenceBoundary() public {
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 6 hours - 1);
        vm.prank(alice);
        vm.expectRevert(UpDownVault.OperatorActive.selector);
        vault.exit();
        vm.warp(t + 6 hours);
        vm.prank(alice);
        vault.exit();
    }
}

/// @notice One call at a time, every parameter fuzzed: value is conserved to the wei, the user gets exactly
///         the engine's payout, and the house never pays more than it locked.
contract ConservationFuzzTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        vm.prank(admin);
        vault.setFeeBps(500);
        _fill(alice, aliceDevice, 1_000 * USDT);
    }

    function testFuzz_openSettleConserves(
        uint256 stakeCents,
        uint16 price,
        uint16 feeBps,
        bool up,
        int64 entryLead,
        int64 settleLead
    ) public {
        stakeCents = bound(stakeCents, 1, 10_000);
        price = uint16(bound(price, 101, 500));
        feeBps = uint16(bound(feeBps, 0, 500));
        uint256 total0 = _float(alice) + _openStake(alice) + _houseFree() + _houseLocked() + _fees();

        Opened memory c = _openOne(alice, aliceDeviceKey, up ? 0 : 1, stakeCents * CENT, price, feeBps, entryLead);
        uint256 fee = stakeCents * feeBps / 10_000;
        uint256 net = stakeCents - fee;
        uint256 pay = net * price / 100;
        assertEq(_houseLocked(), (pay - net) * CENT, "locked = liability");

        uint256 floatBefore = _float(alice);
        _settleOne(c, settleLead);
        UpDownVault.Outcome o = vault.outcome(up ? 0 : 1, entryLead, settleLead);
        uint256 want = o == UpDownVault.Outcome.Won ? pay : (o == UpDownVault.Outcome.Tied ? stakeCents : 0);
        assertEq(_float(alice) - floatBefore, want * CENT, "user got the rule's amount");
        assertEq(_fees(), o == UpDownVault.Outcome.Tied ? 0 : fee * CENT, "fee only on decided calls");
        assertEq(_houseLocked(), 0);
        assertEq(_float(alice) + _openStake(alice) + _houseFree() + _houseLocked() + _fees(), total0, "conserved");
        assertEq(usdt.balanceOf(address(vault)), total0, "backed");
    }
}

/// @notice A whole round, then the operator vanishing: every balance ends where it should and nothing is stuck.
contract LifecycleTest is Base {
    function test_fullRoundThenOperatorVanishes() public {
        _authoriseDefaults();
        uint256 aliceStart = usdt.balanceOf(alice);
        uint256 bobStart = usdt.balanceOf(bob);
        uint256 adminStart = usdt.balanceOf(admin);
        uint256 houseStart = _houseFree();

        _fill(alice, aliceDevice, 100 * USDT);
        _fill(bob, bobDevice, 100 * USDT);
        Opened memory a1 = _openOne(alice, aliceDeviceKey, 0, 20 * USDT, 190, 100, 0); // wins
        Opened memory b1 = _openOne(bob, bobDeviceKey, 0, 30 * USDT, 210, 100, 0); // loses
        Opened memory a2 = _openOne(alice, aliceDeviceKey, 1, 10 * USDT, 190, 100, 7); // ties
        Opened memory b2 = _openOne(bob, bobDeviceKey, 1, 15 * USDT, 190, 100, 0); // voided
        Opened memory a3 = _openOne(alice, aliceDeviceKey, 1, 5 * USDT, 300, 100, 0); // left open
        _settleOne(a1, 1);
        _settleOne(b1, -1);
        _settleOne(a2, 7);
        UpDownVault.VoidItem[] memory v = new UpDownVault.VoidItem[](1);
        v[0] = UpDownVault.VoidItem({id: b2.id, call: b2.rec, reason: 5});
        vm.prank(operator);
        vault.voidCalls(v);
        vault.withdrawFees();

        // a1: net 1,980 x 1.90 = 3,762 back. b1: lost 30. Fees: 20 + 30 cents.
        assertEq(usdt.balanceOf(feeRecipient), 50 * CENT);

        // The operator goes silent with a3 open. Everyone leaves.
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.exit();
        assertEq(_houseLocked(), 0, "nothing left locked");
        uint256 free = _houseFree();
        vm.prank(admin);
        vault.withdrawHouse(admin, free);
        assertEq(usdt.balanceOf(address(vault)), 0, "nothing stuck in the vault");

        // Alice: +17.62 net on a1 (37.62 back on 20), level a2, a3 refunded.
        assertEq(usdt.balanceOf(alice), aliceStart + 1_762 * CENT);
        // Bob: lost 30 on b1, b2 refunded.
        assertEq(usdt.balanceOf(bob), bobStart - 30 * USDT);
        // The house: kept Bob's net 29.70, paid Alice's winnings 17.82 (her 17.62 net plus the 20 cent fee).
        assertEq(usdt.balanceOf(admin), adminStart + houseStart + 2_970 * CENT - 1_782 * CENT);
        assertTrue(a3.id != bytes32(0));
    }
}

/// @notice The rounding fix: with fees rounded up, the fee actually charged must stay within the limits.
contract FeeRoundsUpLimitTest is Base {
    function _config() internal view override returns (UpDownVault.Config memory c) {
        c = super._config();
        c.feeRoundsUp = true;
    }

    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function test_oneCentStakeCannotPayAWholeCentFee() public {
        // 1% of 1 cent rounds up to 1 cent: 100% of the stake. Refused.
        UpDownVault.CallIntent memory it = _intent(alice, 0, CENT, 30);
        it.maxFeeBps = 100;
        _openExpectRejected(
            _one(_item(it, aliceDeviceKey, 190, 100, 0)),
            _one(_reading(MATCH, seq, 600, 0)),
            0,
            UpDownVault.Refusal.FeeTooHigh
        );
    }

    function test_roundedUpFeeWithinTheLimitsIsTaken() public {
        // 1 USDT at 1%: exactly 1 cent.
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 100, 0);
        _settleOne(c, -1);
        assertEq(_fees(), 1 * CENT);
    }
}
