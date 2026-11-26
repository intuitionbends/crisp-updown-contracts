// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Base} from "./utils/Base.sol";
import {UpDownVault} from "../src/UpDownVault.sol";

/// @notice Replacing the operator, oracle and guardian keys: admin only, announced, and possible only after
///         `keyChangeDelay` (24 hours, the recommended value, in these tests).
contract KeyRotationTest is Base {
    uint8 constant OPERATOR = uint8(UpDownVault.Role.Operator);

    address newOperator = makeAddr("newOperator");
    address newGuardian = makeAddr("newGuardian");
    uint256 newOracleKey;
    address newOracle;

    function setUp() public override {
        super.setUp();
        (newOracle, newOracleKey) = makeAddrAndKey("newOracle");
        _authoriseDefaults();
        _fill(alice, aliceDevice, 100 * USDT);
    }

    function _propose(UpDownVault.Role role, address key) internal {
        vm.prank(admin);
        vault.proposeKey(role, key);
    }

    function _execute(UpDownVault.Role role) internal {
        vm.prank(admin);
        vault.executeKey(role);
    }

    // ------------------------------------------------------------------------------------------ the delay

    function test_proposalIsAnnouncedWithItsTime() public {
        uint64 eta = uint64(vm.getBlockTimestamp() + 24 hours);
        vm.expectEmit(true, false, false, true, address(vault));
        emit UpDownVault.KeyChangeProposed(UpDownVault.Role.Operator, operator, newOperator, eta);
        _propose(UpDownVault.Role.Operator, newOperator);
        (address key, uint64 when) = vault.pendingKeys(UpDownVault.Role.Operator);
        assertEq(key, newOperator);
        assertEq(when, eta);
        assertEq(vault.operator(), operator, "nothing changes on proposal");
    }

    function test_cannotTakeEffectBeforeTheDelay() public {
        uint256 t = vm.getBlockTimestamp();
        _propose(UpDownVault.Role.Operator, newOperator);
        vm.warp(t + 24 hours - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.KeyChangeNotReady.selector, uint64(t + 24 hours)));
        vault.executeKey(UpDownVault.Role.Operator);
        vm.warp(t + 24 hours);
        vm.expectEmit(true, false, false, true, address(vault));
        emit UpDownVault.KeyChanged(UpDownVault.Role.Operator, operator, newOperator);
        _execute(UpDownVault.Role.Operator);
        assertEq(vault.operator(), newOperator);
        (address key,) = vault.pendingKeys(UpDownVault.Role.Operator);
        assertEq(key, address(0), "the proposal is used up");
    }

    function test_aNewProposalRestartsTheDelay() public {
        uint256 t = vm.getBlockTimestamp();
        _propose(UpDownVault.Role.Operator, newOperator);
        vm.warp(t + 12 hours);
        address other = makeAddr("otherOperator");
        _propose(UpDownVault.Role.Operator, other);
        vm.warp(t + 24 hours); // the first proposal's time, not the second's
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.KeyChangeNotReady.selector, uint64(t + 36 hours)));
        vault.executeKey(UpDownVault.Role.Operator);
        vm.warp(t + 36 hours);
        _execute(UpDownVault.Role.Operator);
        assertEq(vault.operator(), other);
    }

    function test_cancel() public {
        _propose(UpDownVault.Role.Guardian, newGuardian);
        vm.expectEmit(true, false, false, true, address(vault));
        emit UpDownVault.KeyChangeCancelled(UpDownVault.Role.Guardian, newGuardian);
        vm.prank(admin);
        vault.cancelKey(UpDownVault.Role.Guardian);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.NoPendingKey.selector);
        vault.executeKey(UpDownVault.Role.Guardian);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.NoPendingKey.selector);
        vault.cancelKey(UpDownVault.Role.Guardian);
        assertEq(vault.guardian(), guardian);
    }

    // ------------------------------------------------------------------------------------- each role moves

    function test_operatorMoves() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 0, 0);
        _propose(UpDownVault.Role.Operator, newOperator);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _execute(UpDownVault.Role.Operator);

        vm.prank(operator);
        vm.expectRevert(UpDownVault.NotOperator.selector);
        vault.fill(alice, aliceDevice, 1);

        // The new operator settles a call the old one opened, and can recall to the owner.
        operator = newOperator;
        _settleOne(c, 1);
        assertEq(_float(alice), 90 * USDT + 19 * USDT);
        vm.prank(newOperator);
        vault.recall(alice, 1);
    }

    function test_oracleMoves() public {
        Opened memory c = _openOne(alice, aliceDeviceKey, 0, 10 * USDT, 190, 0, 0);
        _propose(UpDownVault.Role.Oracle, newOracle);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _execute(UpDownVault.Role.Oracle);

        // Readings from the old oracle are no longer accepted.
        UpDownVault.SignedReading[] memory rs = _two(_reading(MATCH, seq, 629, 0), _reading(MATCH, seq + 1, 630, 9));
        UpDownVault.SettleItem[] memory items = new UpDownVault.SettleItem[](1);
        items[0] = UpDownVault.SettleItem({id: c.id, call: c.rec, prev: 0, settle: 1});
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UpDownVault.BadReading.selector, 0));
        vault.settleCalls(items, rs);

        // The new oracle's readings settle the call opened on the old oracle's reading.
        oracleKey = newOracleKey;
        _settleOne(c, 9);
        assertEq(vault.calls(c.id), bytes32(uint256(1)));
    }

    function test_guardianMoves() public {
        _propose(UpDownVault.Role.Guardian, newGuardian);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _execute(UpDownVault.Role.Guardian);
        vm.prank(guardian);
        vm.expectRevert(UpDownVault.NotGuardian.selector);
        vault.pause();
        vm.prank(newGuardian);
        vault.pause();
        (,,, bool paused) = vault.state();
        assertTrue(paused);
    }

    /// A stolen guardian key re-pausing the vault is ended by rotating the guardian.
    function test_aStolenGuardianIsRotatedOut() public {
        uint256 t = vm.getBlockTimestamp();
        vm.prank(guardian);
        vault.pause();
        _propose(UpDownVault.Role.Guardian, newGuardian);
        for (uint256 d = 1; d <= 2; ++d) {
            vm.prank(admin);
            vault.unpause();
            vm.prank(guardian); // the thief pauses again
            vault.pause();
            vm.warp(t + d * 12 hours);
        }
        _execute(UpDownVault.Role.Guardian);
        vm.prank(admin);
        vault.unpause();
        vm.prank(guardian);
        vm.expectRevert(UpDownVault.NotGuardian.selector);
        vault.pause();
    }

    function test_rotationWorksWhilePaused() public {
        vm.prank(guardian);
        vault.pause();
        _propose(UpDownVault.Role.Operator, newOperator);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _execute(UpDownVault.Role.Operator);
        assertEq(vault.operator(), newOperator);
    }

    function test_rotationDoesNotResetTheExitClock() public {
        uint256 t = vm.getBlockTimestamp();
        _propose(UpDownVault.Role.Operator, newOperator);
        vm.warp(t + 24 hours);
        _execute(UpDownVault.Role.Operator);
        // The new operator has done nothing; the old one was last active at t. Users can exit.
        vm.prank(alice);
        vault.exit();
        assertEq(_float(alice), 0);
    }

    // ------------------------------------------------------------------------------------------ refusals

    function test_revert_onlyAdmin() public {
        address[3] memory who = [operator, guardian, makeAddr("anyone")];
        for (uint256 k; k < 3; ++k) {
            vm.startPrank(who[k]);
            vm.expectRevert(UpDownVault.NotAdmin.selector);
            vault.proposeKey(UpDownVault.Role.Operator, who[k]);
            vm.expectRevert(UpDownVault.NotAdmin.selector);
            vault.cancelKey(UpDownVault.Role.Operator);
            vm.expectRevert(UpDownVault.NotAdmin.selector);
            vault.executeKey(UpDownVault.Role.Operator);
            vm.stopPrank();
        }
    }

    function test_revert_zeroKey() public {
        vm.prank(admin);
        vm.expectRevert(UpDownVault.ZeroAddress.selector);
        vault.proposeKey(UpDownVault.Role.Oracle, address(0));
    }

    function test_revert_executeWithNothingProposed() public {
        vm.prank(admin);
        vm.expectRevert(UpDownVault.NoPendingKey.selector);
        vault.executeKey(UpDownVault.Role.Oracle);
    }

    function test_revert_operatorAndOracleMustDiffer() public {
        vm.startPrank(admin);
        vm.expectRevert(UpDownVault.RolesMustDiffer.selector);
        vault.proposeKey(UpDownVault.Role.Operator, oracle);
        vm.expectRevert(UpDownVault.RolesMustDiffer.selector);
        vault.proposeKey(UpDownVault.Role.Oracle, operator);
        vm.stopPrank();
    }

    /// Both keys proposed as the same new address: the first to take effect blocks the second.
    function test_revert_operatorAndOracleMustDifferAtExecution() public {
        address shared = makeAddr("shared");
        _propose(UpDownVault.Role.Operator, shared);
        _propose(UpDownVault.Role.Oracle, shared);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _execute(UpDownVault.Role.Oracle);
        vm.prank(admin);
        vm.expectRevert(UpDownVault.RolesMustDiffer.selector);
        vault.executeKey(UpDownVault.Role.Operator);
        assertEq(vault.operator(), operator);
    }

    function test_revert_constructorChecks() public {
        UpDownVault.Config memory c = _config();
        c.keyChangeDelay = 0;
        vm.expectRevert(UpDownVault.BadConfig.selector);
        new UpDownVault(c);
        c = _config();
        c.oracle = c.operator;
        vm.expectRevert(UpDownVault.RolesMustDiffer.selector);
        new UpDownVault(c);
    }

    function testFuzz_nobodyButTheAdminRotates(address who, uint8 roleSeed, address key) public {
        vm.assume(who != admin && key != address(0));
        UpDownVault.Role role = UpDownVault.Role(roleSeed % 3);
        vm.prank(who);
        vm.expectRevert(UpDownVault.NotAdmin.selector);
        vault.proposeKey(role, key);
    }
}
