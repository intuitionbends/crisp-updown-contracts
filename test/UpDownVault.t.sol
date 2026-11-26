// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Base} from "./utils/Base.sol";
import {UpDownVault} from "../src/UpDownVault.sol";
import {MockUSDT, NoSigAccount} from "./utils/Mocks.sol";

contract ConstructorTest is Base {
    function test_setsEverything() public view {
        assertEq(address(vault.token()), address(usdt));
        assertEq(vault.admin(), admin);
        assertEq(vault.operator(), operator);
        assertEq(vault.oracle(), oracle);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.unit(), CENT);
        assertEq(vault.feeLimitBps(), 500);
        assertEq(vault.silenceSeconds(), 6 hours);
        assertEq(vault.dayOffsetSeconds(), 8 hours);
        assertEq(vault.maxPriceX100(), 500);
        assertEq(vault.maxOvershootSeconds(), 20);
        assertEq(vault.maxEntryLag(), 3);
    }

    function test_revert_zeroAddresses() public {
        for (uint256 k; k < 6; ++k) {
            UpDownVault.Config memory c = _config();
            if (k == 0) c.token = address(0);
            if (k == 1) c.admin = address(0);
            if (k == 2) c.operator = address(0);
            if (k == 3) c.oracle = address(0);
            if (k == 4) c.guardian = address(0);
            if (k == 5) c.feeRecipient = address(0);
            vm.expectRevert(UpDownVault.ZeroAddress.selector);
            new UpDownVault(c);
        }
    }

    function test_revert_badConfig() public {
        for (uint256 k; k < 6; ++k) {
            UpDownVault.Config memory c = _config();
            if (k == 0) c.token = makeAddr("not a contract");
            if (k == 1) c.unit = 0;
            if (k == 2) c.feeLimitBps = 10_001;
            if (k == 3) c.silenceSeconds = 0;
            if (k == 4) c.dayOffsetSeconds = 1 days;
            if (k == 5) c.maxPriceX100 = 100;
            vm.expectRevert(UpDownVault.BadConfig.selector);
            new UpDownVault(c);
        }
    }

    function test_domainSeparatorFollowsChainId() public {
        bytes32 here = vault.domainSeparator();
        vm.chainId(97);
        assertTrue(vault.domainSeparator() != here, "a signature for one chain must not verify on another");
    }
}

contract AuthoriseTest is Base {
    function test_eoaAccount() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        _authorise(p, aliceKey);
        (uint96 cap, uint32 until, uint64 perCall, uint64 daily) = vault.permissions(alice, aliceDevice);
        assertEq(cap, 1_000 * USDT);
        assertEq(until, p.validUntil);
        assertEq(perCall, 100 * USDT / CENT);
        assertEq(daily, 500 * USDT / CENT);
        assertEq(vault.permissionNonce(alice, aliceDevice), 1);
    }

    function test_smartAccountErc1271() public {
        _authorise(_permission(bob, bobDevice, 1), bobOwnerKey);
        (, uint32 until,,) = vault.permissions(bob, bobDevice);
        assertGt(until, 0);
    }

    function test_newerNonceReplaces() public {
        _authorise(_permission(alice, aliceDevice, 1), aliceKey);
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 5);
        p.floatCap = 7 * USDT;
        _authorise(p, aliceKey);
        (uint96 cap,,,) = vault.permissions(alice, aliceDevice);
        assertEq(cap, 7 * USDT);
    }

    function test_severalDevicesPerAccount() public {
        (address second, uint256 secondKey) = makeAddrAndKey("aliceLaptop");
        _authorise(_permission(alice, aliceDevice, 1), aliceKey);
        _authorise(_permission(alice, second, 1), aliceKey);
        _fill(alice, second, 10 * USDT);
        Opened memory c = _openOne(alice, secondKey, 0, 1 * USDT, 190, 0, 0);
        assertTrue(vault.calls(c.id) != bytes32(0));
    }

    function test_revert_notOperator() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.authorise(p, sig);
    }

    function test_revert_zeroAddress() public {
        UpDownVault.Permission memory p = _permission(address(0), aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.ZeroAddress.selector);
        vault.authorise(p, sig);

        p = _permission(alice, address(0), 1);
        sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.ZeroAddress.selector);
        vault.authorise(p, sig);
    }

    function test_revert_expired() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        p.validUntil = uint64(block.timestamp - 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.PermissionExpired.selector);
        vault.authorise(p, sig);
    }

    function test_revert_staleNonce_replayAndOlder() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 3);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vault.authorise(p, sig);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.StaleNonce.selector);
        vault.authorise(p, sig);

        UpDownVault.Permission memory older = _permission(alice, aliceDevice, 2);
        bytes memory sig2 = _sign(aliceKey, vault.hashPermission(older));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.StaleNonce.selector);
        vault.authorise(older, sig2);
    }

    function test_revert_nonceZeroIsStale() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 0);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.StaleNonce.selector);
        vault.authorise(p, sig);
    }

    function test_revert_amountTooLarge() public {
        for (uint256 k; k < 4; ++k) {
            UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
            if (k == 0) p.floatCap = uint256(type(uint96).max) + 1;
            if (k == 1) p.validUntil = uint64(type(uint32).max) + 1;
            if (k == 2) p.perCallMax = (uint256(type(uint64).max) + 1) * CENT;
            if (k == 3) p.dailyLossLimit = (uint256(uint64(type(int64).max)) + 1) * CENT;
            bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
            vm.prank(operator);
            vm.expectRevert(UpDownVault.AmountTooLarge.selector);
            vault.authorise(p, sig);
        }
    }

    function test_revert_badSignature() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        // Signed by the device key, not the account.
        bytes memory sig = _sign(aliceDeviceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, sig);

        // Smart account: a signature by someone other than its owner.
        UpDownVault.Permission memory q = _permission(bob, bobDevice, 1);
        bytes memory bad = _sign(aliceKey, vault.hashPermission(q));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(q, bad);

        // Wrong length.
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, hex"1234");

        // A field changed after signing.
        bytes memory good = _sign(aliceKey, vault.hashPermission(p));
        p.floatCap += 1;
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, good);
    }

    function test_revert_highSMalleable() public {
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, vault.hashPermission(p));
        uint256 n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes memory flipped = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, flipped);
    }

    function test_revert_contractWithoutErc1271() public {
        address acct = address(new NoSigAccount());
        UpDownVault.Permission memory p = _permission(acct, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.BadSignature.selector);
        vault.authorise(p, sig);
    }

    function test_worksWhilePaused() public {
        vm.prank(guardian);
        vault.pause();
        _authorise(_permission(alice, aliceDevice, 1), aliceKey);
    }
}

contract FillTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
    }

    function test_fill() public {
        uint256 before = usdt.balanceOf(alice);
        _fill(alice, aliceDevice, 50 * USDT);
        assertEq(_float(alice), 50 * USDT);
        assertEq(usdt.balanceOf(alice), before - 50 * USDT);
        _fill(bob, bobDevice, 1 * USDT + 3); // any amount, dust included
        assertEq(_float(bob), 1 * USDT + 3);
    }

    function test_fillUpToCapExactly() public {
        _fill(alice, aliceDevice, 1_000 * USDT);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.OverFloatCap.selector);
        vault.fill(alice, aliceDevice, 1);
    }

    function test_revert_capCountsOpenStakes() public {
        _fill(alice, aliceDevice, 1_000 * USDT);
        _openOne(alice, aliceDeviceKey, 0, 100 * USDT, 190, 0, 0);
        // float 900 + open 100 = 1,000: still at the cap.
        vm.prank(operator);
        vm.expectRevert(UpDownVault.OverFloatCap.selector);
        vault.fill(alice, aliceDevice, 1);
    }

    function test_revert_notOperator() public {
        vm.prank(alice);
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.fill(alice, aliceDevice, 1);
    }

    function test_revert_paused() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert(UpDownVault.IsPaused.selector);
        vault.fill(alice, aliceDevice, 1);
    }

    function test_revert_noOrExpiredPermission() public {
        vm.prank(operator);
        vm.expectRevert(UpDownVault.PermissionExpired.selector);
        vault.fill(alice, makeAddr("unknown"), 1);

        vm.warp(block.timestamp + 31 days);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.PermissionExpired.selector);
        vault.fill(alice, aliceDevice, 1);
    }

    function test_revert_transferFails() public {
        vm.prank(alice);
        usdt.approve(address(vault), 0);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.TransferFailed.selector);
        vault.fill(alice, aliceDevice, 1);

        vm.prank(alice);
        usdt.approve(address(vault), type(uint256).max);
        usdt.setReturnFalse(true);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.TransferFailed.selector);
        vault.fill(alice, aliceDevice, 1);
    }
}

contract OpenTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 500 * USDT);
        _fill(bob, bobDevice, 500 * USDT);
    }

    function _expectOpenRefused(
        UpDownVault.OpenItem memory o,
        UpDownVault.SignedReading memory r,
        UpDownVault.Refusal why
    ) internal {
        uint256 houseBefore = _houseFree();
        _openExpectRejected(_one(o), _one(r), 0, why);
        assertEq(_houseFree(), houseBefore, "house moved");
    }

    function _entry() internal view returns (UpDownVault.SignedReading memory) {
        return _reading(MATCH, seq, 600, 1_000);
    }

    function test_openLocksStakeAndLiability() public {
        uint256 houseBefore = _houseFree();
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 1_000);
        // fee 1% of 1,000 cents = 10; net 990; payout 1,881; liability 891 cents.
        assertEq(_float(alice), 490 * USDT);
        assertEq(_openStake(alice), 10 * USDT);
        assertEq(_houseLocked(), 891 * CENT);
        assertEq(_houseFree(), houseBefore - 891 * CENT);
        assertEq(vault.calls(c.id), vault.hashCall(c.rec));
        assertEq(c.rec.settleAt, 630);
    }

    function test_batchOfTwoAccountsSharesReading() public {
        UpDownVault.SignedReading memory r = _entry();
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](2);
        items[0] = _item(_intent(alice, 0, 5 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        items[1] = _item(_intent(bob, 1, 7 * USDT, 60), bobDeviceKey, 210, 50, 0);
        vm.prank(operator);
        vault.openCalls(items, _one(r));
        assertEq(_openStake(alice), 5 * USDT);
        assertEq(_openStake(bob), 7 * USDT);
    }

    function test_entryMayLagSeenUpToLimit() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        UpDownVault.SignedReading memory r = _reading(MATCH, it.readingSeen + 3, 600, 0);
        UpDownVault.OpenItem memory o = _item(it, aliceDeviceKey, 190, 0, 0);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
    }

    function test_revert_notOperator() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _entry();
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.openCalls(_one(o), _one(r));
    }

    function test_revert_paused() public {
        vm.prank(guardian);
        vault.pause();
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _entry();
        vm.prank(operator);
        vm.expectRevert(UpDownVault.IsPaused.selector);
        vault.openCalls(_one(o), _one(r));
    }

    function test_revert_badReading() public {
        UpDownVault.SignedReading memory r = _entry();
        r.signature = _sign(aliceKey, vault.hashReading(r.reading)); // not the oracle
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 0));
        vault.openCalls(_one(o), _one(r));

        // A reading altered after the oracle signed it.
        r = _entry();
        r.reading.lead += 1;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 0));
        vault.openCalls(_one(o), _one(r));
    }

    function test_revert_expired() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.deadline = uint64(block.timestamp - 1);
        _expectOpenRefused(_item(it, aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.Expired);
    }

    function test_revert_badSide() public {
        UpDownVault.CallIntent memory it = _intent(alice, 2, 1 * USDT, 30);
        _expectOpenRefused(_item(it, aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.BadSide);
    }

    function test_revert_badStake() public {
        _expectOpenRefused(
            _item(_intent(alice, 0, 0, 30), aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.BadStake
        );
        _expectOpenRefused(
            _item(_intent(alice, 0, CENT + 1, 30), aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.BadStake
        );
    }

    function test_revert_badLength() public {
        _expectOpenRefused(
            _item(_intent(alice, 0, 1 * USDT, 0), aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.BadLength
        );
    }

    function test_revert_noPermission() public {
        // Signed by a key the account never authorised.
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        _expectOpenRefused(
            _item(_intent(alice, 0, 1 * USDT, 30), strangerKey, 190, 0, 0), _entry(), UpDownVault.Refusal.NoPermission
        );
        // Bob's device signing for Alice.
        _expectOpenRefused(
            _item(_intent(alice, 0, 1 * USDT, 30), bobDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.NoPermission
        );
        // A malformed signature.
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        o.signature = hex"00";
        _expectOpenRefused(o, _entry(), UpDownVault.Refusal.NoPermission);
        // The intent altered after signing recovers some other key.
        o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        o.intent.stake = 2 * USDT;
        _expectOpenRefused(o, _entry(), UpDownVault.Refusal.NoPermission);
    }

    function test_revert_permissionExpiredOrRevoked() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.deadline = uint64(block.timestamp + 40 days);
        vm.warp(block.timestamp + 31 days);
        _expectOpenRefused(_item(it, aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.NoPermission);

        vm.prank(bob);
        vault.revoke(bobDevice);
        UpDownVault.CallIntent memory jt = _intent(bob, 0, 1 * USDT, 30);
        _expectOpenRefused(_item(jt, bobDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.NoPermission);
    }

    function test_revert_overPerCallMax() public {
        _expectOpenRefused(
            _item(_intent(alice, 0, 100 * USDT + CENT, 30), aliceDeviceKey, 190, 0, 0),
            _entry(),
            UpDownVault.Refusal.OverPerCallMax
        );
    }

    function test_revert_priceBelowSignedMinimum() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.minPriceX100 = 185;
        _expectOpenRefused(_item(it, aliceDeviceKey, 184, 0, 0), _entry(), UpDownVault.Refusal.PriceBelowMin);
    }

    function test_revert_priceOutOfRange() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.minPriceX100 = 0;
        _expectOpenRefused(_item(it, aliceDeviceKey, 100, 0, 0), _entry(), UpDownVault.Refusal.PriceOutOfRange);
        _expectOpenRefused(_item(it, aliceDeviceKey, 501, 0, 0), _entry(), UpDownVault.Refusal.PriceOutOfRange);
    }

    function test_revert_feeAboveCeilingOrSignedMax() public {
        // Ceiling is 100 bps.
        _expectOpenRefused(
            _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 101, 0),
            _entry(),
            UpDownVault.Refusal.FeeTooHigh
        );
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        it.maxFeeBps = 50;
        _expectOpenRefused(_item(it, aliceDeviceKey, 190, 51, 0), _entry(), UpDownVault.Refusal.FeeTooHigh);
    }

    function test_revert_wrongMatch() public {
        _expectOpenRefused(
            _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0),
            _reading(OTHER_MATCH, seq, 600, 0),
            UpDownVault.Refusal.WrongMatch
        );
    }

    function test_revert_entryOutOfRange() public {
        UpDownVault.CallIntent memory it = _intent(alice, 0, 1 * USDT, 30);
        _expectOpenRefused(
            _item(it, aliceDeviceKey, 190, 0, 0),
            _reading(MATCH, it.readingSeen - 1, 600, 0),
            UpDownVault.Refusal.EntryOutOfRange
        );
        _expectOpenRefused(
            _item(it, aliceDeviceKey, 190, 0, 0),
            _reading(MATCH, it.readingSeen + 4, 600, 0),
            UpDownVault.Refusal.EntryOutOfRange
        );
    }

    function test_revert_duplicate() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _entry();
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
        _expectOpenRefused(o, r, UpDownVault.Refusal.Duplicate);

        // Twice in one batch: the first opens, the second is rejected at index 1.
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](2);
        items[0] = _item(_intent(bob, 0, 1 * USDT, 30), bobDeviceKey, 190, 0, 0);
        items[1] = items[0];
        _openExpectRejected(items, _one(r), 1, UpDownVault.Refusal.Duplicate);
        assertEq(_openStake(bob), 1 * USDT, "taken once");
    }

    function test_revert_duplicateAfterSettle() public {
        UpDownVault.SignedReading memory r = _entry();
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
        seq += 1;
        Opened memory c = Opened({id: vault.hashIntent(o.intent), rec: _record(o, r.reading, 0)});
        _settleOne(c, 2_000);
        _expectOpenRefused(o, r, UpDownVault.Refusal.Duplicate);
    }

    function test_revert_floatShort() public {
        vm.prank(alice);
        vault.recall(alice, 490 * USDT);
        _expectOpenRefused(
            _item(_intent(alice, 0, 10 * USDT + CENT, 30), aliceDeviceKey, 190, 0, 0),
            _entry(),
            UpDownVault.Refusal.FloatShort
        );
    }

    function test_revert_houseShort() public {
        uint256 take = _houseFree() - 89 * CENT;
        vm.prank(admin);
        vault.withdrawHouse(admin, take);
        // A 1 USDT stake at 1.90 locks 90 cents; only 89 are free.
        _expectOpenRefused(
            _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0), _entry(), UpDownVault.Refusal.HouseShort
        );
        // 89 cents is enough for a stake whose liability is 89: the house is checked call by call.
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 98 * CENT, 191, 0, 0);
        assertEq(_houseLocked(), 89 * CENT);
        assertEq(_houseFree(), 0);
        assertTrue(vault.calls(c.id) != bytes32(0));
    }

    function test_houseShortRejectsOnlyTheCallThatDoesNotFit() public {
        uint256 take = _houseFree() - 100 * CENT;
        vm.prank(admin);
        vault.withdrawHouse(admin, take);
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](2);
        items[0] = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0); // locks 90
        items[1] = _item(_intent(bob, 0, 1 * USDT, 30), bobDeviceKey, 190, 0, 0); // 10 left: rejected
        _openExpectRejected(items, _one(_entry()), 1, UpDownVault.Refusal.HouseShort);
        assertEq(_openStake(alice), 1 * USDT);
        assertEq(_openStake(bob), 0);
        assertEq(_houseLocked(), 90 * CENT);
    }

    function test_badItemDoesNotStopTheRest() public {
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](2);
        items[0] = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        items[1] = _item(_intent(bob, 0, 1 * USDT, 30), bobDeviceKey, 190, 400, 0);
        _openExpectRejected(items, _one(_entry()), 1, UpDownVault.Refusal.FeeTooHigh);
        assertEq(_openStake(alice), 1 * USDT, "the good call opened");
        assertEq(_openStake(bob), 0);
    }

    function test_revert_badReadingIndex() public {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 1);
        _expectOpenRefused(o, _entry(), UpDownVault.Refusal.BadReadingIndex);
    }
}

contract DailyLossTest is Base {
    function setUp() public override {
        super.setUp();
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        p.dailyLossLimit = 30 * USDT;
        _authorise(p, aliceKey);
        _fill(alice, aliceDevice, 500 * USDT);
    }

    function _try(uint256 stake) internal returns (bool ok) {
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, stake, 30), aliceDeviceKey, 190, 0, 0);
        UpDownVault.SignedReading memory r = _reading(MATCH, seq, 600, 0);
        bytes32 id = vault.hashIntent(o.intent);
        vm.recordLogs();
        vm.prank(operator);
        vault.openCalls(_one(o), _one(r));
        ok = vault.calls(id) != bytes32(0);
        if (ok) {
            seq += 1;
        } else {
            (bool found,, UpDownVault.Refusal why) =
                _eventFor(vm.getRecordedLogs(), UpDownVault.CallRejected.selector, id);
            assertTrue(found);
            assertEq(uint8(why), uint8(UpDownVault.Refusal.DailyLossLimit));
        }
    }

    function test_openStakesCountAsAtRisk() public {
        assertTrue(_try(20 * USDT));
        assertFalse(_try(10 * USDT + CENT));
        assertTrue(_try(10 * USDT));
    }

    function test_lossesCountFullStakeFeeIncluded() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 20 * USDT, 190, 100, 0);
        _settleOne(c, -5); // Up loses
        assertEq(_dayLoss(alice), 2_000);
        assertFalse(_try(10 * USDT + CENT));
        assertTrue(_try(10 * USDT));
    }

    function test_winsOffsetLosses() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 20 * USDT, 190, 0, 0);
        _settleOne(c, -5); // lost 20
        Opened memory d = _openOne(alice, aliceDeviceKey, 1, 10 * USDT, 190, 0, 0);
        _settleOne(d, -5); // Down wins: +9 profit
        assertEq(_dayLoss(alice), 2_000 - 900);
        assertTrue(_try(19 * USDT));
    }

    function test_tiesAndVoidsDoNotCount() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 20 * USDT, 190, 100, 7);
        _settleOne(c, 7);
        assertEq(_dayLoss(alice), 0);
        assertTrue(_try(30 * USDT));
    }

    function test_resetsAtDayBoundary() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 30 * USDT, 190, 0, 0);
        _settleOne(c, -1);
        assertFalse(_try(CENT));
        // Day boundary is midnight UTC+8 (offset 8h).
        uint256 nextDay = ((block.timestamp + 8 hours) / 1 days + 1) * 1 days - 8 hours;
        vm.warp(nextDay - 1);
        assertFalse(_try(CENT));
        vm.warp(nextDay);
        assertEq(vault.today(), (nextDay + 8 hours) / 1 days);
        assertTrue(_try(30 * USDT));
    }
}

contract SettleTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 500 * USDT);
        _fill(bob, bobDevice, 500 * USDT);
    }

    function test_wonPaysNetTimesPriceAndTakesFee() public {
        uint256 houseBefore = _houseFree();
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 1_000);
        _settleOne(c, 1_001);
        // net 990 cents x 1.90 = 1,881 cents back; fee 10 cents; house paid 891.
        assertEq(_float(alice), 490 * USDT + 1_881 * CENT);
        assertEq(_fees(), 10 * CENT);
        assertEq(_houseFree(), houseBefore - 891 * CENT);
        assertEq(_houseLocked(), 0);
        assertEq(_openStake(alice), 0);
        assertEq(vault.calls(c.id), bytes32(uint256(1)));
    }

    function test_lostHouseKeepsNetAndFeeSeparate() public {
        uint256 houseBefore = _houseFree();
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 1_000);
        _settleOne(c, 999);
        assertEq(_float(alice), 490 * USDT);
        assertEq(_fees(), 10 * CENT);
        assertEq(_houseFree(), houseBefore + 990 * CENT);
        assertEq(_houseLocked(), 0);
    }

    function test_tiedReturnsWholeStakeFeeIncluded() public {
        uint256 houseBefore = _houseFree();
        Opened memory c = _openOne(alice, aliceDeviceKey, 1, 10 * USDT, 190, 100, -500);
        _settleOne(c, -500);
        assertEq(_float(alice), 500 * USDT);
        assertEq(_fees(), 0);
        assertEq(_houseFree(), houseBefore);
    }

    function test_feeRoundsDownToTheCent() public {
        // 99 cents at 1%: 0.99 cents of fee rounds to nothing.
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 99 * CENT, 190, 100, 0);
        _settleOne(c, 1);
        assertEq(_fees(), 0);
        assertEq(_float(alice), 500 * USDT - 99 * CENT + 188 * CENT); // 99 x 1.90 = 188.1 -> 188
    }

    function test_feeRateFixedAtOpen() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 0);
        vm.prank(admin);
        vault.setFeeBps(0);
        _settleOne(c, -1);
        assertEq(_fees(), 10 * CENT, "a call keeps the rate it opened with");
    }

    function test_settleOnExactBoundaryAndMaxOvershoot() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        _settleAt(c, 5, 629, 650); // 20 s past 630: allowed
        assertEq(vault.calls(c.id), bytes32(uint256(1)));
    }

    function test_prevMayBeTheEntryReading() public {
        UpDownVault.SignedReading memory entry = _reading(MATCH, seq, 600, 0);
        UpDownVault.OpenItem memory o = _item(_intent(alice, 0, 1 * USDT, 30), aliceDeviceKey, 190, 0, 0);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(entry));
        Opened memory c = Opened({id: vault.hashIntent(o.intent), rec: _record(o, entry.reading, 0)});
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, 640, 3);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vault.settleCalls(items, _two(entry, q));
        assertEq(_float(alice), 500 * USDT + 90 * CENT);
    }

    function test_batchSettlesManyOnOneReadingPair() public {
        Opened memory a = _openOne(alice, aliceDeviceKey, 0, 2 * USDT, 190, 100, 50);
        seq -= 1; // same entry reading seq for bob, same clock
        Opened memory b = _openOne(bob, bobDeviceKey, 1, 3 * USDT, 210, 0, 50);
        UpDownVault.SignedReading memory p = _reading(MATCH, seq, 629, 50);
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, 631, 80);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](2);
        items[0] = UpDownVault.SettleItem({id: a.id, call: a.rec, prev: 0, settle: 1});
        items[1] = UpDownVault.SettleItem({id: b.id, call: b.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vault.settleCalls(items, _two(p, q));
        // Alice Up wins: net 198 x 1.90 = 376 cents. Bob Down loses.
        assertEq(_float(alice), 498 * USDT + 376 * CENT);
        assertEq(_float(bob), 497 * USDT);
        assertEq(_fees(), 2 * CENT);
        assertEq(_houseLocked(), 0);
    }

    function test_worksWhilePaused() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        vm.prank(guardian);
        vault.pause();
        _settleOne(c, 1);
    }

    function _expectSettleRefused(
        Opened memory c,
        UpDownVault.SignedReading memory p,
        UpDownVault.SignedReading memory q,
        UpDownVault.Refusal why
    ) internal {
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.SettleRefused.selector, 0, why));
        vault.settleCalls(items, _two(p, q));
    }

    function _expectSettleSkipped(
        Opened memory c,
        UpDownVault.SignedReading memory p,
        UpDownVault.SignedReading memory q,
        UpDownVault.Refusal why
    ) internal {
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        uint256 floatBefore = _float(c.rec.account);
        uint256 freeBefore = _houseFree();
        uint256 feesBefore = _fees();
        vm.expectEmit(true, false, false, true, address(vault));
        emit UpDownVault.CallSkipped(c.id, 0, why);
        vm.prank(operator);
        vault.settleCalls(items, _two(p, q));
        assertEq(_float(c.rec.account), floatBefore);
        assertEq(_houseFree(), freeBefore);
        assertEq(_fees(), feesBefore);
    }

    function test_revert_notOperator() public {
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](0);
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.settleCalls(items, new UpDownVault.SignedReading[](0));
    }

    function test_revert_badReading() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        UpDownVault.SignedReading memory p = _reading(MATCH, seq, 629, 0);
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, 630, 9);
        q.reading.lead = 10;
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 1));
        vault.settleCalls(items, _two(p, q));
    }

    function test_revert_unknownCall() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        UpDownVault.SignedReading memory p = _reading(MATCH, seq, 629, 0);
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, 630, 9);
        // A record that does not match what was opened (operator claims a better price for the house).
        c.rec.priceX100 = 150;
        _expectSettleRefused(c, p, q, UpDownVault.Refusal.UnknownCall);
        c.rec.priceX100 = 190;
        // A call that was never opened.
        Opened memory never = c;
        bytes32 realId = c.id;
        never.id = keccak256("never opened");
        _expectSettleRefused(never, p, q, UpDownVault.Refusal.UnknownCall);
        c.id = realId;
    }

    function test_settlingTwiceIsSkipped_retrySafe() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        _settleOne(c, 9);
        // A resent batch: already final, so it changes nothing and does not stop the batch.
        _expectSettleSkipped(
            c, _reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 630, -9), UpDownVault.Refusal.AlreadyFinal
        );
    }

    function test_skippedItemDoesNotStopTheRest() public {
        Opened memory a = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        seq -= 1;
        Opened memory b = _openOne(bob, bobDeviceKey, 0, 1 * USDT, 190, 0, 0);
        _settleOne(a, 5);
        UpDownVault.SignedReading memory p = _reading(MATCH, seq, 629, 0);
        UpDownVault.SignedReading memory q = _reading(MATCH, seq + 1, 630, 5);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](2);
        items[0] = UpDownVault.SettleItem({id: a.id, call: a.rec, prev: 0, settle: 1});
        items[1] = UpDownVault.SettleItem({id: b.id, call: b.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vault.settleCalls(items, _two(p, q));
        assertEq(vault.calls(b.id), bytes32(uint256(1)), "b settled");
        assertEq(_float(bob), 500 * USDT + 90 * CENT);
    }

    function test_revert_badReadingIndex() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 2});
        UpDownVault.SignedReading[] memory rs = _two(_reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 630, 9));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UpDownVault.SettleRefused.selector, 0, UpDownVault.Refusal.BadReadingIndex)
        );
        vault.settleCalls(items, rs);
    }

    function test_staleAfterExitIsSkipped() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(alice);
        vault.exit();
        _expectSettleSkipped(
            c, _reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 630, 9), UpDownVault.Refusal.StaleCall
        );
    }

    function test_revert_wrongMatch() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        _expectSettleRefused(
            c, _reading(OTHER_MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 630, 9), UpDownVault.Refusal.WrongMatch
        );
        _expectSettleRefused(
            c, _reading(MATCH, seq, 629, 0), _reading(OTHER_MATCH, seq + 1, 630, 9), UpDownVault.Refusal.WrongMatch
        );
    }

    function test_revert_notConsecutive() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        // A gap: a reading could lie between them.
        _expectSettleRefused(
            c, _reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 2, 630, 9), UpDownVault.Refusal.NotConsecutive
        );
        // Out of order.
        _expectSettleRefused(
            c, _reading(MATCH, seq + 1, 629, 0), _reading(MATCH, seq, 630, 9), UpDownVault.Refusal.NotConsecutive
        );
        // Both before the entry reading.
        uint64 e = c.rec.entrySeq;
        _expectSettleRefused(
            c, _reading(MATCH, e - 2, 629, 0), _reading(MATCH, e - 1, 630, 9), UpDownVault.Refusal.NotConsecutive
        );
    }

    function test_revert_notFirstAtOrAfter() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        // Not yet due: the "settle" reading is before 630.
        _expectSettleRefused(
            c, _reading(MATCH, seq, 628, 0), _reading(MATCH, seq + 1, 629, 9), UpDownVault.Refusal.NotFirstAtOrAfter
        );
        // Not the first: the previous reading was already at 630.
        _expectSettleRefused(
            c, _reading(MATCH, seq, 630, 0), _reading(MATCH, seq + 1, 631, 9), UpDownVault.Refusal.NotFirstAtOrAfter
        );
    }

    function test_revert_overshoot() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        _expectSettleRefused(
            c, _reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 651, 9), UpDownVault.Refusal.Overshoot
        );
    }
}

contract VoidTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 500 * USDT);
    }

    function _void(Opened memory c, uint8 reason) internal {
        UpDownVault.VoidItem[] memory items = new UpDownVault.VoidItem[](1);
        items[0] = UpDownVault.VoidItem({id: c.id, call: c.rec, reason: reason});
        vm.prank(operator);
        vault.voidCalls(items);
    }

    function _expectVoidSkipped(Opened memory c, UpDownVault.Refusal why) internal {
        UpDownVault.VoidItem[] memory items = new UpDownVault.VoidItem[](1);
        items[0] = UpDownVault.VoidItem({id: c.id, call: c.rec, reason: 1});
        uint256 freeBefore = _houseFree();
        vm.expectEmit(true, false, false, true, address(vault));
        emit UpDownVault.CallSkipped(c.id, 0, why);
        vm.prank(operator);
        vault.voidCalls(items);
        assertEq(_houseFree(), freeBefore);
    }

    function _expectVoidRefused(Opened memory c, uint8 reason, UpDownVault.Refusal why) internal {
        UpDownVault.VoidItem[] memory items = new UpDownVault.VoidItem[](1);
        items[0] = UpDownVault.VoidItem({id: c.id, call: c.rec, reason: reason});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.VoidRefused.selector, 0, why));
        vault.voidCalls(items);
    }

    function test_voidRefundsWholeStakeAndReleasesHouse() public {
        uint256 houseBefore = _houseFree();
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 100, 0);
        _void(c, vault.VOID_LATE_TICK());
        assertEq(_float(alice), 500 * USDT);
        assertEq(_fees(), 0);
        assertEq(_houseFree(), houseBefore);
        assertEq(_houseLocked(), 0);
        assertEq(vault.calls(c.id), bytes32(uint256(1)));
    }

    function test_everyListedReason() public {
        for (uint8 r = 1; r <= vault.MAX_VOID_REASON(); ++r) {
            Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
            _void(c, r);
        }
    }

    function test_worksWhilePaused() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        vm.prank(guardian);
        vault.pause();
        _void(c, 1);
    }

    function test_revert_notOperator() public {
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.voidCalls(new UpDownVault.VoidItem[](0));
    }

    function test_revert_badReason() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        _expectVoidRefused(c, 0, UpDownVault.Refusal.BadVoidReason);
        _expectVoidRefused(c, 9, UpDownVault.Refusal.BadVoidReason);
    }

    function test_revert_unknownOrAlreadyFinal() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        c.rec.stakeUnits += 1; // claim a bigger refund
        _expectVoidRefused(c, 1, UpDownVault.Refusal.UnknownCall);
        c.rec.stakeUnits -= 1;
        _void(c, 1);
        // Already final: a retried void is skipped and changes nothing.
        uint256 floatBefore = _float(alice);
        _expectVoidSkipped(c, UpDownVault.Refusal.AlreadyFinal);
        assertEq(_float(alice), floatBefore);
    }

    function test_staleAfterExitIsSkipped() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(alice);
        vault.exit();
        _expectVoidSkipped(c, UpDownVault.Refusal.StaleCall);
    }
}

contract RecallTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function test_operatorRecallsToOwner() public {
        uint256 before = usdt.balanceOf(alice);
        vm.prank(operator);
        vault.recall(alice, 40 * USDT);
        assertEq(usdt.balanceOf(alice), before + 40 * USDT);
        assertEq(_float(alice), 60 * USDT);
    }

    function test_userRecallsAll() public {
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.recall(alice, type(uint256).max);
        assertEq(usdt.balanceOf(alice), before + 100 * USDT);
        assertEq(_float(alice), 0);
    }

    function test_openStakeStaysUntilSettled() public {
        _openOne(alice, aliceDeviceKey, 0, 30 * USDT, 190, 0, 0);
        vm.prank(alice);
        vm.expectRevert(UpDownVault.InsufficientFloat.selector);
        vault.recall(alice, 70 * USDT + 1);
        vm.prank(operator);
        vault.recall(alice, type(uint256).max);
        assertEq(_openStake(alice), 30 * USDT);
    }

    function test_worksWhilePaused() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(alice);
        vault.recall(alice, 1);
    }

    function test_revert_notAllowed() public {
        vm.prank(bob);
        vm.expectRevert(UpDownVault.NotAllowed.selector);
        vault.recall(alice, 1);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.NotAllowed.selector);
        vault.recall(alice, 1);
    }

    function test_revert_overFloat() public {
        vm.prank(operator);
        vm.expectRevert(UpDownVault.InsufficientFloat.selector);
        vault.recall(alice, 100 * USDT + 1);
    }

    function test_revert_transferFails() public {
        usdt.setReturnFalse(true);
        vm.prank(alice);
        vm.expectRevert(UpDownVault.TransferFailed.selector);
        vault.recall(alice, 1);
    }
}

contract ExitTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function test_revert_operatorActive() public {
        uint256 t = vm.getBlockTimestamp();
        vm.prank(alice);
        vm.expectRevert(UpDownVault.OperatorActive.selector);
        vault.exit();
        vm.warp(t + 6 hours - 1);
        vm.prank(alice);
        vm.expectRevert(UpDownVault.OperatorActive.selector);
        vault.exit();
    }

    function test_afterSilenceRefundsOpenStakesAndSendsAll() public {
        uint256 houseBefore = _houseFree();
        _openOne(alice, aliceDeviceKey, 0, 30 * USDT, 190, 100, 0);
        vm.warp(block.timestamp + 6 hours);
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.exit();
        assertEq(usdt.balanceOf(alice), before + 100 * USDT);
        assertEq(_float(alice), 0);
        assertEq(_openStake(alice), 0);
        assertEq(_houseLocked(), 0);
        assertEq(_houseFree(), houseBefore);
        (,,, uint32 epoch,,,) = vault.accounts(alice);
        assertEq(epoch, 1);
    }

    function test_anyOperatorActionResetsSilence() public {
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 5 hours);
        _fill(bob, bobDevice, 1);
        vm.warp(t + 10 hours);
        vm.prank(alice);
        vm.expectRevert(UpDownVault.OperatorActive.selector);
        vault.exit();
    }

    function test_stuckCallOpensExitWhileOperatorBusy() public {
        _openOne(alice, aliceDeviceKey, 0, 30 * USDT, 190, 0, 0);
        // The operator keeps posting for others but never settles Alice's call.
        uint256 t = vm.getBlockTimestamp();
        for (uint256 k; k < 6; ++k) {
            t += 1 hours;
            vm.warp(t);
            _fill(bob, bobDevice, 1);
        }
        uint256 before = usdt.balanceOf(alice);
        vm.prank(alice);
        vault.exit();
        assertEq(usdt.balanceOf(alice), before + 100 * USDT);
    }

    function test_worksWhilePausedAndAccountCanPlayAgain() public {
        vm.prank(guardian);
        vault.pause();
        vm.warp(block.timestamp + 6 hours);
        vm.prank(alice);
        vault.exit();
        vm.prank(admin);
        vault.unpause();
        _fill(alice, aliceDevice, 10 * USDT);
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        assertEq(c.rec.epoch, 1);
        _settleOne(c, 1);
    }

    function test_revert_nothingToExit() public {
        vm.warp(block.timestamp + 6 hours);
        vm.prank(bob);
        vm.expectRevert(UpDownVault.NothingToExit.selector);
        vault.exit();
    }
}

contract RevokeTest is Base {
    function test_revokeStopsFillsAndCallsButOpenCallsStand() public {
        _authoriseDefaults();
        _fill(alice, aliceDevice, 10 * USDT);
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 1 * USDT, 190, 0, 0);
        vm.prank(alice);
        vault.revoke(aliceDevice);
        vm.prank(operator);
        vm.expectRevert(UpDownVault.PermissionExpired.selector);
        vault.fill(alice, aliceDevice, 1);
        _settleOne(c, 1);
        // The revoked permission cannot be replayed: its nonce is spent.
        UpDownVault.Permission memory p = _permission(alice, aliceDevice, 1);
        bytes memory sig = _sign(aliceKey, vault.hashPermission(p));
        vm.prank(operator);
        vm.expectRevert(UpDownVault.StaleNonce.selector);
        vault.authorise(p, sig);
    }
}

contract AdminTest is Base {
    function test_fundAndWithdrawHouse() public {
        uint256 free = _houseFree();
        vm.prank(admin);
        vault.fundHouse(5 * USDT);
        assertEq(_houseFree(), free + 5 * USDT);
        address treasury = makeAddr("treasury");
        vm.prank(admin);
        vault.withdrawHouse(treasury, 7 * USDT);
        assertEq(usdt.balanceOf(treasury), 7 * USDT);
        assertEq(_houseFree(), free - 2 * USDT);
    }

    function test_revert_fundHouse() public {
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.fundHouse(1);
        usdt.setReturnFalse(true);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.TransferFailed.selector);
        vault.fundHouse(1);
    }

    function test_revert_withdrawHouse() public {
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.withdrawHouse(admin, 1);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.ZeroAddress.selector);
        vault.withdrawHouse(address(0), 1);
    }

    function test_revert_withdrawHouseCannotTouchLocked() public {
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
        _openOne(alice, aliceDeviceKey, 0, 100 * USDT, 190, 0, 0);
        uint256 free = _houseFree();
        vm.prank(admin);
        vm.expectRevert(UpDownVault.InsufficientHouse.selector);
        vault.withdrawHouse(admin, free + 1);
        vm.prank(admin);
        vault.withdrawHouse(admin, free);
        assertEq(_houseLocked(), 90 * USDT);
    }

    function test_setFeeBps() public {
        vm.prank(admin);
        vault.setFeeBps(500);
        (,, uint16 bps,) = vault.state();
        assertEq(bps, 500);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.FeeAboveLimit.selector);
        vault.setFeeBps(501);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeBps(1);
    }

    function test_setFeeRecipient() public {
        address r = makeAddr("finance");
        vm.prank(admin);
        vault.setFeeRecipient(r);
        assertEq(vault.feeRecipient(), r);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeRecipient(r);
    }

    function test_twoStepAdmin() public {
        address safe = makeAddr("safe");
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.transferAdmin(safe);

        vm.prank(admin);
        vault.transferAdmin(safe);
        assertEq(vault.admin(), admin, "nothing moves until accepted");

        vm.prank(makeAddr("someone"));
        vm.expectRevert(UpDownVault.NotPendingAdmin.selector);
        vault.acceptAdmin();

        vm.prank(safe);
        vault.acceptAdmin();
        assertEq(vault.admin(), safe);
        assertEq(vault.pendingAdmin(), address(0));

        vm.prank(admin);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.setFeeBps(1);
    }

    function test_transferAdminCanBeCancelled() public {
        address safe = makeAddr("safe");
        vm.startPrank(admin);
        vault.transferAdmin(safe);
        vault.transferAdmin(address(0));
        vm.stopPrank();
        vm.prank(safe);
        vm.expectRevert(UpDownVault.NotPendingAdmin.selector);
        vault.acceptAdmin();
        // With nothing pending, address(0) cannot accept either.
        vm.prank(address(0));
        vm.expectRevert(UpDownVault.NotPendingAdmin.selector);
        vault.acceptAdmin();
    }

    function test_pauseAndUnpause() public {
        vm.expectRevert(UpDownVault.NotGuardian.selector);
        vault.pause();
        vm.prank(admin);
        vm.expectRevert(UpDownVault.NotGuardian.selector);
        vault.pause();

        vm.prank(guardian);
        vault.pause();
        (,,, bool paused) = vault.state();
        assertTrue(paused);

        vm.prank(guardian);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.unpause();
        vm.prank(admin);
        vault.unpause();
        (,,, paused) = vault.state();
        assertFalse(paused);
    }
}

contract FeesTest is Base {
    function setUp() public override {
        super.setUp();
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function test_anyoneSweepsWholeBalanceToRecipient() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 50 * USDT, 190, 100, 0);
        _settleOne(c, -1);
        vm.prank(guardian);
        vault.pause();
        vm.prank(makeAddr("anyone"));
        vault.withdrawFees();
        assertEq(usdt.balanceOf(feeRecipient), 50 * CENT);
        assertEq(_fees(), 0);
    }

    function test_zeroBalanceIsANoOp() public {
        vault.withdrawFees();
        assertEq(usdt.balanceOf(feeRecipient), 0);
    }

    function test_revert_transferFails() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 50 * USDT, 190, 100, 0);
        _settleOne(c, -1);
        usdt.setReturnFalse(true);
        vm.expectRevert(UpDownVault.TransferFailed.selector);
        vault.withdrawFees();
    }
}

/// The fee rounded up instead of down, as the owner may choose.
contract FeeRoundsUpTest is Base {
    function _config() internal view override returns (UpDownVault.Config memory c) {
        c = super._config();
        c.feeRoundsUp = true;
    }

    function test_feeRoundsUp() public view {
        assertEq(vault.feeOf(99, 100), 1);
        assertEq(vault.feeOf(100, 100), 1);
        assertEq(vault.feeOf(101, 100), 2);
        assertEq(vault.feeOf(0, 100), 0);
    }
}
