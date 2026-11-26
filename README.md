# crisp-updown-contracts

`UpDownVault`: the on-chain custody and settlement layer for Crisp's Up/Down game on BSC. It holds each user's float,
the house pool and Crisp's fees in USDT. It takes calls signed by a user's device key and decides every payout from
readings signed by the oracle. The rules are the engine's, restated from `crisp-updown/src/rules.rs`.

First version. Built and tested locally only: nothing is deployed and no real keys exist.

```bash
forge build
forge test                                         # everything, 203 tests
forge test --match-contract Gas --isolate -vv      # the gas figures below
slither .                                          # static analysis; settings in slither.config.json
```

Foundry 1.0, solc 0.8.28 (`via_ir`, optimizer 10,000 runs), EVM `cancun`. `forge-std` v1.9.7 is vendored in `lib/`
(copied from a local checkout, not a submodule), and `foundry.toml` sets `offline = true`.

## Deployments

**BSC testnet (chain 97)**, deployed 2026-11-26. This is a test deployment for sharing, not the launch contract.

| Contract | Address and verified source on BscScan | Also on Sourcify |
|---|---|---|
| UpDownVault | [`0xfBAc8E64AD6c74B3a8b0282d09A00Cf704190Cd6`](https://testnet.bscscan.com/address/0xfBAc8E64AD6c74B3a8b0282d09A00Cf704190Cd6#code) | [exact match](https://repo.sourcify.dev/97/0xfBAc8E64AD6c74B3a8b0282d09A00Cf704190Cd6) |
| TestUSDT (tUSDT, 18 decimals, anyone can mint) | [`0x6e1A88AD2cD18f3dA0f79FF14D20D939f8b74570`](https://testnet.bscscan.com/address/0x6e1A88AD2cD18f3dA0f79FF14D20D939f8b74570#code) | [exact match](https://repo.sourcify.dev/97/0x6e1A88AD2cD18f3dA0f79FF14D20D939f8b74570) |

Roles: admin, guardian and fee recipient are the deployer `0x599db79A2f192A14bfef857462025014305AB33c`; the operator
is `0xD97d8C0451FCC2ef4078cdE3628fCd3Aa12220bF` and the oracle `0x9596702B27dD4b8F126c21383e298363410e9487`. Their
keys are encrypted keystores on the owner's machine. Settings are the tested values in
[script/DeployUpDownVault.s.sol](script/DeployUpDownVault.s.sol), including the 24-hour key-change delay; the fee
ceiling starts at 0. The full record is [deployments/bsc-testnet.json](deployments/bsc-testnet.json).

To deploy again: `./script/deploy-testnet.sh` (asks for the deployer keystore password). The same script deploys to
BSC mainnet on real USDT when pointed at a mainnet RPC. Both contracts are verified as exact matches on BscScan
(through its web form, Standard-JSON-Input, compiler v0.8.28+commit.7893614a, "No License") and on Sourcify (through
its v2 API; Foundry 1.0's built-in Sourcify step fails against Sourcify's current API). The compiler inputs and the
vault's encoded constructor arguments used are in [deployments/bscscan-verify/](deployments/bscscan-verify/).

## What it holds

Three balances in one token, kept apart:

| Balance | Where | Moves by |
|---|---|---|
| A user's float | `accounts[a].float` (free) and `openStakeUnits` (staked in open calls) | `fill` in; `recall` and `exit` out, to the user's own address only |
| The house pool | `house.free` and `house.locked` | `fundHouse` and `withdrawHouse` (free money only); every open call locks its liability |
| Accrued fees | `state.fees` | Fees on won and lost calls in; `withdrawFees()` pays all of it to `feeRecipient` |

**Units.** Signed messages and balances are in token base units (18 decimals). A call's stake, fee, payout and
liability are counted in whole `unit`s (`1e16` = one cent): a stake must be a whole number of units, and the fee and
the payout round to a unit. This is the engine's "rounded down to a whole coin", with one coin as one cent.

**What a call locks.** The user's whole stake comes out of the float. The house locks
`liability = payout(stake − fee) − (stake − fee)` from its free pool. Together they cover the full payout plus the
fee, so a win can always be paid. When it settles:

| Result | User gets | House | Fees |
|---|---|---|---|
| Won | `(stake − fee) × price`, rounded down | pays its liability | `+ fee` |
| Lost | nothing | gets back its liability and keeps `stake − fee` | `+ fee` |
| Level, or void | the whole stake, fee included | liability released | nothing |

## Functions

| Function | Caller | Checks |
|---|---|---|
| `authorise(Permission, sig)` | operator | Signed by the account: ERC-1271 if it has code (Kernel), else plain ECDSA. Not expired. Nonce greater than the last one for that device key, so an old permission cannot be replayed. Works while paused |
| `fill(account, deviceKey, amount)` | operator | Not paused. The device key's permission is live. Float + open stakes + amount ≤ its float cap. Pulls from the account's wallet |
| `openCalls(items, readings)` | operator | Not paused. Every reading signed by the oracle. Per call: deadline, side, stake a whole unit, length > 0; intent signed by a live device key of the account; stake ≤ per-call maximum; price ≥ the signed minimum and within 1.01 to `maxPriceX100`; fee ≤ the ceiling and ≤ the signed maximum; entry reading on the intent's match and within `maxEntryLag` readings after the one seen; not taken before; float covers the stake; daily loss limit; the house's free pool covers its liability. A call that fails any check is rejected on its own (`CallRejected`) and the rest open |
| `settleCalls(items, readings)` | operator | Every reading signed by the oracle. Per call: the record matches the stored hash and the account's epoch; the settle reading is the first at or after the settle time (see below); not more than `maxOvershootSeconds` late. Works while paused |
| `voidCalls(items)` | operator | Reason code 1 to 8; the record matches and is current. Refund only. Works while paused |
| `recall(account, amount)` | operator or the account | Free float only (never open stake), sent to `account`. `type(uint256).max` means all. Works while paused |
| `exit()` | the account | The operator has been silent for `silenceSeconds`, **or** the caller's newest open call is that old. Cancels every open call (stake returned, house lock released), sends the whole float to the caller. Works while paused |
| `revoke(deviceKey)` | the account | Removes one of its own device keys. Calls already opened stand |
| `fundHouse(amount)` | admin | Pulls from the admin |
| `withdrawHouse(to, amount)` | admin | Free house money only |
| `setFeeBps(bps)` | admin | ≤ `feeLimitBps`. Applies to calls opened afterwards: each call keeps its own rate |
| `setFeeRecipient(to)` | admin | Not zero |
| `transferAdmin(to)`, `acceptAdmin()` | admin, then the new admin | Two steps; `transferAdmin(address(0))` cancels |
| `withdrawFees()` | anyone | No arguments; pays the whole fee balance to `feeRecipient`. Works while paused |
| `pause()` | guardian | Stops `fill` and `openCalls` only |
| `unpause()` | admin | Not in the brief; see Departures |
| `proposeKey(role, key)` | admin | Proposes a new operator, oracle or guardian key. Not zero; the operator and oracle must differ. Announced with `KeyChangeProposed` and the earliest time it can take effect (`keyChangeDelay` from now). A new proposal for the role restarts the delay |
| `executeKey(role)` | admin | Puts the proposed key in place once the delay has passed (rechecks that operator and oracle differ) |
| `cancelKey(role)` | admin | Withdraws a proposal before it takes effect |

**How batches fail.** In `openCalls` each call stands alone: one that fails a check emits
`CallRejected(id, account, index, reason)`, takes nothing, and the rest open. The engine returns that stake as
`chain_rejected`, as the plan describes. In `settleCalls` and `voidCalls`, a call that is already final (a retried
batch) or belongs to an epoch its account has exited is passed over with `CallSkipped(id, index, reason)`. Anything
else there means the operator sent wrong data (a forged record, readings that do not prove the settle time, a bad
reason code), so it reverts the whole batch with `SettleRefused(index, reason)` or `VoidRefused(index, reason)`. A
reading the oracle did not sign reverts any batch with `BadReading(index)`. This came out of the audit; see
[AUDIT.md](AUDIT.md).

The rules are public pure functions on the contract (`outcome`, `payout`, `returned`, `liability`, `feeOf`), and
settlement uses them, so the parity tests check the code that moves money.

## Signed messages

EIP-712, domain `UpDownVault` / `1` / chain id / vault address. The domain is rebuilt if the chain id changes.

```
Permission(address account,address deviceKey,uint256 floatCap,uint256 perCallMax,uint256 dailyLossLimit,uint64 validUntil,uint64 nonce)
CallIntent(address account,bytes32 matchId,uint8 side,uint256 stake,uint32 length,uint16 minPriceX100,uint16 maxFeeBps,uint64 readingSeen,uint256 nonce,uint64 deadline)
Reading(bytes32 matchId,uint64 seq,int32 clock,int64 lead)
```

- `side` 0 is Up, 1 is Down. `stake`, `floatCap`, `perCallMax` and `dailyLossLimit` are token base units.
  `readingSeen` is the sequence number of the reading the player was shown. `maxFeeBps` is the user's fee limit.
- **A call's id is the digest of its intent.** The vault takes a digest once and keeps it marked after settling, so
  an intent cannot be replayed. The nonce makes otherwise identical intents distinct. The engine's `requestId`
  maps to it naturally.
- Device-key and oracle signatures are 65-byte ECDSA; malleable (high-s) signatures are refused.
- `test/Eip712.t.sol` checks all three digests against signatures made by `cast wallet sign --data` (alloy's
  EIP-712, a separate implementation) from the JSON in `test/fixtures/`.

## Proving the settle reading is the first at or after the settle time

`settleAt` = the entry reading's clock + the call's length. A settle names two oracle readings of the call's match:

1. `settle.seq == prev.seq + 1`: consecutive sequence numbers, so no reading lies between them;
2. `prev.clock < settleAt <= settle.clock`: `prev` is before the settle time and `settle` is at or after it;
3. `prev.seq >= entrySeq`: both come after the call opened (`prev` may be the entry reading itself);
4. `settle.clock − settleAt <= maxOvershootSeconds`: otherwise the engine voids the call (`late_tick`), and so must
   the operator.

This rests on the oracle signing one reading per sequence number per match. The plan's anchored roots make a second,
conflicting reading for the same number publicly detectable, but the vault does not check them. Readings verified
once per batch serve every call that names them, so a reading that decides fifty calls is checked once.

**What it cannot prove.** If the match clock passed the settle time, went backwards, then passed it again, there are
two crossing pairs and the vault cannot tell which was first. The engine voids such a call (`clock_rewound`). The
vault relies on the operator doing the same: one more place where the oracle and operator are trusted, as the plan
says they are.

## Daily loss limit

Counted per account per day, in units: stakes lost (full stake, fee included) less profit on wins, with level
results and voids counting nothing. A new call is refused if today's loss so far + every open stake + the new stake
would pass the limit of the permission that signed it. Open stakes therefore count as already lost, so the limit holds
even if every open call loses. The day is `(block.timestamp + dayOffsetSeconds) / 1 day`.

## Parameters for the owner to set

None of these are final. Each is a constructor field (`UpDownVault.Config`) or a named constant. The tests use the
values shown.

| Parameter | Kind | Test value | Suggested or note |
|---|---|---|---|
| `feeLimitBps`: fixed fee limit | constructor | 500 | 5% suggested by the plan; `setFeeBps` can never pass it |
| `feeRoundsUp`: fee rounding | constructor | false | Down to the unit suggested (a stake under $1 at 1% pays no fee). `true` rounds up |
| `unit`: the rounding unit for stake, fee and payout | constructor | `1e16` (one cent) | The plan's "cents". With a smaller unit, open stakes per account cap at 2^48 units |
| `silenceSeconds`: operator silence before `exit` | constructor | 6 hours | Also how old a user's newest open call must be to exit while the operator is otherwise active |
| `dayOffsetSeconds`: day boundary for the daily loss limit | constructor | 28,800 (midnight UTC+8) | 0 is midnight UTC. The engine's PnL day is Asia/Kuala_Lumpur |
| `maxPriceX100`: price ceiling | constructor | 500 | The engine's prices run 1.18 to 4.75 at an even price of 1.90 |
| `maxOvershootSeconds` | constructor | 20 | The engine's `UPDOWN_MAX_OVERSHOOT` default. Not in the brief's list; see Departures |
| `maxEntryLag`: readings between the one seen and the entry | constructor | 3 | Not in the brief's list; see Departures |
| `keyChangeDelay`: wait before a new operator, oracle or guardian key takes effect | constructor | 24 hours | **Chosen: 24 hours.** Must be above 0 and is fixed at deploy. It is users' warning time against a bad admin installing its own keys, and also how long Up/Down stays paused while a stolen key is swapped. Consider 48 hours once the house pool and floats are large; not below about 12 hours |
| `admin`, `operator`, `oracle`, `guardian`, `feeRecipient` | constructor | test addresses | The operator and oracle must differ. Operator, oracle and guardian change by `proposeKey` after the delay; the admin by its two-step handover; the fee recipient by `setFeeRecipient` |
| Void reason codes | constants | 1 to 8 | `MATCH_GONE` 1, `CLOCK_STOPPED` 2, `CLOCK_REWOUND` 3, `LATE_TICK` 4, `CANCELLED` 5, `NOT_RACING` 6, `LAPPED` 7, `FEED_STALE` 8, from the engine's `void_reason` values. `chain_rejected` is not a void: a call rejected on chain never opened there |
| `MIN_PRICE_X100` | constant | 101 | A price must pay more than the stake |

The fee ceiling (`setFeeBps`) starts at 0 on deploy, so no call can carry a fee until the admin sets it.

## Measured gas

Measured with `forge test --match-contract Gas --isolate -vv`, which runs each vault call as its own transaction
with cold storage, as on chain. Figures are **whole-transaction gas**, including the 21,000 base and calldata. Each
player has one open call (the engine's rule), so every call in a batch touches a different, cold account. "Returning"
means the player has had a call before. A player's first settle writes their daily-loss slot for the first time, which
costs about 17,000 more, once.

| | Batch of 1 | Per call, batch of 10 | Per call, batch of 50 | Each extra call (10 → 50) | Plan's estimate |
|---|---|---|---|---|---|
| Open | 94,797 | 56,371 | 53,084 | **52,263** | 35,000 to 50,000 |
| Settle, calls sharing one reading pair | 81,022 | 32,509 | 28,215 | **27,142** | 25,000 to 35,000 |
| Settle, each call with its own reading pair | | 45,670 | 42,613 | 41,849 | |
| Settle, player's first ever | | 49,719 | 45,419 | 44,345 | |

Reading the operator and oracle keys from storage (so they can be rotated) adds about 4,200 gas per batch, not per
call. Calldata is about 4,200 gas of each open and 2,900 of each shared-reading settle (7,900 with its own readings). Open
execution alone is therefore about 48,000 per call. Its largest single cost is the new storage slot recording the call
(22,100), followed by two ECDSA recoveries (the device key, plus the oracle's once per batch) and the event.

At the plan's price (about $0.003 per 100k gas), a call opened and settled in a batch of 50 costs about
$0.0024.

## Tests

| Suite | What it covers | Result |
|---|---|---|
| `test/UpDownVault.t.sol` | Every function, and every revert or rejection: each custom error and each `Refusal` reason, with its index in the batch | 109 pass |
| `test/RuleParity.t.sol` | Every outcome case of `up_and_down_and_tie`, the payout cases and the 1..2000 loop of `payout_rounds_down_and_never_mints`, and the due-time cases of `settling_waits_then_settles_then_gives_up`. Each is run against the pure functions and end to end (open, settle, money moved = `returned`). The outcome and payout rules are also fuzzed, 1,000 runs each, against an independent restatement | 7 pass |
| `test/invariant/` | A handler drives random sequences of every state-changing function plus attacks: an outsider recalling someone else's float, the admin withdrawing locked money, the operator settling a forged record, resending an open or a settle that already landed, and a player emptying their float just before a batch with someone else's call. Invariants: the vault's USDT equals floats + open stakes + house (free and locked) + fees, exactly, apart from tokens sent to it directly; every token the vault ever sent went to its owner by recall or exit, to the admin's chosen address from the free pool, or to the fee recipient, and to nobody else; floats, open stakes, liabilities and fees match a shadow ledger computed from the engine's rules; locked house money equals the liability of every open call; no account's loss today plus open stakes ever passes its daily limit; no attack succeeded | 5 pass, plus a check that the handler really reaches the daily limit; 256 runs × 100 calls by default, and 2,000 runs × 150 calls (300,000 calls per invariant) in the audit |
| `test/Eip712.t.sol` | Digests against `cast`-signed fixtures | 4 pass |
| `test/Gas.t.sol` | The gas table | 7 pass |
| `test/KeyRotation.t.sol` | Replacing the operator, oracle and guardian: the delay to the second, cancel, a new proposal restarting the delay, each role handing over (including calls opened under the old key), operator and oracle kept apart, admin only (fuzzed) | 17 pass |
| `test/audit/Audit.t.sol` | The audit's attack and edge-case tests, by role; see [AUDIT.md](AUDIT.md) | 53 pass |

The smart-account tests use `MockSmartAccount`, which answers ERC-1271 for its owner's signature over the vault's own
digest. Real Kernel 0.3.1 is not exercised (no mainnet or fork calls were allowed). See below.

## Departures and ambiguities

1. **`unpause` (admin only) added.** The brief lists only `pause`. Without an unpause, one guardian action would end
   the vault for good. The admin (a multisig before mainnet) restarts it, and the hot guardian key can only stop it.
2. **`revoke(deviceKey)` added, callable by the account.** The brief gives no way to withdraw a device key. A
   revoked permission cannot be replayed, because its nonce is spent.
3. **`exit` also opens for a stuck call.** The brief says "after the operator has been silent". A live operator could
   keep posting other batches and never settle one user's call, locking that stake for ever. So `exit` also opens when
   the caller's newest open call is `silenceSeconds` old. Free float can be recalled at any time anyway.
4. **`exit` and the house.** Exit cancels the caller's open calls with an O(1) epoch bump: their stakes return and
   the house's locks release. A settle or void of an earlier-epoch call is then refused (`StaleCall`). A user who
   exits just as a silent operator returns keeps a stake the operator might have settled as a loss. That is the price
   of the way out.
5. **"Locks its full possible payout from the house pool"** is read as: the house locks the payout less the stake at
   risk (its liability), and the user's stake is locked from the float. Together they are the full payout plus the
   fee. Locking the whole payout from the house as well would lock the stake twice.
6. **`maxOvershootSeconds` and `maxEntryLag` are new parameters.** The brief does not name them. Without the
   overshoot limit, the operator could settle calls the engine voids (`late_tick`). Without the entry lag, an operator
   who has seen later readings could choose a later entry reading against the player.
7. **The daily loss limit nets wins against losses** and counts open stakes as already lost. The plan says only that
   a lost call counts its full stake. It is tracked per account but bounded by the signing permission's limit, so
   several devices do not multiply it.
8. **The float cap counts open stakes**, matching "the most the vault may hold for a user at one time". Winnings can
   take the float above the cap; only fills are bounded.
9. **Bad calls are rejected one at a time, not by reverting the batch** (changed in the audit). The first version
   reverted the whole batch, which let one player stop everyone's calls by recalling their float just before the
   batch landed. Rejections and skips are events, so the chain sink and the reconciler must read them.
10. **Only a hash of each open call is stored.** Settle and void hand the record back. This saves two new storage
    slots (about 44,000 gas) per open. The full record is in the `CallOpened` event for the chain sink.
11. **Operator, oracle and guardian keys can be replaced, after a delay** (added after the audit, at the owner's
    request; not in the brief). The admin proposes a key; it can take effect only `keyChangeDelay` later, and the
    proposal is announced on chain, so a change cannot be slipped in unnoticed. Until then the old key keeps its
    powers. What a stolen operator key can do in that window is limited (see AUDIT.md, A-06).

## Not verified, and not built

- **Kernel 0.3.1's ERC-1271.** Kernel wraps the digest in its own EIP-712 domain and expects a validator-mode prefix
  on the signature. The ZeroDev SDK's `signTypedData` on the Kernel account produces that. The vault passes its
  digest and the signature bytes through unchanged, so this should work, but it has not been run against a real
  Kernel account. It needs a BSC testnet run.
- **Counterfactual accounts (ERC-6492)** are not supported: an account must be deployed before it signs a permission.
  Predict accounts already are.
- **Fee-on-transfer tokens** are not handled. BSC USDT takes none.
- **The oracle's anchored reading roots** are not built here.
- **No audit.**
