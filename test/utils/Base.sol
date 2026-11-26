// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {UpDownVault} from "../../src/UpDownVault.sol";
import {MockUSDT, MockSmartAccount} from "./Mocks.sol";

/// @notice Shared fixture: a vault on a mock 18-decimal USDT, an EOA player and a smart-account player, each with
///         a device key, and helpers that sign permissions, intents and readings with Foundry's local keys.
abstract contract Base is Test {
    uint256 internal constant CENT = 1e16;
    uint256 internal constant USDT = 1e18;
    bytes32 internal constant MATCH = keccak256("dota:8123456789");
    bytes32 internal constant OTHER_MATCH = keccak256("dota:8000000001");

    UpDownVault internal vault;
    MockUSDT internal usdt;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal guardian = makeAddr("guardian");
    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal oracleKey;
    address internal oracle;

    // An ordinary wallet player.
    uint256 internal aliceKey;
    address internal alice;
    uint256 internal aliceDeviceKey;
    address internal aliceDevice;

    // A smart-account player (ERC-1271), owned by bobOwner.
    uint256 internal bobOwnerKey;
    address internal bobOwner;
    address internal bob;
    uint256 internal bobDeviceKey;
    address internal bobDevice;

    uint64 internal seq = 100; // next reading sequence number
    uint256 internal intentNonce;

    function _config() internal view virtual returns (UpDownVault.Config memory c) {
        c = UpDownVault.Config({
            token: address(usdt),
            admin: admin,
            operator: operator,
            oracle: oracle,
            guardian: guardian,
            feeRecipient: feeRecipient,
            unit: CENT,
            feeLimitBps: 500,
            feeRoundsUp: false,
            silenceSeconds: 6 hours,
            dayOffsetSeconds: 8 hours,
            maxPriceX100: 500,
            maxOvershootSeconds: 20,
            maxEntryLag: 3,
            keyChangeDelay: 24 hours
        });
    }

    function setUp() public virtual {
        vm.warp(1_795_000_000);
        usdt = new MockUSDT();
        (oracle, oracleKey) = makeAddrAndKey("oracle");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (aliceDevice, aliceDeviceKey) = makeAddrAndKey("aliceDevice");
        (bobOwner, bobOwnerKey) = makeAddrAndKey("bobOwner");
        (bobDevice, bobDeviceKey) = makeAddrAndKey("bobDevice");
        bob = address(new MockSmartAccount(bobOwner));

        vault = new UpDownVault(_config());

        usdt.mint(admin, 1_000_000 * USDT);
        vm.startPrank(admin);
        usdt.approve(address(vault), type(uint256).max);
        vault.fundHouse(100_000 * USDT);
        vault.setFeeBps(100);
        vm.stopPrank();

        for (uint256 k; k < 2; ++k) {
            address who = k == 0 ? alice : bob;
            usdt.mint(who, 10_000 * USDT);
            vm.prank(who);
            usdt.approve(address(vault), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------------------------------ signing

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permission(address account, address device, uint64 nonce)
        internal
        view
        returns (UpDownVault.Permission memory)
    {
        return UpDownVault.Permission({
            account: account,
            deviceKey: device,
            floatCap: 1_000 * USDT,
            perCallMax: 100 * USDT,
            dailyLossLimit: 500 * USDT,
            validUntil: uint64(block.timestamp + 30 days),
            nonce: nonce
        });
    }

    function _authorise(UpDownVault.Permission memory p, uint256 signerKey) internal {
        bytes memory sig = _sign(signerKey, vault.hashPermission(p));
        vm.prank(operator);
        vault.authorise(p, sig);
    }

    function _authoriseDefaults() internal {
        _authorise(_permission(alice, aliceDevice, 1), aliceKey);
        _authorise(_permission(bob, bobDevice, 1), bobOwnerKey);
    }

    function _fill(address account, address device, uint256 amount) internal {
        vm.prank(operator);
        vault.fill(account, device, amount);
    }

    function _reading(bytes32 matchId, uint64 s, int32 clock, int64 lead)
        internal
        view
        returns (UpDownVault.SignedReading memory)
    {
        UpDownVault.Reading memory r = UpDownVault.Reading({matchId: matchId, seq: s, clock: clock, lead: lead});
        return UpDownVault.SignedReading({reading: r, signature: _sign(oracleKey, vault.hashReading(r))});
    }

    function _intent(address account, uint8 side, uint256 stake, uint32 length)
        internal
        returns (UpDownVault.CallIntent memory)
    {
        return UpDownVault.CallIntent({
            account: account,
            matchId: MATCH,
            side: side,
            stake: stake,
            length: length,
            minPriceX100: 101,
            maxFeeBps: 500,
            readingSeen: seq,
            nonce: ++intentNonce,
            deadline: uint64(block.timestamp + 60)
        });
    }

    function _item(UpDownVault.CallIntent memory it, uint256 deviceKey, uint16 price, uint16 feeBps, uint256 entry)
        internal
        view
        returns (UpDownVault.OpenItem memory)
    {
        return UpDownVault.OpenItem({
            intent: it,
            signature: _sign(deviceKey, vault.hashIntent(it)),
            priceX100: price,
            feeBps: feeBps,
            entry: entry
        });
    }

    function _one(UpDownVault.OpenItem memory o) internal pure returns (UpDownVault.OpenItem[] memory a) {
        a = new UpDownVault.OpenItem[](1);
        a[0] = o;
    }

    function _one(UpDownVault.SignedReading memory r) internal pure returns (UpDownVault.SignedReading[] memory a) {
        a = new UpDownVault.SignedReading[](1);
        a[0] = r;
    }

    function _two(UpDownVault.SignedReading memory r0, UpDownVault.SignedReading memory r1)
        internal
        pure
        returns (UpDownVault.SignedReading[] memory a)
    {
        a = new UpDownVault.SignedReading[](2);
        a[0] = r0;
        a[1] = r1;
    }

    function _record(UpDownVault.OpenItem memory o, UpDownVault.Reading memory entry, uint32 epoch)
        internal
        pure
        returns (UpDownVault.CallRecord memory)
    {
        return UpDownVault.CallRecord({
            account: o.intent.account,
            matchId: o.intent.matchId,
            side: o.intent.side,
            stakeUnits: uint64(o.intent.stake / CENT),
            priceX100: o.priceX100,
            feeBps: o.feeBps,
            entryLead: entry.lead,
            entrySeq: entry.seq,
            settleAt: int64(entry.clock) + int64(uint64(o.intent.length)),
            epoch: epoch
        });
    }

    struct Opened {
        bytes32 id;
        UpDownVault.CallRecord rec;
    }

    /// Opens one call at entry clock 600 on a fresh reading with `entryLead`; returns its id and record.
    function _openOne(
        address account,
        uint256 deviceKey,
        uint8 side,
        uint256 stake,
        uint16 price,
        uint16 feeBps,
        int64 entryLead
    ) internal returns (Opened memory r) {
        UpDownVault.SignedReading memory entry = _reading(MATCH, seq, 600, entryLead);
        UpDownVault.OpenItem memory o = _item(_intent(account, side, stake, 30), deviceKey, price, feeBps, 0);
        (,,, uint32 epoch,,,) = vault.accounts(account);
        vm.prank(operator);
        vault.openCalls(_one(o), _one(entry));
        seq += 1;
        r.id = vault.hashIntent(o.intent);
        r.rec = _record(o, entry.reading, epoch);
    }

    /// Settles `c` on a reading pair straddling its settle time, the settle reading `lead`.
    function _settleOne(Opened memory c, int64 lead) internal {
        _settleAt(c, lead, int32(c.rec.settleAt) - 1, int32(c.rec.settleAt));
    }

    function _settleAt(Opened memory c, int64 lead, int32 prevClock, int32 settleClock) internal {
        UpDownVault.SignedReading memory p = _reading(c.rec.matchId, seq, prevClock, c.rec.entryLead);
        UpDownVault.SignedReading memory q = _reading(c.rec.matchId, seq + 1, settleClock, lead);
        seq += 2;
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vault.settleCalls(items, _two(p, q));
    }

    // ------------------------------------------------------------------------------------- batch outcomes

    /// Finds the CallRejected or CallSkipped event for `id` among recorded logs.
    function _eventFor(Vm.Log[] memory logs, bytes32 topic0, bytes32 id)
        internal
        pure
        returns (bool found, uint256 index, UpDownVault.Refusal why)
    {
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].topics.length > 1 && logs[k].topics[0] == topic0 && logs[k].topics[1] == id) {
                if (topic0 == UpDownVault.CallRejected.selector) {
                    (index, why) = abi.decode(logs[k].data, (uint256, UpDownVault.Refusal));
                } else {
                    (index, why) = abi.decode(logs[k].data, (uint256, UpDownVault.Refusal));
                }
                return (true, index, why);
            }
        }
    }

    /// Opens a batch and asserts item `index` (call `id`) was rejected for `why`, leaving its account and the
    /// house as they were.
    function _openExpectRejected(
        UpDownVault.OpenItem[] memory items,
        UpDownVault.SignedReading[] memory rs,
        uint256 index,
        UpDownVault.Refusal why
    ) internal {
        bytes32 id = vault.hashIntent(items[index].intent);
        address acct = items[index].intent.account;
        bytes32 storedBefore = vault.calls(id);
        uint256 floatBefore = _float(acct);
        uint256 openBefore = _openStake(acct);
        vm.recordLogs();
        vm.prank(operator);
        vault.openCalls(items, rs);
        (bool found, uint256 gotIndex, UpDownVault.Refusal gotWhy) =
            _eventFor(vm.getRecordedLogs(), UpDownVault.CallRejected.selector, id);
        assertTrue(found, "no CallRejected");
        assertEq(gotIndex, index, "index");
        assertEq(uint8(gotWhy), uint8(why), "reason");
        if (items.length == 1) {
            assertEq(vault.calls(id), storedBefore, "call stored");
            assertEq(_float(acct), floatBefore, "float moved");
            assertEq(_openStake(acct), openBefore, "stake moved");
        }
    }

    // ------------------------------------------------------------------------------------------ views

    function _float(address a) internal view returns (uint256 f) {
        (f,,,,,,) = vault.accounts(a);
    }

    function _openStake(address a) internal view returns (uint256 s) {
        (, uint48 u,,,,,) = vault.accounts(a);
        s = uint256(u) * CENT;
    }

    function _houseFree() internal view returns (uint256 f) {
        (f,) = vault.house();
    }

    function _houseLocked() internal view returns (uint256 l) {
        (, l) = vault.house();
    }

    function _fees() internal view returns (uint256 f) {
        (f,,,) = vault.state();
    }

    function _dayLoss(address a) internal view returns (int64 d) {
        (,,,,,, d) = _accountTail(a);
    }

    function _accountTail(address a) internal view returns (uint96, uint48, uint48, uint32, uint32, uint32, int64) {
        (uint96 f, uint48 s, uint48 l, uint32 e, uint32 lo, uint32 d, int64 dl) = vault.accounts(a);
        return (f, s, l, e, lo, d, dl);
    }
}
