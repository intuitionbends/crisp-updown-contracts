# UpDownVault: internal audit

An internal security review and test campaign on `src/UpDownVault.sol`, done before any deployment. It does not
replace the independent audit the plan requires before mainnet.

- **Source reviewed:** `src/UpDownVault.sol`, SHA-256 `60692fc76295dd2f…` after the fixes and the key rotation below.
  Nothing is committed yet, so there is no commit hash.
- **Method:** a line-by-line review of every function against each party that could act against the vault. Each
  conclusion is backed by a test that tries the attack or checks the edge, plus fuzzing and invariant runs.
- **Tools:** Foundry 1.0 (unit, fuzz and invariant tests) and Slither 0.11.6 (static analysis, 102 detectors; see
  "Slither" below). Slither was installed into a throwaway virtualenv; nothing was added to the repository except
  `slither.config.json`.

## Result

Five issues were fixed in the contract: A-01 to A-04, and key rotation (A-06), added at the owner's request.
Slither's two useful points were fixed too. One trust point and eight informational points remain open; the owner
decides on those. No issue was found that lets anyone take a user's float, take locked house money, mint value, or
pay out other than as the signed readings say.

| ID | Severity | Finding | Status |
|---|---|---|---|
| A-01 | Medium | One player could block every other player's calls | **Fixed** |
| A-02 | Low | Resending a batch that had already landed reverted it | **Fixed** |
| A-03 | Low | With `feeRoundsUp` set, the fee charged could pass the user's signed limit | **Fixed** |
| A-04 | Low | An account's ERC-1271 answer was copied in full, however large | **Fixed** |
| A-05 | Medium (trust) | The operator can void, or not settle, a call after it knows the result | Open: design decision |
| A-06 | Low (trust) | Operator, oracle and guardian keys could not be rotated | **Fixed** (delayed rotation) |
| A-07 | Info | The admin can redirect fees already accrued, not only future ones | Open |
| A-08 | Info | `fill` uses the float cap of whichever live key the operator names | Open |
| A-09 | Info | A permission survives a change of the smart account's owner | Open |
| A-10 | Info | A clock that rewinds past the settle time cannot be told apart on chain | Open (documented) |
| A-11 | Info | Tokens that take a transfer fee, or blacklist the vault, are not supported | Open (documented) |
| A-12 | Info | A call's length and the entry reading's clock are not bounded on chain | Open |
| A-13 | Info | An intent signed before an `exit` can still open after it, until its deadline | Open |
| A-14 | Info | Operator and oracle together can settle against users | Open (the plan's trust model) |
| S-1 | Info | Events were emitted after token transfers | **Fixed** (Slither) |
| S-2 | Info | Admin, fee-recipient and pause events did not index their addresses | **Fixed** (Slither) |

Severity: **Medium** means loss of availability for many users, or an unfair result for users, without breaking the
money's custody. **Low** means a limited or conditional effect. **Info** is something the owner should know.
"Trust" marks behaviour the plan accepts by trusting a Crisp key; the finding says what that trust allows.

## Fixed

### A-01 · Medium · One player could block every other player's calls

**Before.** `openCalls` was all or nothing. A player could make their own call fail between the operator's
simulation and the block: recall their float, or revoke their device key. That reverted every call in the batch.
Repeated each block, it would stop Up/Down for everyone. `exit`, once open, did the same to a settle batch, because
the exited player's call reverted it (`StaleCall`).

**Fix.** Each call in `openCalls` now stands alone. A call that fails a check emits
`CallRejected(id, account, index, reason)`, takes nothing, and the others open. The house is checked call by call
(`HouseShort`). This is also what the plan's `chain_rejected` path assumes. In `settleCalls` and `voidCalls`, a call
of an exited epoch is passed over with `CallSkipped`.

**Tests.** `UserAttackTest.test_cannotStopOtherPlayersCalls`, `test_exitCannotStopOtherPlayersSettles`,
`OpenTest.test_badItemDoesNotStopTheRest`, `test_houseShortRejectsOnlyTheCallThatDoesNotFit`. The invariant
handler's `griefBatch` attempts this throughout every invariant run.

### A-02 · Low · Resending a batch that had already landed reverted it

**Before.** If the chain sink resent a batch whose first send had landed unseen, every call in it was a duplicate,
or already final, and the resend reverted. That is exactly the retry the plan's outbox does.

**Fix.** A resent open is rejected (`Duplicate`) without effect. A resent settle or void is passed over
(`AlreadyFinal`). A record that does not match what was opened still reverts the batch: that is wrong data, not a
retry.

**Tests.** `SettleTest.test_settlingTwiceIsSkipped_retrySafe`, `VoidTest.test_revert_unknownOrAlreadyFinal`,
`OperatorCompromiseTest.test_cannotOpenTheSameIntentTwice`. The handler's `replayOpen` and `replaySettle` resend
landed batches, the settle with a different result, and count any change as a successful attack.

### A-03 · Low · With `feeRoundsUp` set, the fee charged could pass the user's signed limit

**Before.** Only the fee *rate* was checked against the ceiling and the user's `maxFeeBps`. Rounded up, 1% of a
1-cent stake is 1 cent: the whole stake.

**Fix.** The fee actually charged must also satisfy `fee × 10,000 ≤ stake × min(ceiling, maxFeeBps)`. With the
suggested rounding (down) nothing changes. Rounding up now refuses any call where the rounded fee would pass a limit.

**Tests.** `FeeRoundsUpLimitTest.test_oneCentStakeCannotPayAWholeCentFee`, `test_roundedUpFeeWithinTheLimitsIsTaken`.

### A-04 · Low · An account's ERC-1271 answer was copied in full, however large

**Before.** `authorise` copied whatever the account returned. An account returning a megabyte cost the operator's
transaction about 4.1M gas.

**Fix.** The vault now reads back 32 bytes only. The same account now costs about 2.07M gas, all of it the account's
own memory expansion inside its own frame. The vault cannot prevent that part without capping the gas it forwards,
which could break heavier validators such as passkeys. It is the user's own account, and the operator simulates
`authorise` before sending it.

**Tests.** `Erc1271HardeningTest.test_returnBombIsNotCopiedAndFails`. The test fails against the old code (4,110,800
gas) and passes against the new (2,076,725). `test_gasBurnerFailsInsteadOfStealingTheCall` covers an account that
burns all its gas.

### A-06 · Low (trust) · Operator, oracle and guardian keys could not be rotated

**Before.** They were immutable, because the brief listed no setters. Replacing a compromised operator or oracle key
meant pausing, deploying a new vault and moving everyone over. A stolen guardian key could pause again every time the
admin unpaused, stopping new calls until a redeploy.

**Fix.** `proposeKey(role, key)`, `executeKey(role)` and `cancelKey(role)`, all admin only.
- A proposal can take effect only `keyChangeDelay` later (a constructor parameter, fixed at deploy; 24 hours
  chosen). It is
  announced with `KeyChangeProposed`, including that time, so anyone watching the vault sees it coming.
- A new proposal for the same role restarts the delay, so the delay cannot be shortened by re-proposing.
- The operator and the oracle must always be different keys. This is checked at deploy, at proposal and again at
  execution, so proposing both as one new address cannot merge them.
- Calls opened under the old operator or oracle settle normally under the new one.
- Rotation does not reset the silence clock that opens `exit`.

**Still true during the delay.** The old key keeps its powers until the change takes effect. For a stolen operator
key that means: it can void calls or leave them unsettled (A-05), and settle only on readings the oracle signed. It
can fill floats up to their caps (the money stays the user's), and recall floats only to their owners. It cannot take
anything. Pausing stops new fills and calls meanwhile. The admin's own handover stays two-step without a delay, as
before.

**Tests.** `test/KeyRotation.t.sol`, 17 tests: the delay to the second, a new proposal restarting it, cancel, each role
handing over (`test_operatorMoves`, `test_oracleMoves`, `test_guardianMoves`), `test_aStolenGuardianIsRotatedOut`,
operator and oracle kept apart at proposal and at execution, rotation while paused, the exit clock, admin only
(fuzzed).

## Open

### A-05 · Medium (trust) · The operator can void, or not settle, a call after it knows the result

A void needs only a reason code from the list, at any time. An operator, or a stolen operator key, could therefore
void the calls the house would lose and settle the ones it wins. Simply never settling a winning call works too:
after `silenceSeconds` the user can exit, but gets back only the stake. The plan accepts this ("voids are used for
their listed reasons"), but it is the main way the house could be unfair while every check passes.

Options, cheapest first:
- The reconciler alerts on voids that follow a decided reading, and on void rates per match.
- `late_tick` voids carry their proof: the same consecutive reading pair, showing the overshoot.
- Other voids are allowed only before the settle time, or only with a reading showing why (the match gone, the clock
  stopped).

### A-07 · Info · The admin can redirect fees already accrued

`setFeeRecipient` followed by `withdrawFees` sends the current fee balance to the new address, not only future fees,
as the plan's wording suggests (`AdminGuardianLimitsTest.test_adminCanRedirectAccruedFees`). Sweeping to the old
recipient inside `setFeeRecipient` would close this. It is not done here, because a recipient that cannot receive
would then block the change.

### A-08 · Info · `fill` uses the float cap of whichever live key the operator names

Floats are per account; caps are per device key. With keys signed at different caps, `fill` is bounded by the
largest. Normally every key of an account carries the same caps.

### A-09 · Info · A permission survives a change of the smart account's owner

`authorise` checks the account's signature once. If the Kernel account's owner later changes, existing device keys
keep their permission until it expires or is revoked. crisp-trading should revoke them on an owner change.

### A-10 · Info · A clock that rewinds past the settle time cannot be told apart on chain

If the match clock passes the settle time, goes back, and passes it again, there are two reading pairs that each
look like "the first at or after". The engine voids such calls (`clock_rewound`). The vault relies on the operator to
do the same (see README, "Proving the settle reading is the first").

### A-11 · Info · Tokens that take a transfer fee, or blacklist the vault, are not supported

`fill` credits the amount asked for. On a token that keeps part of a transfer, the vault ends up short
(`TokenBehaviourTest.test_knownLimitation_feeOnTransferLeavesTheVaultShort`). A token that returns nothing on
transfer works (`test_worksWithATokenThatReturnsNothing`). BSC USDT takes no fee. A token able to freeze the vault's
address would freeze everything in it. Deploy only on the token the vault was tested for.

### A-12 · Info · A call's length and the entry reading's clock are not bounded on chain

The engine offers 30 or 60 seconds (15 for F1) and takes calls only once a game has started. The vault checks only
`length > 0`. A user-signed call with a huge length stays open until it is voided or the user exits.

### A-13 · Info · An intent signed before an `exit` can still open after it, until its deadline

The intent carries no epoch, so within its deadline (60 seconds in the tests) it can open in the new epoch, if the
float allows. This is harmless (the user signed it), but the engine should drop pending intents for an account that
exits.

### A-14 · Info · Operator and oracle together can settle against users

The oracle can sign any reading, and the operator chooses what to post. Together they could settle every open call
as a loss. Per account, that is bounded by the open stakes and the daily loss limit. The plan accepts this trust and
adds anchored reading roots, which the vault does not check. Keeping the two keys separate (KMS) is what protects
users here.

## Slither

Slither 0.11.6, all 102 detectors, on `src/` (tests and `lib/` excluded through `slither.config.json`). The first run
found 34 results, none of them High severity. 11 were fixed (S-1 and S-2). The 23 left were each checked against the
code:

| Detector | Count | Verdict |
|---|---|---|
| `timestamp` | 9 | Intended. Deadlines, permission expiry, the silence before `exit`, the key-change delay and the day of the daily loss limit are all measured in seconds to days. A validator's few seconds of clock leeway changes nothing material. Several of the nine are not timestamp comparisons at all (`stored == DONE`, a transfer's return value); Slither's taint tracking over-reaches |
| `uninitialized-local` | 6 | Intended. Batch totals and `back` start at zero, which is Solidity's default |
| `incorrect-equality` | 3 | False positive. The detector looks for `balance == x` checks an attacker can upset. These compare a sentinel (`DONE`), a day number, and a stored fee balance that only the vault changes |
| `low-level-calls` | 2 | Intended. The safe-transfer pattern for tokens that return `false` or nothing. Both outcomes are checked and covered by tests |
| `divide-before-multiply` | 1 | False positive. `stakeUnits = stake / unit` is exact: a stake that is not a whole number of units is rejected (`BadStake`) before this line |
| `missing-zero-check` | 1 | Intended. `transferAdmin(address(0))` cancels a proposal, and `acceptAdmin` refuses address 0 |
| `assembly` | 1 | Intended. The bounded ERC-1271 call from A-04, which reads back 32 bytes only |

### S-1 · Info · Events were emitted after token transfers (fixed)

`fill`, `recall`, `exit`, `fundHouse`, `withdrawHouse` and `withdrawFees` emitted their event after the token call.
State was already updated before each call, so nothing could be taken twice (`ReentrancyTest`). With a token that
calls back, however, events could be logged out of order for indexers. Each now emits before the transfer.

### S-2 · Info · Admin, fee-recipient and pause events did not index their addresses (fixed)

`FeeRecipientSet`, `AdminProposed`, `AdminTransferred`, `Paused` and `Unpaused` now index their address parameters,
so monitoring can filter for them. The new `KeyChange*` events index the role.

## What the tests establish

Each line is a property the vault holds, and the tests that show it. Test files are under `test/`.

**Custody**
- A float is only ever paid to its owner: by `recall` (operator or owner) or `exit` (owner).
  `OperatorCompromiseTest.test_recallAlwaysPaysTheOwnerNotTheOperator`, `UserAttackTest.test_cannotRecallSomeoneElsesFloat`.
  The invariant `invariant_floatsOnlyToOwners` checks every token the vault ever sent, over 300,000 calls in the
  audit run.
- An open stake cannot be recalled; it leaves only by settle, void or exit.
  `UserAttackTest.test_cannotEscapeALosingCallWhileTheOperatorIsActive`.
- The admin reaches only the free house pool and the fee recipient's address.
  `AdminGuardianLimitsTest.test_adminCannotReachFloatsLockedMoneyOrRecall`.
- The vault's balance always equals floats + open stakes + house (free and locked) + fees, exactly, apart from
  tokens sent to it directly. `invariant_solvent`, `ConservationFuzzTest`.
- When the operator vanishes, everyone gets out and nothing is stuck: after all exits and the house withdrawal the
  vault holds 0. `LifecycleTest.test_fullRoundThenOperatorVanishes`.

**Authorisation**
- No call opens without a signature from a live device key of that account. The operator, another player, the oracle,
  a revoked or expired key, a malformed signature and an altered intent are all refused. Tests: `OpenTest.test_revert_noPermission`,
  `test_revert_permissionExpiredOrRevoked`, `OperatorCompromiseTest.test_cannotOpenACallNobodySigned`,
  `test_cannotMoveAnIntentToAnotherAccount`, `UserAttackTest.test_cannotOpenOnSomeoneElsesAccount`,
  `SignatureAttackTest.test_noMessageCanStandInForAnother`, `test_malformedSignaturesRecoverNobody`.
- Signatures do not cross vaults, chains or message types. `SignatureAttackTest` (5 tests). `Eip712Test` checks all
  three digests against `cast`.
- An old permission cannot be replayed after a newer one or a revoke. `AuthoriseTest.test_revert_staleNonce_replayAndOlder`,
  `RevokeTest`.
- Every role-gated function refuses every other caller (fuzzed). `AccessControlFuzzTest`.

**Payout**
- The payout is exactly the engine's rule: all 12 outcome cases and the payout cases from `rules.rs`, plus 20,000
  fuzz runs each of outcome and payout in the audit run. `RuleParityTest`.
- Value is conserved to the wei on every open and settle, the user gets exactly the rule's amount, the fee is taken
  only on decided calls, and the house never pays more than it locked. 20,000 fuzzed runs in the audit run.
  `ConservationFuzzTest.testFuzz_openSettleConserves`.
- A settle uses only the first oracle reading at or after the settle time. A skipped reading, an early or late pair,
  readings from before the call, another match's readings, an unsigned reading and a forged record (each of its nine
  fields) are all refused. `OperatorCompromiseTest.test_cannotSettleOnAnythingButTheFirstReadingAtOrAfter`,
  `test_cannotSettleWithReadingsTheOracleDidNotSign`, `test_cannotSettleAForgedRecord`. The handler's forged settles
  run in every invariant run.
- A call is opened once and settled or voided once. `test_cannotOpenTheSameIntentTwice`,
  `test_settlingTwiceIsSkipped_retrySafe`, and the handler's `replayOpen` and `replaySettle`.

**Limits**
- Fee at or under both the admin's ceiling and the user's signed maximum, after rounding.
  `OperatorCompromiseTest.test_cannotChargeMoreThanTheUserSigned`, `FeeRoundsUpLimitTest`.
- Price at or above the user's signed minimum and within 1.01 to the ceiling. `test_cannotPayLessThanTheUserSigned`,
  `BoundaryTest.test_priceFloorAndCeiling`.
- The entry reading is within `maxEntryLag` after the one the player saw, on the same match.
  `test_cannotPickAnEntryReadingOutsideTheWindow`.
- The daily loss limit always holds, open stakes included, even with a stolen low-limit key.
  `invariant_dailyLossNeverExceeded`, `UserAttackTest.test_aStolenLowLimitKeyIsBoundByItsOwnLimit`, `DailyLossTest`.
- Every limit holds exactly at its edge and refuses one past it: deadline, permission expiry, price, fee, stake,
  daily loss, float cap, silence. `BoundaryTest` (7 tests), `FillTest.test_fillUpToCapExactly`.

**Liveness**
- A compromised operator, oracle or guardian key can be replaced without redeploying, after an announced delay.
  `KeyRotationTest`.
- A pause stops only fills and new calls. Settles, voids, recalls, exits, fee sweeps and admin actions all still
  work. `PauseMatrixTest.test_matrix`.
- One player cannot stop others' opens or settles, and resent batches are safe. A-01 and A-02 above.
- A token that calls the recipient back cannot be used to take a float twice, by `recall` or `exit`.
  `ReentrancyTest` (2 tests).

## Test run

`forge test`: **203 tests, all passing**, in 31 suites:

| Suite | Tests |
|---|---|
| `test/UpDownVault.t.sol`: every function, revert and rejection | 109 |
| `test/audit/Audit.t.sol`: the attacks and edges above | 53 |
| `test/KeyRotation.t.sol` | 17 |
| `test/RuleParity.t.sol` | 7 |
| `test/Gas.t.sol` | 7 |
| `test/invariant/Invariants.t.sol`: 5 invariants and the handler self-check | 6 |
| `test/Eip712.t.sol` | 4 |

Audit campaign, run once on top of the defaults:
- Invariants at 2,000 runs × 150 calls (300,000 calls per invariant): all 5 hold.
- Every fuzz test at 20,000 runs: all pass.

The handler was checked to really reach its daily-loss limit and its grief and replay paths, so the invariants are
exercised, not merely passing.

## Before mainnet

1. An independent audit (the plan's gate).
2. A BSC testnet run with a real Kernel 0.3.1 account, signing a permission through the ZeroDev SDK, to confirm the
   ERC-1271 path end to end.
3. Decide A-05. If voids are to carry proofs, that is a contract change and needs its own tests.
4. Deploy with `keyChangeDelay` = 24 hours (chosen), and have monitoring page someone on every `KeyChangeProposed`
   (A-06). Reconsider 48 hours once the house pool and floats are large.
5. Make the chain sink and the reconciler read `CallRejected` and `CallSkipped` (A-01, A-02).
6. Optionally, a second static analyser (Aderyn) alongside Slither.
