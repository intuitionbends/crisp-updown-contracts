// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {UpDownVault} from "../../src/UpDownVault.sol";
import {MockUSDT} from "../utils/Mocks.sol";
import {Handler} from "./Handler.sol";

contract InvariantsTest is Test {
    UpDownVault internal vault;
    MockUSDT internal usdt;
    Handler internal handler;

    function setUp() public {
        vm.warp(1_795_000_000);
        usdt = new MockUSDT();
        address admin = makeAddr("admin");
        address operator = makeAddr("operator");
        address guardian = makeAddr("guardian");
        address feeRecipient = makeAddr("feeRecipient");
        (address oracle, uint256 oracleKey) = makeAddrAndKey("oracle");
        vault = new UpDownVault(
            UpDownVault.Config({
                token: address(usdt),
                admin: admin,
                operator: operator,
                oracle: oracle,
                guardian: guardian,
                feeRecipient: feeRecipient,
                unit: 1e16,
                feeLimitBps: 500,
                feeRoundsUp: false,
                silenceSeconds: 6 hours,
                dayOffsetSeconds: 8 hours,
                maxPriceX100: 500,
                maxOvershootSeconds: 20,
                maxEntryLag: 3,
                keyChangeDelay: 24 hours
            })
        );
        handler = new Handler(vault, usdt, admin, operator, guardian, feeRecipient, oracleKey);

        usdt.mint(admin, 50_000e18);
        vm.startPrank(admin);
        usdt.approve(address(vault), type(uint256).max);
        vault.fundHouse(50_000e18);
        vault.setFeeBps(100);
        vm.stopPrank();

        targetContract(address(handler));
    }

    function _sums() internal view returns (uint256 floats, uint256 open, uint256 liab) {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            (uint96 f, uint48 s, uint48 l,,,,) = vault.accounts(a);
            floats += f;
            open += uint256(s) * vault.unit();
            liab += uint256(l) * vault.unit();
        }
    }

    /// The vault's USDT always covers floats + open stakes + house pool (free and locked) + accrued fees.
    /// Exactly, apart from tokens sent to it directly, which belong to nobody.
    function invariant_solvent() public view {
        (uint256 floats, uint256 open,) = _sums();
        (uint256 free, uint256 locked) = vault.house();
        (uint128 fees,,,) = vault.state();
        uint256 owed = floats + open + free + locked + fees;
        uint256 bal = usdt.balanceOf(address(vault));
        assertGe(bal, owed, "vault short");
        assertEq(bal, owed + handler.ghostDonated(), "unexplained balance");
    }

    /// A float only ever leaves to its owner: every token the vault has sent went to a player through their own
    /// recall or exit, to the admin's chosen address from the free house pool, or to the fee recipient from fees.
    function invariant_floatsOnlyToOwners() public view {
        uint256 accounted;
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(usdt.sent(address(vault), a), handler.ghostOut(a), "player paid other than by recall/exit");
            accounted += handler.ghostOut(a);
        }
        assertEq(usdt.sent(address(vault), handler.houseSink()), handler.ghostHouseOut());
        assertEq(usdt.sent(address(vault), handler.feeRecipient()), handler.ghostFeesOut());
        accounted += handler.ghostHouseOut() + handler.ghostFeesOut();
        assertEq(usdt.totalSent(address(vault)), accounted, "vault paid someone else");
        assertEq(handler.attacksSucceeded(), 0, "an attack succeeded");
    }

    /// Each float and open stake equals the shadow ledger worked out from the engine's rules.
    function invariant_matchesShadowLedger() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            (uint96 f, uint48 s, uint48 l,,,,) = vault.accounts(a);
            assertEq(f, handler.shadowFloat(a), "float");
            assertEq(uint256(s) * vault.unit(), handler.shadowOpen(a), "open stake");
            assertEq(uint256(l) * vault.unit(), handler.shadowLiability(a), "liability");
        }
        (uint128 fees,,,) = vault.state();
        assertEq(fees, handler.shadowFees(), "fees");
    }

    /// Locked house money is exactly the full possible payout less stake of every open call.
    function invariant_lockedMatchesOpenCalls() public view {
        (,, uint256 liab) = _sums();
        (, uint256 locked) = vault.house();
        assertEq(locked, liab);
        assertEq(locked, handler.openLiabilityTotal());
    }

    /// No account can ever be exposed past its daily loss limit: today's net loss plus every open stake.
    function invariant_dailyLossNeverExceeded() public view {
        uint256 today = vault.today();
        int256 limit = int256(handler.DAILY_LIMIT() / vault.unit());
        for (uint256 i; i < handler.actorCount(); ++i) {
            (, uint48 open,,,, uint32 day, int64 loss) = vault.accounts(handler.actors(i));
            int256 lossToday = day == today ? int256(loss) : int256(0);
            assertLe(lossToday + int256(uint256(open)), limit);
        }
    }

    /// Checks the handler itself: driven straight at the limit, it must see rejections, or the daily loss
    /// invariant would pass without ever being tested.
    function test_handlerHitsTheDailyLimit() public {
        for (uint256 k; k < 4; ++k) {
            handler.open(0, true, 99_999, 190, 0, 0, false); // about 1,000 USDT each against a 1,500 limit
        }
        assertEq(handler.calls("open"), 1);
        assertEq(handler.calls("openRejected"), 3);
    }

    function afterInvariant() external view {
        string[20] memory names = [
            "fill",
            "open",
            "openRejected",
            "settle",
            "void",
            "recall",
            "exit",
            "fundHouse",
            "withdrawHouse",
            "withdrawFees",
            "setFeeBps",
            "pause",
            "warp",
            "donate",
            "attackRecall",
            "attackWithdrawHouse",
            "attackForgedSettle",
            "replayOpen",
            "replaySettle",
            "griefBatch"
        ];
        for (uint256 i; i < names.length; ++i) {
            console.log(names[i], handler.calls(names[i]));
        }
    }
}
