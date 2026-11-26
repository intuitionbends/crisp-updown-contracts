// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UpDownVault} from "../../src/UpDownVault.sol";
import {MockUSDT, MockSmartAccount} from "../utils/Mocks.sol";

/// @notice Drives the vault through random sequences of every state-changing function, as the operator, the
///         players, the admin, the guardian and outsiders would. It keeps a shadow ledger worked out from the
///         engine's rules independently of the contract, and counts any attack that succeeds.
contract Handler is Test {
    uint256 internal constant CENT = 1e16;
    uint256 internal constant USDT = 1e18;
    uint256 internal constant N = 4;
    uint256 public constant DAILY_LIMIT = 1_500 * USDT;

    UpDownVault public vault;
    MockUSDT public usdt;
    address public admin;
    address public operator;
    address public guardian;
    address public feeRecipient;
    address public houseSink = makeAddr("houseSink");
    uint256 internal oracleKey;

    address[N] public actors;
    uint256[N] internal deviceKeys;
    address[N] internal devices;

    // Shadow ledger, in wei.
    mapping(address => uint256) public shadowFloat;
    mapping(address => uint256) public shadowOpen;
    mapping(address => uint256) public shadowLiability;
    mapping(address => uint256) public ghostOut; // sent to the actor by recall or exit
    uint256 public ghostHouseOut;
    uint256 public ghostFeesOut;
    uint256 public ghostDonated;
    uint256 public shadowFees;
    uint256 public attacksSucceeded;

    struct Open {
        bytes32 id;
        UpDownVault.CallRecord rec;
    }

    Open[] internal opens;
    // The last call opened and the last call settled, kept for replay attempts.
    UpDownVault.OpenItem internal lastItem;
    UpDownVault.SignedReading internal lastEntry;
    bool internal haveLast;
    Open internal lastSettled;
    bool internal haveSettled;
    mapping(bytes32 => uint64) internal nextSeq;
    uint256 internal nonce;
    mapping(string => uint256) public calls;

    constructor(
        UpDownVault vault_,
        MockUSDT usdt_,
        address admin_,
        address operator_,
        address guardian_,
        address feeRecipient_,
        uint256 oracleKey_
    ) {
        vault = vault_;
        usdt = usdt_;
        admin = admin_;
        operator = operator_;
        guardian = guardian_;
        feeRecipient = feeRecipient_;
        oracleKey = oracleKey_;

        for (uint256 i; i < N; ++i) {
            (address owner, uint256 ownerKey) = makeAddrAndKey(string.concat("player", vm.toString(i)));
            // Half the players are smart accounts, half ordinary wallets.
            address acct = i % 2 == 0 ? owner : address(new MockSmartAccount(owner));
            actors[i] = acct;
            (devices[i], deviceKeys[i]) = makeAddrAndKey(string.concat("device", vm.toString(i)));
            usdt.mint(acct, 1_000_000 * USDT);
            vm.prank(acct);
            usdt.approve(address(vault), type(uint256).max);

            UpDownVault.Permission memory p = UpDownVault.Permission({
                account: acct,
                deviceKey: devices[i],
                floatCap: 100_000 * USDT,
                perCallMax: 1_000 * USDT,
                dailyLossLimit: DAILY_LIMIT,
                validUntil: type(uint32).max,
                nonce: 1
            });
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, vault.hashPermission(p));
            vm.prank(operator);
            vault.authorise(p, abi.encodePacked(r, s, v));
        }
        nextSeq[keccak256("m0")] = 1;
        nextSeq[keccak256("m1")] = 1;
    }

    // ----------------------------------------------------------------------------------------- helpers

    function actorCount() external pure returns (uint256) {
        return N;
    }

    function openCount() external view returns (uint256) {
        return opens.length;
    }

    function openLiabilityTotal() external view returns (uint256 total) {
        for (uint256 i; i < opens.length; ++i) {
            (,, uint256 liab) = _amounts(opens[i].rec);
            total += liab * CENT;
        }
    }

    function _paused() internal view returns (bool p) {
        (,,, p) = vault.state();
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _reading(bytes32 m, uint64 s, int32 clock, int64 lead)
        internal
        view
        returns (UpDownVault.SignedReading memory)
    {
        UpDownVault.Reading memory r = UpDownVault.Reading({matchId: m, seq: s, clock: clock, lead: lead});
        return UpDownVault.SignedReading({reading: r, signature: _sign(oracleKey, vault.hashReading(r))});
    }

    /// The engine's rule, worked out here and not by the contract: fee down to the cent, payout on the rest.
    function _amounts(UpDownVault.CallRecord memory c) internal pure returns (uint256 fee, uint256 pay, uint256 liab) {
        fee = uint256(c.stakeUnits) * c.feeBps / 10_000;
        uint256 net = c.stakeUnits - fee;
        pay = net * c.priceX100 / 100;
        liab = pay - net;
    }

    function _remove(uint256 i) internal {
        opens[i] = opens[opens.length - 1];
        opens.pop();
    }

    function _warp(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    // ------------------------------------------------------------------------------------------ actions

    function fill(uint256 who, uint256 amount) external {
        if (_paused()) return;
        uint256 i = who % N;
        address a = actors[i];
        uint256 held = vault.floatOf(a) + shadowOpen[a];
        uint256 cap = 100_000 * USDT;
        if (held >= cap) return;
        amount = _bound(amount, 1, cap - held);
        vm.prank(operator);
        vault.fill(a, devices[i], amount);
        shadowFloat[a] += amount;
        calls["fill"]++;
    }

    function open(uint256 who, bool up, uint256 stakeSeed, uint256 priceSeed, uint256 feeSeed, int64 lead, bool m1)
        external
    {
        if (_paused()) return;
        uint256 i = who % N;
        address a = actors[i];
        // Spread evenly up to the per-call maximum (1,000 USDT); the fuzzer alone favours tiny stakes.
        uint256 stakeCents = stakeSeed % 100_000 + 1;
        if (shadowFloat[a] < stakeCents * CENT) {
            // The operator tops the float up first, as the engine does when it runs low.
            uint256 top = stakeCents * CENT - shadowFloat[a];
            if (shadowFloat[a] + shadowOpen[a] + top > 100_000 * USDT) return;
            vm.prank(operator);
            vault.fill(a, devices[i], top);
            shadowFloat[a] += top;
        }
        (,, uint16 ceiling,) = vault.state();
        UpDownVault.CallRecord memory rec = UpDownVault.CallRecord({
            account: a,
            matchId: m1 ? keccak256("m1") : keccak256("m0"),
            side: up ? 0 : 1,
            stakeUnits: uint64(stakeCents),
            priceX100: uint16(_bound(priceSeed, 101, 500)),
            feeBps: uint16(_bound(feeSeed, 0, ceiling)),
            entryLead: int64(_bound(lead, -50_000, 50_000)),
            entrySeq: 0,
            settleAt: 630,
            epoch: 0
        });
        (,,, rec.epoch,,,) = vault.accounts(a);
        rec.entrySeq = nextSeq[rec.matchId]++;
        _openCall(i, rec);
    }

    function _openCall(uint256 i, UpDownVault.CallRecord memory rec) internal {
        (,, uint256 liab) = _amounts(rec);
        (uint256 free,) = vault.house();
        if (free < liab * CENT) return;

        UpDownVault.CallIntent memory it = UpDownVault.CallIntent({
            account: rec.account,
            matchId: rec.matchId,
            side: rec.side,
            stake: uint256(rec.stakeUnits) * CENT,
            length: 30,
            minPriceX100: 101,
            maxFeeBps: 500,
            readingSeen: rec.entrySeq,
            nonce: ++nonce,
            deadline: uint64(vm.getBlockTimestamp() + 60)
        });
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](1);
        items[0] = UpDownVault.OpenItem({
            intent: it,
            signature: _sign(deviceKeys[i], vault.hashIntent(it)),
            priceX100: rec.priceX100,
            feeBps: rec.feeBps,
            entry: 0
        });
        UpDownVault.SignedReading[] memory rs = new UpDownVault.SignedReading[](1);
        rs[0] = _reading(rec.matchId, rec.entrySeq, 600, rec.entryLead);
        vm.prank(operator);
        vault.openCalls(items, rs);
        bytes32 id = vault.hashIntent(it);
        if (vault.calls(id) == bytes32(0)) {
            // Rejected (the daily loss limit, here): nothing of it may have been taken.
            calls["openRejected"]++;
            return;
        }
        lastItem = items[0];
        lastEntry = rs[0];
        haveLast = true;

        address a = rec.account;
        opens.push(Open({id: id, rec: rec}));
        shadowFloat[a] -= uint256(rec.stakeUnits) * CENT;
        shadowOpen[a] += uint256(rec.stakeUnits) * CENT;
        shadowLiability[a] += liab * CENT;
        calls["open"]++;
    }

    function settle(uint256 pick, int64 lead, uint256 overshoot) external {
        if (opens.length == 0) return;
        uint256 k = pick % opens.length;
        Open memory o = opens[k];
        lead = int64(_bound(lead, -50_000, 50_000));
        int32 settleClock = int32(int64(o.rec.settleAt)) + int32(int256(_bound(overshoot, 0, 20)));
        uint64 s = nextSeq[o.rec.matchId];
        nextSeq[o.rec.matchId] = s + 2;
        UpDownVault.SignedReading[] memory rs = new UpDownVault.SignedReading[](2);
        rs[0] = _reading(o.rec.matchId, s, int32(int64(o.rec.settleAt)) - 1, o.rec.entryLead);
        rs[1] = _reading(o.rec.matchId, s + 1, settleClock, lead);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: o.id, call: o.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vault.settleCalls(items, rs);

        (uint256 fee, uint256 pay, uint256 liab) = _amounts(o.rec);
        address a = o.rec.account;
        shadowOpen[a] -= uint256(o.rec.stakeUnits) * CENT;
        shadowLiability[a] -= liab * CENT;
        bool tied = lead == o.rec.entryLead;
        bool won = !tied && ((lead > o.rec.entryLead) == (o.rec.side == 0));
        if (won) {
            shadowFloat[a] += pay * CENT;
            shadowFees += fee * CENT;
        } else if (tied) {
            shadowFloat[a] += uint256(o.rec.stakeUnits) * CENT;
        } else {
            shadowFees += fee * CENT;
        }
        lastSettled = o;
        haveSettled = true;
        _remove(k);
        calls["settle"]++;
    }

    // ------------------------------------------------------------------------------------ replays and griefing

    /// The operator resends a batch that already landed. Nothing may move.
    function replayOpen() external {
        if (!haveLast || _paused()) return;
        address a = lastItem.intent.account;
        uint256 floatBefore = vault.floatOf(a);
        (uint256 freeBefore,) = vault.house();
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](1);
        items[0] = lastItem;
        UpDownVault.SignedReading[] memory rs = new UpDownVault.SignedReading[](1);
        rs[0] = lastEntry;
        vm.prank(operator);
        vault.openCalls(items, rs);
        (uint256 freeAfter,) = vault.house();
        if (vault.floatOf(a) != floatBefore || freeAfter != freeBefore) attacksSucceeded++;
        calls["replayOpen"]++;
    }

    /// The operator resends a settle that already landed, with a different result. Nothing may move.
    function replaySettle(int64 lead) external {
        if (!haveSettled) return;
        Open memory o = lastSettled;
        address a = o.rec.account;
        uint256 floatBefore = vault.floatOf(a);
        (uint128 feesBefore,,,) = vault.state();
        uint64 s = nextSeq[o.rec.matchId];
        nextSeq[o.rec.matchId] = s + 2;
        UpDownVault.SignedReading[] memory rs = new UpDownVault.SignedReading[](2);
        rs[0] = _reading(o.rec.matchId, s, int32(int64(o.rec.settleAt)) - 1, 0);
        rs[1] = _reading(o.rec.matchId, s + 1, int32(int64(o.rec.settleAt)), int64(_bound(lead, -50_000, 50_000)));
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: o.id, call: o.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vault.settleCalls(items, rs); // must not revert: skipped
        (uint128 feesAfter,,,) = vault.state();
        if (vault.floatOf(a) != floatBefore || feesAfter != feesBefore) attacksSucceeded++;
        calls["replaySettle"]++;
    }

    /// A player empties their float just before a batch with someone else's call lands. The other call must
    /// still open, and the griefer's must be rejected without taking anything.
    function griefBatch(uint256 griefer, uint256 stakeSeed) external {
        if (_paused()) return;
        uint256 gi = griefer % N;
        uint256 vi = (gi + 1) % N;
        address g = actors[gi];
        address v = actors[vi];
        uint256 stakeCents = _bound(stakeSeed, 1, 1_000);
        // The victim needs float for the call, and room under the cap and the daily limit.
        if (shadowFloat[v] < stakeCents * CENT) return;
        (, uint48 vOpen,,,, uint32 vDay, int64 vLoss) = vault.accounts(v);
        int256 lossToday = vDay == vault.today() ? int256(vLoss) : int256(0);
        if (lossToday + int256(uint256(vOpen) + stakeCents) > int256(DAILY_LIMIT / CENT)) return;
        (uint256 free,) = vault.house();
        if (free < stakeCents * CENT * 4) return;

        bytes32 m = keccak256("m0");
        uint64 s = nextSeq[m]++;
        UpDownVault.OpenItem[] memory items = new UpDownVault.OpenItem[](2);
        items[0] = _griefItem(gi, g, m, s, stakeCents + shadowFloat[g] / CENT + 1);
        items[1] = _griefItem(vi, v, m, s, stakeCents);
        UpDownVault.SignedReading[] memory rs = new UpDownVault.SignedReading[](1);
        rs[0] = _reading(m, s, 600, 0);

        if (shadowFloat[g] != 0) {
            vm.prank(g);
            vault.recall(g, type(uint256).max);
            ghostOut[g] += shadowFloat[g];
            shadowFloat[g] = 0;
        }
        vm.prank(operator);
        vault.openCalls(items, rs);
        if (vault.calls(vault.hashIntent(items[0].intent)) != bytes32(0)) attacksSucceeded++;
        bytes32 vid = vault.hashIntent(items[1].intent);
        if (vault.calls(vid) == bytes32(0)) {
            attacksSucceeded++; // the griefer stopped someone else's call
            return;
        }
        (,,, uint32 epoch,,,) = vault.accounts(v);
        UpDownVault.CallRecord memory rec = UpDownVault.CallRecord({
            account: v,
            matchId: m,
            side: 0,
            stakeUnits: uint64(stakeCents),
            priceX100: 190,
            feeBps: 0,
            entryLead: 0,
            entrySeq: s,
            settleAt: 630,
            epoch: epoch
        });
        (,, uint256 liab) = _amounts(rec);
        opens.push(Open({id: vid, rec: rec}));
        shadowFloat[v] -= stakeCents * CENT;
        shadowOpen[v] += stakeCents * CENT;
        shadowLiability[v] += liab * CENT;
        calls["griefBatch"]++;
    }

    function _griefItem(uint256 i, address a, bytes32 m, uint64 s, uint256 stakeCents)
        internal
        returns (UpDownVault.OpenItem memory)
    {
        if (stakeCents > 100_000) stakeCents = 100_000;
        UpDownVault.CallIntent memory it = UpDownVault.CallIntent({
            account: a,
            matchId: m,
            side: 0,
            stake: stakeCents * CENT,
            length: 30,
            minPriceX100: 101,
            maxFeeBps: 500,
            readingSeen: s,
            nonce: ++nonce,
            deadline: uint64(vm.getBlockTimestamp() + 60)
        });
        return UpDownVault.OpenItem({
            intent: it,
            signature: _sign(deviceKeys[i], vault.hashIntent(it)),
            priceX100: 190,
            feeBps: 0,
            entry: 0
        });
    }

    function voidCall(uint256 pick, uint256 reasonSeed) external {
        if (opens.length == 0) return;
        uint256 k = pick % opens.length;
        Open memory o = opens[k];
        UpDownVault.VoidItem[] memory items = new UpDownVault.VoidItem[](1);
        items[0] = UpDownVault.VoidItem({id: o.id, call: o.rec, reason: uint8(_bound(reasonSeed, 1, 8))});
        vm.prank(operator);
        vault.voidCalls(items);
        (,, uint256 liab) = _amounts(o.rec);
        address a = o.rec.account;
        shadowOpen[a] -= uint256(o.rec.stakeUnits) * CENT;
        shadowLiability[a] -= liab * CENT;
        shadowFloat[a] += uint256(o.rec.stakeUnits) * CENT;
        _remove(k);
        calls["void"]++;
    }

    function recall(uint256 who, uint256 amount, bool byOperator) external {
        address a = actors[who % N];
        if (shadowFloat[a] == 0) return;
        amount = _bound(amount, 1, shadowFloat[a]);
        vm.prank(byOperator ? operator : a);
        vault.recall(a, amount);
        shadowFloat[a] -= amount;
        ghostOut[a] += amount;
        calls["recall"]++;
    }

    function exit(uint256 who) external {
        address a = actors[who % N];
        uint256 amount = shadowFloat[a] + shadowOpen[a];
        if (amount == 0) return;
        _warp(vault.silenceSeconds());
        vm.prank(a);
        vault.exit();
        ghostOut[a] += amount;
        shadowFloat[a] = 0;
        shadowOpen[a] = 0;
        shadowLiability[a] = 0;
        for (uint256 k = opens.length; k > 0; --k) {
            if (opens[k - 1].rec.account == a) _remove(k - 1);
        }
        calls["exit"]++;
    }

    function fundHouse(uint256 amount) external {
        amount = _bound(amount, 1, 10_000 * USDT);
        usdt.mint(admin, amount);
        vm.prank(admin);
        vault.fundHouse(amount);
        calls["fundHouse"]++;
    }

    function withdrawHouse(uint256 amount) external {
        (uint256 free,) = vault.house();
        // Keep 20,000 USDT so the house can still take large calls; otherwise only tiny ones would open.
        if (free <= 20_000 * USDT) return;
        amount = _bound(amount, 1, free - 20_000 * USDT);
        vm.prank(admin);
        vault.withdrawHouse(houseSink, amount);
        ghostHouseOut += amount;
        calls["withdrawHouse"]++;
    }

    function withdrawFees(address anyone) external {
        uint256 f = shadowFees;
        vm.prank(anyone);
        vault.withdrawFees();
        ghostFeesOut += f;
        shadowFees = 0;
        calls["withdrawFees"]++;
    }

    function setFeeBps(uint256 bps) external {
        uint16 v = uint16(_bound(bps, 0, vault.feeLimitBps()));
        vm.prank(admin);
        vault.setFeeBps(v);
        calls["setFeeBps"]++;
    }

    function pauseOrUnpause(uint256 seed) external {
        bool p = seed % 4 == 0; // pause now and then, unpause more often
        vm.prank(p ? guardian : admin);
        if (p) vault.pause();
        else vault.unpause();
        calls["pause"]++;
    }

    function warp(uint256 secs) external {
        _warp(_bound(secs, 1, 3 days));
        calls["warp"]++;
    }

    /// Someone sends the token straight to the vault: it belongs to nobody and must not break accounting.
    function donate(uint256 amount) external {
        amount = _bound(amount, 1, 1_000 * USDT);
        usdt.mint(address(this), amount);
        usdt.transfer(address(vault), amount);
        ghostDonated += amount;
        calls["donate"]++;
    }

    // ------------------------------------------------------------------------------------------ attacks

    /// Anyone but the owner or the operator tries to move a player's float. Must always fail.
    function attackRecall(uint256 attackerSeed, uint256 victim, uint256 amount) external {
        address v = actors[victim % N];
        address[4] memory who = [admin, guardian, feeRecipient, actors[(victim % N + 1) % N]];
        address attacker = who[attackerSeed % 4];
        vm.prank(attacker);
        try vault.recall(v, _bound(amount, 0, shadowFloat[v])) {
            attacksSucceeded++;
        } catch {}
        calls["attackRecall"]++;
    }

    /// The admin tries to take more than the free house pool (locked money, floats or fees). Must fail.
    function attackWithdrawHouse(uint256 extra) external {
        (uint256 free,) = vault.house();
        vm.prank(admin);
        try vault.withdrawHouse(admin, free + _bound(extra, 1, 1_000_000 * USDT)) {
            attacksSucceeded++;
        } catch {}
        calls["attackWithdrawHouse"]++;
    }

    /// The operator settles an open call with its record altered in the house's favour. Must fail.
    function attackForgedSettle(uint256 pick, uint256 field) external {
        if (opens.length == 0) return;
        Open memory o = opens[pick % opens.length];
        UpDownVault.CallRecord memory r = o.rec;
        uint256 f = field % 4;
        if (f == 0) r.priceX100 = r.priceX100 == 101 ? 102 : 101;
        else if (f == 1) r.side = 1 - r.side;
        else if (f == 2) r.entryLead = r.entryLead + 1;
        else r.account = admin;
        uint64 s = nextSeq[r.matchId];
        nextSeq[r.matchId] = s + 2;
        UpDownVault.SignedReading[] memory rs = new UpDownVault.SignedReading[](2);
        rs[0] = _reading(r.matchId, s, int32(int64(r.settleAt)) - 1, 0);
        rs[1] = _reading(r.matchId, s + 1, int32(int64(r.settleAt)), 1);
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: o.id, call: r, prev: 0, settle: 1});
        vm.prank(operator);
        try vault.settleCalls(items, rs) {
            attacksSucceeded++;
        } catch {}
        calls["attackForgedSettle"]++;
    }
}
