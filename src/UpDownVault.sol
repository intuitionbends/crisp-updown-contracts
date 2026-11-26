// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @title UpDownVault
/// @notice Custody and settlement for Crisp's Up/Down game on BSC. It holds three separate balances in one token
///         (BSC USDT): each user's float, the house pool (free and locked), and accrued fees. The operator posts
///         opens and settles in batches; the contract decides every payout from readings signed by the oracle and
///         call intents signed by the user's device keys. There is no upgrade path.
/// @dev    Amounts in signed messages and in storage are token base units (wei), except where a name ends in
///         `Units`: a call's stake, fee, payout and liability are counted in whole `unit`s (one cent of 18-decimal
///         USDT by default), which is where the engine's "rounded down to a whole coin" lands on-chain.
contract UpDownVault {
    // ------------------------------------------------------------------------------------------------------ types

    /// @notice A standing permission, signed by the account: lets `deviceKey` sign call intents for `account`.
    /// @dev    `floatCap`, `perCallMax` and `dailyLossLimit` are token base units.
    struct Permission {
        address account;
        address deviceKey;
        uint256 floatCap;
        uint256 perCallMax;
        uint256 dailyLossLimit;
        uint64 validUntil;
        uint64 nonce;
    }

    /// @notice A call intent, signed by a device key. `side` is 0 for Up, 1 for Down. `stake` is token base units
    ///         and must be a whole number of `unit`s. `length` is seconds of the match clock. `readingSeen` is the
    ///         sequence number of the reading the player was looking at. `maxFeeBps` is the most the player agreed
    ///         to be charged. The EIP-712 digest of the intent is the call's id, so the vault takes it once.
    struct CallIntent {
        address account;
        bytes32 matchId;
        uint8 side;
        uint256 stake;
        uint32 length;
        uint16 minPriceX100;
        uint16 maxFeeBps;
        uint64 readingSeen;
        uint256 nonce;
        uint64 deadline;
    }

    /// @notice A reading of the line, signed by the oracle. `lead` is team A's measure less team B's.
    struct Reading {
        bytes32 matchId;
        uint64 seq;
        int32 clock;
        int64 lead;
    }

    struct SignedReading {
        Reading reading;
        bytes signature;
    }

    /// @notice One call in an `openCalls` batch. `priceX100` and `feeBps` are the operator's for this call;
    ///         `entry` indexes the batch's readings.
    struct OpenItem {
        CallIntent intent;
        bytes signature;
        uint16 priceX100;
        uint16 feeBps;
        uint256 entry;
    }

    /// @notice What the vault keeps of an open call. Only its hash is stored; settle and void hand it back.
    struct CallRecord {
        address account;
        bytes32 matchId;
        uint8 side;
        uint64 stakeUnits;
        uint16 priceX100;
        uint16 feeBps;
        int64 entryLead;
        uint64 entrySeq;
        int64 settleAt;
        uint32 epoch;
    }

    /// @notice One call in a `settleCalls` batch: `prev` and `settle` index the batch's readings and must be
    ///         consecutive readings of the call's match that straddle its settle time.
    struct SettleItem {
        bytes32 id;
        CallRecord call;
        uint256 prev;
        uint256 settle;
    }

    struct VoidItem {
        bytes32 id;
        CallRecord call;
        uint8 reason;
    }

    enum Outcome {
        Won,
        Lost,
        Tied
    }

    /// @notice Why one item of a batch was refused. In `openCalls` the item is rejected (`CallRejected`) and the
    ///         rest of the batch opens. In `settleCalls` and `voidCalls` a call that is already final or belongs to
    ///         an exited epoch is skipped (`CallSkipped`); any other refusal reverts the batch with the item's index.
    ///         New values are only ever appended.
    enum Refusal {
        Expired,
        BadSide,
        BadStake,
        BadLength,
        NoPermission,
        OverPerCallMax,
        PriceBelowMin,
        PriceOutOfRange,
        FeeTooHigh,
        WrongMatch,
        EntryOutOfRange,
        Duplicate,
        FloatShort,
        DailyLossLimit,
        UnknownCall,
        StaleCall,
        NotConsecutive,
        NotFirstAtOrAfter,
        Overshoot,
        BadVoidReason,
        AlreadyFinal,
        HouseShort,
        BadReadingIndex
    }

    struct Config {
        address token;
        address admin;
        address operator;
        address oracle;
        address guardian;
        address feeRecipient;
        /// Smallest amount a call is counted in (token base units). Stakes are whole units; fee and payout round
        /// to it. Suggested: 1e16, one cent of 18-decimal USDT.
        uint256 unit;
        /// Fixed fee limit in basis points; `setFeeBps` can never exceed it. Suggested: 500 (5%).
        uint16 feeLimitBps;
        /// Fee rounding: false rounds the fee down to the unit (suggested), true rounds it up.
        bool feeRoundsUp;
        /// Seconds the operator must be silent before `exit` opens.
        uint32 silenceSeconds;
        /// Seconds added to block time before dividing into days, to place the daily loss limit's day boundary.
        /// 0 is midnight UTC; 28800 is midnight in Kuala Lumpur (UTC+8).
        uint32 dayOffsetSeconds;
        /// Highest price a call may carry, x100 (475 = 4.75x).
        uint16 maxPriceX100;
        /// Seconds past the settle time a settle reading may be before the call must be voided (`late_tick`).
        /// The engine's default is 20.
        uint32 maxOvershootSeconds;
        /// How many readings after the one the player saw a call may still open on.
        uint64 maxEntryLag;
        /// Seconds between the admin proposing a new operator, oracle or guardian key and the change being
        /// possible. Must be above 0. Recommended: 24 hours.
        uint32 keyChangeDelay;
    }

    /// @notice The keys the admin can replace, each only after `keyChangeDelay`.
    enum Role {
        Operator,
        Oracle,
        Guardian
    }

    // -------------------------------------------------------------------------------------------- constants

    /// @notice Void reason codes. They mirror the engine's `void_reason` values.
    uint8 public constant VOID_MATCH_GONE = 1;
    uint8 public constant VOID_CLOCK_STOPPED = 2;
    uint8 public constant VOID_CLOCK_REWOUND = 3;
    uint8 public constant VOID_LATE_TICK = 4;
    uint8 public constant VOID_CANCELLED = 5;
    uint8 public constant VOID_NOT_RACING = 6;
    uint8 public constant VOID_LAPPED = 7;
    uint8 public constant VOID_FEED_STALE = 8;
    uint8 public constant MAX_VOID_REASON = 8;

    /// @notice A price must pay more than the stake back.
    uint16 public constant MIN_PRICE_X100 = 101;

    uint16 internal constant BPS = 10_000;
    bytes32 internal constant DONE = bytes32(uint256(1));
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    uint256 internal constant HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    bytes32 public constant PERMISSION_TYPEHASH = keccak256(
        "Permission(address account,address deviceKey,uint256 floatCap,uint256 perCallMax,uint256 dailyLossLimit,uint64 validUntil,uint64 nonce)"
    );
    bytes32 public constant CALL_INTENT_TYPEHASH = keccak256(
        "CallIntent(address account,bytes32 matchId,uint8 side,uint256 stake,uint32 length,uint16 minPriceX100,uint16 maxFeeBps,uint64 readingSeen,uint256 nonce,uint64 deadline)"
    );
    bytes32 public constant READING_TYPEHASH = keccak256("Reading(bytes32 matchId,uint64 seq,int32 clock,int64 lead)");
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("UpDownVault");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    // ------------------------------------------------------------------------------------------- immutables

    IERC20 public immutable token;
    uint256 public immutable unit;
    uint16 public immutable feeLimitBps;
    bool public immutable feeRoundsUp;
    uint32 public immutable silenceSeconds;
    uint32 public immutable dayOffsetSeconds;
    uint16 public immutable maxPriceX100;
    uint32 public immutable maxOvershootSeconds;
    uint64 public immutable maxEntryLag;
    uint32 public immutable keyChangeDelay;

    uint256 internal immutable _chainId;
    bytes32 internal immutable _domainSeparator;

    // --------------------------------------------------------------------------------------------- storage

    struct StoredPermission {
        uint96 floatCap; // wei
        uint32 validUntil; // 0 = none
        uint64 perCallMaxUnits;
        uint64 dailyLossUnits;
    }

    /// @dev The first five fields share one slot, so an open writes one slot and only reads the second.
    struct Account {
        uint96 float; // wei, free to stake or recall
        uint48 openStakeUnits; // whole stakes (fee included) of open calls
        uint48 openLiabilityUnits; // house money locked against this account's open calls
        uint32 epoch; // bumped by exit; calls from an older epoch are gone
        uint32 lastOpenAt;
        uint32 day; // the day `dayLossUnits` counts
        int64 dayLossUnits; // net: stakes lost less profit on wins, settled that day
    }

    struct House {
        uint128 free;
        uint128 locked;
    }

    struct State {
        uint128 fees;
        uint40 lastOperatorAt;
        uint16 feeBps;
        bool paused;
    }

    /// @notice A key change the admin has proposed: the new key and the earliest time it can take effect.
    struct PendingKey {
        address key;
        uint64 eta;
    }

    address public operator;
    address public oracle;
    address public guardian;
    mapping(Role role => PendingKey) public pendingKeys;

    address public admin;
    address public pendingAdmin;
    address public feeRecipient;
    House public house;
    State public state;

    mapping(address account => Account) public accounts;
    mapping(address account => mapping(address deviceKey => StoredPermission)) public permissions;
    mapping(address account => mapping(address deviceKey => uint64)) public permissionNonce;
    /// @notice Call id (intent digest) => hash of its record while open, `DONE` once settled or voided.
    mapping(bytes32 id => bytes32) public calls;

    // ---------------------------------------------------------------------------------------------- events

    event Authorised(address indexed account, address indexed deviceKey, Permission permission);
    event Revoked(address indexed account, address indexed deviceKey);
    event Filled(address indexed account, uint256 amount, uint256 float);
    event Recalled(address indexed account, address indexed by, uint256 amount);
    event Exited(address indexed account, uint256 amount, uint256 refundedStake, uint32 newEpoch);
    event CallOpened(bytes32 indexed id, address indexed account, address deviceKey, CallRecord call);
    event CallSettled(
        bytes32 indexed id, address indexed account, Outcome outcome, uint256 returned, uint256 fee, uint64 settleSeq
    );
    event CallVoided(bytes32 indexed id, address indexed account, uint8 reason, uint256 returned);
    /// @notice An item of an `openCalls` batch that did not open. Nothing of it was taken; the engine returns the
    ///         stake as `chain_rejected`.
    event CallRejected(bytes32 indexed id, address indexed account, uint256 index, Refusal why);
    /// @notice An item of a `settleCalls` or `voidCalls` batch that was already final (a retried batch) or belonged
    ///         to an epoch its account has exited. Nothing changed.
    event CallSkipped(bytes32 indexed id, uint256 index, Refusal why);
    event HouseFunded(address indexed from, uint256 amount);
    event HouseWithdrawn(address indexed to, uint256 amount);
    event FeeBpsSet(uint16 feeBps);
    event FeeRecipientSet(address indexed feeRecipient);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event AdminProposed(address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event KeyChangeProposed(Role indexed role, address current, address proposed, uint64 eta);
    event KeyChangeCancelled(Role indexed role, address proposed);
    event KeyChanged(Role indexed role, address previous, address current);

    // ---------------------------------------------------------------------------------------------- errors

    error NotOperator();
    error NotAdmin();
    error NotGuardian();
    error NotPendingAdmin();
    error NotAllowed();
    error IsPaused();
    error ZeroAddress();
    error BadConfig();
    error BadSignature();
    error PermissionExpired();
    error StaleNonce();
    error AmountTooLarge();
    error OverFloatCap();
    error InsufficientFloat();
    error InsufficientHouse();
    error FeeAboveLimit();
    error OperatorActive();
    error NothingToExit();
    error BadReading(uint256 index);
    error SettleRefused(uint256 index, Refusal why);
    error VoidRefused(uint256 index, Refusal why);
    error TransferFailed();
    error Overflow();
    error RolesMustDiffer();
    error NoPendingKey();
    error KeyChangeNotReady(uint64 eta);

    // ------------------------------------------------------------------------------------------- modifiers

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
        state.lastOperatorAt = uint40(block.timestamp);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (state.paused) revert IsPaused();
        _;
    }

    // ------------------------------------------------------------------------------------------ constructor

    constructor(Config memory c) {
        if (
            c.token == address(0) || c.admin == address(0) || c.operator == address(0) || c.oracle == address(0)
                || c.guardian == address(0) || c.feeRecipient == address(0)
        ) revert ZeroAddress();
        if (c.token.code.length == 0) revert BadConfig();
        if (c.unit == 0 || c.feeLimitBps > BPS || c.silenceSeconds == 0 || c.dayOffsetSeconds >= 1 days) {
            revert BadConfig();
        }
        if (c.maxPriceX100 < MIN_PRICE_X100 || c.keyChangeDelay == 0) revert BadConfig();
        if (c.operator == c.oracle) revert RolesMustDiffer();

        token = IERC20(c.token);
        admin = c.admin;
        operator = c.operator;
        oracle = c.oracle;
        guardian = c.guardian;
        feeRecipient = c.feeRecipient;
        unit = c.unit;
        feeLimitBps = c.feeLimitBps;
        feeRoundsUp = c.feeRoundsUp;
        silenceSeconds = c.silenceSeconds;
        dayOffsetSeconds = c.dayOffsetSeconds;
        maxPriceX100 = c.maxPriceX100;
        maxOvershootSeconds = c.maxOvershootSeconds;
        maxEntryLag = c.maxEntryLag;
        keyChangeDelay = c.keyChangeDelay;

        _chainId = block.chainid;
        _domainSeparator = _buildDomainSeparator();
        state.lastOperatorAt = uint40(block.timestamp);
    }

    // ============================================================================================ operator

    /// @notice Records a standing permission signed by `p.account` (ERC-1271 for a smart account, ECDSA for a
    ///         plain wallet). A newer nonce for the same device key replaces the older permission.
    function authorise(Permission calldata p, bytes calldata signature) external onlyOperator {
        if (p.account == address(0) || p.deviceKey == address(0)) revert ZeroAddress();
        if (p.validUntil < block.timestamp) revert PermissionExpired();
        if (p.nonce <= permissionNonce[p.account][p.deviceKey]) revert StaleNonce();
        if (p.floatCap > type(uint96).max || p.validUntil > type(uint32).max) revert AmountTooLarge();
        uint256 perCall = p.perCallMax / unit;
        uint256 daily = p.dailyLossLimit / unit;
        if (perCall > type(uint64).max || daily > uint256(uint64(type(int64).max))) revert AmountTooLarge();

        bytes32 digest = _hashTypedData(keccak256(abi.encode(PERMISSION_TYPEHASH, p)));
        if (!_isValidAccountSignature(p.account, digest, signature)) revert BadSignature();

        permissionNonce[p.account][p.deviceKey] = p.nonce;
        permissions[p.account][p.deviceKey] = StoredPermission({
            floatCap: uint96(p.floatCap),
            validUntil: uint32(p.validUntil),
            perCallMaxUnits: uint64(perCall),
            dailyLossUnits: uint64(daily)
        });
        emit Authorised(p.account, p.deviceKey, p);
    }

    /// @notice Pulls `amount` of the token from `account`'s wallet into its float. The float plus the account's
    ///         open stakes may not pass the float cap of a live permission for `deviceKey`.
    function fill(address account, address deviceKey, uint256 amount) external onlyOperator whenNotPaused {
        StoredPermission memory p = permissions[account][deviceKey];
        if (p.validUntil < block.timestamp) revert PermissionExpired();
        Account storage a = accounts[account];
        uint256 held = uint256(a.float) + uint256(a.openStakeUnits) * unit + amount;
        if (held > p.floatCap) revert OverFloatCap();
        a.float = _u96(uint256(a.float) + amount);
        emit Filled(account, amount, a.float);
        _pull(account, amount);
    }

    /// @notice Opens a batch of calls. Every reading is checked against the oracle first (a bad one reverts the
    ///         batch). Each call's intent must be signed by a live device key of its account; a call that fails any
    ///         check is rejected on its own (`CallRejected`) and the rest open, so one player changing their own
    ///         state (a recall, a revoke) cannot stop everyone else's calls, and a retried batch does not reopen.
    function openCalls(OpenItem[] calldata items, SignedReading[] calldata readings)
        external
        onlyOperator
        whenNotPaused
    {
        _verifyReadings(readings);
        uint256 day = _today();
        uint16 ceiling = state.feeBps;
        House memory h = house;
        uint256 freeUnits = h.free / unit;
        uint256 lockUnits;
        for (uint256 i; i < items.length; ++i) {
            (bytes32 id, Refusal why, bool ok, uint256 liab) =
                _open(items[i], readings, day, ceiling, freeUnits - lockUnits);
            if (ok) {
                lockUnits += liab;
            } else {
                emit CallRejected(id, items[i].intent.account, i, why);
            }
        }
        if (lockUnits != 0) {
            uint256 lockWei = lockUnits * unit;
            house = House({free: uint128(h.free - lockWei), locked: _u128(h.locked + lockWei)});
        }
    }

    /// @notice Settles a batch of calls on the first oracle reading at or after each call's settle time.
    /// @dev    "First" is proven by the reading before it: `prev` and `settle` are readings of the same match
    ///         with consecutive sequence numbers, `prev.clock < settleAt <= settle.clock`, and `prev` is not before
    ///         the entry reading. The oracle signs one reading per sequence number (and anchors roots of them
    ///         off-chain), so no reading lies between the two.
    function settleCalls(SettleItem[] calldata items, SignedReading[] calldata readings) external onlyOperator {
        _verifyReadings(readings);
        uint256 day = _today();
        uint256 releaseUnits; // locked liability released
        uint256 houseGainUnits; // to the free pool
        uint256 feeUnits;
        for (uint256 i; i < items.length; ++i) {
            (bool done, uint256 rel, uint256 gain, uint256 fee) = _settle(i, items[i], readings, day);
            if (!done) continue;
            releaseUnits += rel;
            houseGainUnits += gain;
            feeUnits += fee;
        }
        House memory h = house;
        house = House({free: _u128(h.free + houseGainUnits * unit), locked: uint128(h.locked - releaseUnits * unit)});
        state.fees = _u128(state.fees + feeUnits * unit);
    }

    /// @notice Voids a batch of calls: each stake is returned whole, fee included, and the house's lock released.
    function voidCalls(VoidItem[] calldata items) external onlyOperator {
        uint256 releaseUnits;
        for (uint256 i; i < items.length; ++i) {
            VoidItem calldata v = items[i];
            if (v.reason == 0 || v.reason > MAX_VOID_REASON) revert VoidRefused(i, Refusal.BadVoidReason);
            (bool live, bool skip, Refusal why) = _checkLive(v.id, v.call);
            if (skip) {
                emit CallSkipped(v.id, i, why);
                continue;
            }
            if (!live) revert VoidRefused(i, why);
            (,, uint256 liab) = _amounts(v.call.stakeUnits, v.call.feeBps, v.call.priceX100);
            Account storage a = accounts[v.call.account];
            a.openStakeUnits = uint48(uint256(a.openStakeUnits) - v.call.stakeUnits);
            a.openLiabilityUnits = uint48(uint256(a.openLiabilityUnits) - liab);
            uint256 back = uint256(v.call.stakeUnits) * unit;
            a.float = _u96(uint256(a.float) + back);
            calls[v.id] = DONE;
            releaseUnits += liab;
            emit CallVoided(v.id, v.call.account, v.reason, back);
        }
        House memory h = house;
        uint256 rel = releaseUnits * unit;
        house = House({free: _u128(h.free + rel), locked: uint128(h.locked - rel)});
    }

    // ======================================================================================== operator or user

    /// @notice Sends `amount` of `account`'s free float (its float less open stakes) to `account` and nowhere
    ///         else. `type(uint256).max` sends all of it. Works while paused.
    function recall(address account, uint256 amount) external {
        if (msg.sender == operator) {
            state.lastOperatorAt = uint40(block.timestamp);
        } else if (msg.sender != account) {
            revert NotAllowed();
        }
        Account storage a = accounts[account];
        if (amount == type(uint256).max) amount = a.float;
        if (amount > a.float) revert InsufficientFloat();
        a.float = uint96(uint256(a.float) - amount);
        emit Recalled(account, msg.sender, amount);
        _send(account, amount);
    }

    // ================================================================================================= user

    /// @notice The user's way out. Opens once the operator has been silent for `silenceSeconds`, or once the
    ///         caller's newest open call has waited that long. Every open call is cancelled (stake returned,
    ///         fee included; the house's lock released) and the whole float goes to the caller.
    function exit() external {
        Account storage a = accounts[msg.sender];
        bool operatorSilent = block.timestamp >= uint256(state.lastOperatorAt) + silenceSeconds;
        bool callStuck = a.openStakeUnits != 0 && block.timestamp >= uint256(a.lastOpenAt) + silenceSeconds;
        if (!operatorSilent && !callStuck) revert OperatorActive();

        uint256 refund = uint256(a.openStakeUnits) * unit;
        uint256 release = uint256(a.openLiabilityUnits) * unit;
        uint256 amount = uint256(a.float) + refund;
        if (amount == 0) revert NothingToExit();

        a.float = 0;
        a.openStakeUnits = 0;
        a.openLiabilityUnits = 0;
        a.epoch += 1;
        if (release != 0) {
            House memory h = house;
            house = House({free: _u128(h.free + release), locked: uint128(h.locked - release)});
        }
        emit Exited(msg.sender, amount, refund, a.epoch);
        _send(msg.sender, amount);
    }

    /// @notice An account withdraws one of its own device keys. Calls already opened stand.
    function revoke(address deviceKey) external {
        delete permissions[msg.sender][deviceKey];
        emit Revoked(msg.sender, deviceKey);
    }

    // ================================================================================================ admin

    function fundHouse(uint256 amount) external onlyAdmin {
        house.free = _u128(uint256(house.free) + amount);
        emit HouseFunded(msg.sender, amount);
        _pull(msg.sender, amount);
    }

    /// @notice Withdraws unlocked house money only.
    function withdrawHouse(address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        if (amount > house.free) revert InsufficientHouse();
        house.free = uint128(uint256(house.free) - amount);
        emit HouseWithdrawn(to, amount);
        _send(to, amount);
    }

    /// @notice Sets the fee ceiling for calls opened from now on. Never above the fixed limit.
    function setFeeBps(uint16 bps) external onlyAdmin {
        if (bps > feeLimitBps) revert FeeAboveLimit();
        state.feeBps = bps;
        emit FeeBpsSet(bps);
    }

    function setFeeRecipient(address to) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        feeRecipient = to;
        emit FeeRecipientSet(to);
    }

    /// @notice Proposes a new admin; `address(0)` cancels a proposal. The role moves only on `acceptAdmin`.
    function transferAdmin(address to) external onlyAdmin {
        pendingAdmin = to;
        emit AdminProposed(to);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) revert NotPendingAdmin();
        emit AdminTransferred(admin, msg.sender);
        admin = msg.sender;
        pendingAdmin = address(0);
    }

    /// @notice Lifts a pause. Admin only, so a hot guardian key can stop the vault but not restart it.
    function unpause() external onlyAdmin {
        state.paused = false;
        emit Unpaused(msg.sender);
    }

    // ============================================================================================= anyone

    /// @notice Pays the whole fee balance to `feeRecipient`. Takes no destination; works while paused.
    function withdrawFees() external {
        uint256 amount = state.fees;
        if (amount == 0) return;
        state.fees = 0;
        address to = feeRecipient;
        emit FeesWithdrawn(to, amount);
        _send(to, amount);
    }

    // ======================================================================================== key rotation

    /// @notice Proposes a new key for one role. It can take effect `keyChangeDelay` seconds from now, so anyone
    ///         watching the vault sees it coming. A new proposal for the same role replaces the old one and
    ///         restarts the delay. The operator and the oracle must always be different keys.
    function proposeKey(Role role, address key) external onlyAdmin {
        if (key == address(0)) revert ZeroAddress();
        _checkRolesDiffer(role, key);
        uint64 eta = uint64(block.timestamp) + keyChangeDelay;
        pendingKeys[role] = PendingKey({key: key, eta: eta});
        emit KeyChangeProposed(role, _keyOf(role), key, eta);
    }

    /// @notice Withdraws a proposed key change before it takes effect.
    function cancelKey(Role role) external onlyAdmin {
        address proposed = pendingKeys[role].key;
        if (proposed == address(0)) revert NoPendingKey();
        delete pendingKeys[role];
        emit KeyChangeCancelled(role, proposed);
    }

    /// @notice Puts a proposed key in place once its delay has passed. Calls already open are unaffected; from
    ///         now on only the new key acts for the role (for the oracle: only its readings are accepted).
    function executeKey(Role role) external onlyAdmin {
        PendingKey memory p = pendingKeys[role];
        if (p.key == address(0)) revert NoPendingKey();
        if (block.timestamp < p.eta) revert KeyChangeNotReady(p.eta);
        _checkRolesDiffer(role, p.key);
        delete pendingKeys[role];
        address previous = _keyOf(role);
        if (role == Role.Operator) operator = p.key;
        else if (role == Role.Oracle) oracle = p.key;
        else guardian = p.key;
        emit KeyChanged(role, previous, p.key);
    }

    function _keyOf(Role role) internal view returns (address) {
        if (role == Role.Operator) return operator;
        if (role == Role.Oracle) return oracle;
        return guardian;
    }

    function _checkRolesDiffer(Role role, address key) internal view {
        if ((role == Role.Operator && key == oracle) || (role == Role.Oracle && key == operator)) {
            revert RolesMustDiffer();
        }
    }

    // ============================================================================================= guardian

    /// @notice Stops new fills and new calls. Settling, voids, recalls, exits and fee sweeps keep working.
    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        state.paused = true;
        emit Paused(msg.sender);
    }

    // ================================================================================================ rules

    /// @notice `rules::outcome` restated: Up wins if the lead rose, Down if it fell, unchanged is a tie.
    function outcome(uint8 side, int64 entryLead, int64 settleLead) public pure returns (Outcome) {
        if (settleLead == entryLead) return Outcome.Tied;
        return ((settleLead > entryLead) == (side == 0)) ? Outcome.Won : Outcome.Lost;
    }

    /// @notice `rules::payout` restated: stake times price, rounded down to a whole unit.
    function payout(uint256 stakeUnits, uint16 priceX100) public pure returns (uint256) {
        return stakeUnits * priceX100 / 100;
    }

    /// @notice `rules::returned` restated, on the stake after the fee.
    function returned(Outcome o, uint256 stakeUnits, uint16 priceX100) public pure returns (uint256) {
        if (o == Outcome.Won) return payout(stakeUnits, priceX100);
        if (o == Outcome.Tied) return stakeUnits;
        return 0;
    }

    /// @notice `rules::liability` restated: the most the house can lose on a stake.
    function liability(uint256 stakeUnits, uint16 priceX100) public pure returns (uint256) {
        return payout(stakeUnits, priceX100) - stakeUnits;
    }

    /// @notice The fee on a stake, in units, rounded as configured.
    function feeOf(uint256 stakeUnits, uint16 bps) public view returns (uint256) {
        uint256 n = stakeUnits * bps;
        return feeRoundsUp ? (n + BPS - 1) / BPS : n / BPS;
    }

    /// @notice A call's fee, its winning payout (on the stake less the fee) and the house liability it locks.
    function _amounts(uint256 stakeUnits, uint16 bps, uint16 priceX100)
        internal
        view
        returns (uint256 fee, uint256 pay, uint256 liab)
    {
        fee = feeOf(stakeUnits, bps);
        uint256 net = stakeUnits - fee;
        pay = payout(net, priceX100);
        liab = pay - net;
    }

    // ============================================================================================== views

    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _chainId ? _domainSeparator : _buildDomainSeparator();
    }

    function hashPermission(Permission calldata p) external view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(PERMISSION_TYPEHASH, p)));
    }

    /// @notice The call's id: the EIP-712 digest of its intent.
    function hashIntent(CallIntent calldata i) external view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(CALL_INTENT_TYPEHASH, i)));
    }

    function hashReading(Reading calldata r) external view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(READING_TYPEHASH, r)));
    }

    function hashCall(CallRecord calldata c) external pure returns (bytes32) {
        return keccak256(abi.encode(c));
    }

    function floatOf(address account) external view returns (uint256) {
        return accounts[account].float;
    }

    function today() external view returns (uint256) {
        return _today();
    }

    // =========================================================================================== internals

    /// @dev Checks one call and opens it, or returns why not without changing anything.
    function _open(
        OpenItem calldata o,
        SignedReading[] calldata readings,
        uint256 day,
        uint16 ceiling,
        uint256 houseFreeUnits
    ) internal returns (bytes32 id, Refusal why, bool ok, uint256 liabUnits) {
        CallIntent calldata it = o.intent;
        id = _hashTypedData(keccak256(abi.encode(CALL_INTENT_TYPEHASH, it)));
        if (it.deadline < block.timestamp) return (id, Refusal.Expired, false, 0);
        if (it.side > 1) return (id, Refusal.BadSide, false, 0);
        if (it.stake == 0 || it.stake % unit != 0) return (id, Refusal.BadStake, false, 0);
        if (it.length == 0) return (id, Refusal.BadLength, false, 0);
        if (calls[id] != bytes32(0)) return (id, Refusal.Duplicate, false, 0);

        address key = _recover(id, o.signature);
        StoredPermission memory p = permissions[it.account][key];
        if (key == address(0) || p.validUntil < block.timestamp) return (id, Refusal.NoPermission, false, 0);

        uint256 stakeUnits = it.stake / unit;
        if (stakeUnits > p.perCallMaxUnits) return (id, Refusal.OverPerCallMax, false, 0);
        if (o.priceX100 < it.minPriceX100) return (id, Refusal.PriceBelowMin, false, 0);
        if (o.priceX100 < MIN_PRICE_X100 || o.priceX100 > maxPriceX100) {
            return (id, Refusal.PriceOutOfRange, false, 0);
        }
        uint256 fee;
        (fee,, liabUnits) = _amounts(stakeUnits, o.feeBps, o.priceX100);
        // The fee actually charged, after rounding, must sit within both limits, not just its rate.
        uint256 maxBps = ceiling < it.maxFeeBps ? ceiling : it.maxFeeBps;
        if (o.feeBps > maxBps || fee * BPS > stakeUnits * maxBps) return (id, Refusal.FeeTooHigh, false, 0);

        if (o.entry >= readings.length) return (id, Refusal.BadReadingIndex, false, 0);
        Reading calldata r = readings[o.entry].reading;
        if (r.matchId != it.matchId) return (id, Refusal.WrongMatch, false, 0);
        if (r.seq < it.readingSeen || r.seq - it.readingSeen > maxEntryLag) {
            return (id, Refusal.EntryOutOfRange, false, 0);
        }

        Account storage a = accounts[it.account];
        if (a.float < it.stake) return (id, Refusal.FloatShort, false, 0);
        int256 lossSoFar = a.day == day ? int256(a.dayLossUnits) : int256(0);
        if (lossSoFar + int256(uint256(a.openStakeUnits) + stakeUnits) > int256(uint256(p.dailyLossUnits))) {
            return (id, Refusal.DailyLossLimit, false, 0);
        }
        if (liabUnits > houseFreeUnits) return (id, Refusal.HouseShort, false, 0);

        ok = true;
        a.float = uint96(uint256(a.float) - it.stake);
        a.openStakeUnits = _u48(uint256(a.openStakeUnits) + stakeUnits);
        a.openLiabilityUnits = _u48(uint256(a.openLiabilityUnits) + liabUnits);
        a.lastOpenAt = uint32(block.timestamp);

        CallRecord memory rec = CallRecord({
            account: it.account,
            matchId: it.matchId,
            side: it.side,
            stakeUnits: uint64(stakeUnits),
            priceX100: o.priceX100,
            feeBps: o.feeBps,
            entryLead: r.lead,
            entrySeq: r.seq,
            settleAt: int64(r.clock) + int64(uint64(it.length)),
            epoch: a.epoch
        });
        calls[id] = keccak256(abi.encode(rec));
        emit CallOpened(id, it.account, key, rec);
    }

    function _settle(uint256 i, SettleItem calldata s, SignedReading[] calldata readings, uint256 day)
        internal
        returns (bool done, uint256 releaseUnits, uint256 houseGainUnits, uint256 feeUnits)
    {
        CallRecord calldata c = s.call;
        (bool live, bool skip, Refusal why) = _checkLive(s.id, c);
        if (skip) {
            emit CallSkipped(s.id, i, why);
            return (false, 0, 0, 0);
        }
        if (!live) revert SettleRefused(i, why);
        if (s.prev >= readings.length || s.settle >= readings.length) {
            revert SettleRefused(i, Refusal.BadReadingIndex);
        }
        done = true;

        Reading calldata p = readings[s.prev].reading;
        Reading calldata q = readings[s.settle].reading;
        if (p.matchId != c.matchId || q.matchId != c.matchId) revert SettleRefused(i, Refusal.WrongMatch);
        if (q.seq != p.seq + 1 || p.seq < c.entrySeq) revert SettleRefused(i, Refusal.NotConsecutive);
        if (!(int64(p.clock) < c.settleAt && int64(q.clock) >= c.settleAt)) {
            revert SettleRefused(i, Refusal.NotFirstAtOrAfter);
        }
        if (int64(q.clock) - c.settleAt > int64(uint64(maxOvershootSeconds))) {
            revert SettleRefused(i, Refusal.Overshoot);
        }

        Outcome o = outcome(c.side, c.entryLead, q.lead);
        (uint256 fee, uint256 pay, uint256 liab) = _amounts(c.stakeUnits, c.feeBps, c.priceX100);
        uint256 back;
        if (o == Outcome.Won) {
            back = pay;
            feeUnits = fee;
        } else if (o == Outcome.Lost) {
            houseGainUnits = liab + (c.stakeUnits - fee);
            feeUnits = fee;
        } else {
            back = c.stakeUnits;
            houseGainUnits = liab;
        }
        releaseUnits = liab;

        Account storage a = accounts[c.account];
        a.openStakeUnits = uint48(uint256(a.openStakeUnits) - c.stakeUnits);
        a.openLiabilityUnits = uint48(uint256(a.openLiabilityUnits) - liab);
        if (back != 0) a.float = _u96(uint256(a.float) + back * unit);
        int64 loss = int64(c.stakeUnits) - int64(uint64(back));
        if (a.day != day) {
            a.day = uint32(day);
            a.dayLossUnits = loss;
        } else {
            a.dayLossUnits += loss;
        }
        calls[s.id] = DONE;
        emit CallSettled(s.id, c.account, o, back * unit, feeUnits * unit, q.seq);
    }

    /// @dev Whether `c` is the open call `id` of its account's current epoch (`live`); whether it is already
    ///      final or from an exited epoch, so a settle or void should pass over it (`skip`); else why it is
    ///      refused. A record that does not match what was opened is never skipped: it reverts.
    function _checkLive(bytes32 id, CallRecord calldata c) internal view returns (bool live, bool skip, Refusal why) {
        bytes32 stored = calls[id];
        if (stored == DONE) return (false, true, Refusal.AlreadyFinal);
        if (stored != keccak256(abi.encode(c))) return (false, false, Refusal.UnknownCall);
        if (accounts[c.account].epoch != c.epoch) return (false, true, Refusal.StaleCall);
        return (true, false, Refusal.UnknownCall);
    }

    function _verifyReadings(SignedReading[] calldata readings) internal view {
        address o = oracle;
        for (uint256 i; i < readings.length; ++i) {
            bytes32 digest = _hashTypedData(keccak256(abi.encode(READING_TYPEHASH, readings[i].reading)));
            address signer = _recover(digest, readings[i].signature);
            if (signer != o || signer == address(0)) revert BadReading(i);
        }
    }

    function _today() internal view returns (uint256) {
        return (block.timestamp + dayOffsetSeconds) / 1 days;
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function _buildDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    /// @dev ERC-1271 for an account with code (Kernel 0.3.1); if that does not answer yes, a plain ECDSA
    ///      signature by the account itself (an ordinary wallet, or a delegated EOA).
    function _isValidAccountSignature(address account, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        if (account.code.length != 0) {
            bytes memory data = abi.encodeCall(IERC1271.isValidSignature, (digest, signature));
            bool ok;
            bytes32 answer;
            // Read at most 32 bytes back, so an account cannot make the caller pay to copy a huge answer.
            assembly ("memory-safe") {
                ok := staticcall(gas(), account, add(data, 32), mload(data), 0, 32)
                if lt(returndatasize(), 32) { ok := 0 }
                answer := mload(0)
            }
            if (ok && answer == bytes32(ERC1271_MAGIC)) return true;
        }
        address signer = _recover(digest, signature);
        return signer != address(0) && signer == account;
    }

    /// @dev 65-byte (r, s, v) ECDSA; returns address(0) for anything malformed or malleable.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        if (uint256(s) > HALF_ORDER || (v != 27 && v != 28)) return address(0);
        return ecrecover(digest, v, r, s);
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert Overflow();
        return uint128(x);
    }

    function _u96(uint256 x) internal pure returns (uint96) {
        if (x > type(uint96).max) revert Overflow();
        return uint96(x);
    }

    function _u48(uint256 x) internal pure returns (uint48) {
        if (x > type(uint48).max) revert Overflow();
        return uint48(x);
    }

    function _pull(address from, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            address(token).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
