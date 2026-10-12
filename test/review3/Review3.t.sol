// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BossToken} from "../../src/BossToken.sol";
import {AbilityBoard} from "../../src/AbilityBoard.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FixedAbility} from "../mocks/Abilities.sol";
import {BossFixture} from "../utils/BossFixture.sol";
import {Bundle, SmartAccount} from "../utils/Bundle.sol";
import {R3Router, SplitHealer} from "./R3Router.sol";
import {BossHook} from "../../src/BossHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

/// @dev Third independent review, on fix-audit2 @ 53e3ce2 (fixes of the swarm's second audit). Finding A
/// (sell first, then buy back) was fixed by anchoring the cap at the transaction's first trade; finding B
/// (BOSS left inside the PoolManager, taken by another party without a swap here) is a documented limit,
/// so B1-B3 now assert the documented behaviour.
/// Convention of the earlier reviews: each probe asserts what the fix CLAIMS in its final assertions,
/// so a FAIL documents a gap between the claim and the code and a PASS confirms the claim.
/// Runs with BOSS as currency0 and as currency1 (IMD pairing) and with native ETH.
abstract contract Review3Base is BossFixture {
    using stdStorage for StdStorage;
    address internal bundlerEOA = makeAddr("bundlerEOA");
    address internal bundlerWallet = makeAddr("bundlerWallet");
    R3Router internal ra; // the victim's / player's router (locker A)
    R3Router internal rb; // another party's router (locker B), same pool
    R3Router internal rx; // another party's router on a HOOKLESS BOSS pool (never calls BossHook.afterSwap)
    PoolKey internal key2;
    Bundle internal bundle;

    function setUp() public virtual override {
        super.setUp();
        _r3SetUp();
    }


    function _r3SetUp() internal {
        ra = new R3Router(IPoolManager(address(manager)), key, boss);
        rb = new R3Router(IPoolManager(address(manager)), key, boss);
        // Anyone can open a plain BOSS pool next to the game's (no hook, other fee tier).
        key2 = PoolKey({
            currency0: key.currency0, currency1: key.currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        manager.initialize(key2, TickMath.getSqrtPriceAtTick(launchTick()));
        _seedPool2(40_000_000 ether);
        rx = new R3Router(IPoolManager(address(manager)), key2, boss);
        _fundRouter(address(ra));
        _fundRouter(address(rb));
        _fundRouter(address(rx));
        bundle = new Bundle();
    }

    function _fundRouter(address r) internal {
        if (useNative()) vm.deal(r, 100 ether);
        else quoteToken.mint(r, 100 ether);
    }

    function _seedPool2(uint256 bossAmount) internal {
        int24 tick = launchTick();
        int24 lower;
        int24 upper;
        uint128 liq;
        if (bossIsCurrency0) {
            lower = tick + TICK_SPACING;
            upper = TickMath.maxUsableTick(TICK_SPACING);
            liq = LiquidityAmounts.getLiquidityForAmount0(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), bossAmount
            );
        } else {
            lower = TickMath.minUsableTick(TICK_SPACING);
            upper = tick - TICK_SPACING;
            liq = LiquidityAmounts.getLiquidityForAmount1(
                TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), bossAmount
            );
        }
        lpRouter.modifyLiquidity(key2, ModifyLiquidityParams(lower, upper, int256(uint256(liq)), 0), "");
    }

    // ------------------------------------------------------------------ action builders

    function _A(R3Router.Kind k, address who, uint256 amount) internal pure returns (R3Router.Action memory) {
        return R3Router.Action(k, who, amount, 0, 0);
    }

    function _share(address who, uint256 num, uint256 den) internal pure returns (R3Router.Action memory) {
        return R3Router.Action(R3Router.Kind.TakeBossShare, who, 0, num, den);
    }

    function _1(R3Router.Action memory x) internal pure returns (R3Router.Action[] memory s) {
        s = new R3Router.Action[](1);
        s[0] = x;
    }

    function _2(R3Router.Action memory x, R3Router.Action memory y) internal pure returns (R3Router.Action[] memory s) {
        s = new R3Router.Action[](2);
        s[0] = x;
        s[1] = y;
    }

    function _3(R3Router.Action memory x, R3Router.Action memory y, R3Router.Action memory z)
        internal
        pure
        returns (R3Router.Action[] memory s)
    {
        s = new R3Router.Action[](3);
        s[0] = x;
        s[1] = y;
        s[2] = z;
    }

    function _4(R3Router.Action memory w, R3Router.Action memory x, R3Router.Action memory y, R3Router.Action memory z)
        internal
        pure
        returns (R3Router.Action[] memory s)
    {
        s = new R3Router.Action[](4);
        s[0] = w;
        s[1] = x;
        s[2] = y;
        s[3] = z;
    }

    uint256 internal constant MAX = type(uint256).max;

    // ------------------------------------------------------------------ views

    function _killer(uint64 r) internal view returns (address k) {
        (k,,,,) = hook.results(r);
    }

    function _prize(uint64 r) internal view returns (uint256 p) {
        (,, p,,) = hook.results(r);
    }

    function _pool(uint64 r) internal view returns (uint256 dp) {
        (,,, dp,) = hook.results(r);
    }

    function _wallets() internal view returns (address[] memory w) {
        w = new address[](11);
        w[0] = alice;
        w[1] = bob;
        w[2] = carol;
        w[3] = bundlerEOA;
        w[4] = bundlerWallet;
        w[5] = address(ra);
        w[6] = address(rb);
        w[7] = address(rx);
        w[8] = address(hook);
        w[9] = address(this);
        w[10] = keeper;
    }

    function _sumDamage(uint64 r) internal view returns (uint256 s) {
        address[] memory w = _wallets();
        for (uint256 i = 0; i < w.length; i++) {
            s += hook.damage(r, w[i]);
        }
    }

    function _assertSums() internal view {
        uint64 r = hook.round();
        assertEq(_sumDamage(r), hook.eligibleDamage(r), "open round: eligible == sum of damage held");
        for (uint64 c = 1; c < r; c++) {
            (,,,, uint256 elig) = hook.results(c);
            assertEq(_sumDamage(c), elig, "closed round: snapshot == sum of damage held");
        }
    }

    function _bundle2(address t0, bytes memory c0, address t1, bytes memory c1) internal {
        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        t[0] = t0;
        c[0] = c0;
        t[1] = t1;
        c[1] = c1;
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
    }

    // =================================================================== A. High 1 fix: credit without net damage

    /// @dev Reverse order of the judge's round trip: SELL first (flash, no BOSS owned), then buy the
    /// same BOSS back, then the killing buy, all in one unlock. The sell runs while nothing is pending,
    /// so `_unpend` has nothing to slice; the buy-back then opens a fresh batch whose T_PEND_HP0 is
    /// the HP AFTER the heal. The cap `pd <= T_PEND_HP0 - hp` therefore admits the healed HP as credit.
    /// Fix claim: "the kill credits no more than the HP the transaction removed".
    function test_r3_A1_sellFirstFlash_thenBuyBackAndKill_creditExceedsNetDamage() public {
        buyExactIn(alice, 0.9 ether); // the other players dealt 90% of the boss
        uint256 hpStart = hook.hp();
        uint256 flashBoss = boss.balanceOf(alice); // the BOSS that went out: selling it heals ~all of it

        uint256 snap = vm.snapshotState();
        // Honest kill, for comparison.
        vm.prank(bob, bob);
        ra.run(_2(_A(R3Router.Kind.BuyIn, address(0), 2 ether), _A(R3Router.Kind.TakeBoss, bob, MAX)));
        uint256 honestDmg = hook.damage(1, bob);
        uint256 honestShare = hook.claimableDamage(1, bob);
        uint256 honestAlice = hook.claimableDamage(1, alice);
        uint256 honestCost = 100 ether - _quoteBalance(address(ra));
        vm.revertToState(snap);

        // Attack: flash sell, buy back, kill.
        vm.prank(bob, bob);
        ra.run(
            _4(
                _A(R3Router.Kind.SellIn, address(0), flashBoss),
                _A(R3Router.Kind.BuyBackLast, address(0), 0),
                _A(R3Router.Kind.BuyIn, address(0), 2 ether),
                _A(R3Router.Kind.TakeBoss, bob, MAX)
            )
        );
        uint256 attackCost = 100 ether - _quoteBalance(address(ra));
        assertEq(_killer(1), bob);
        console2.log("A1 hp before bob's tx (net HP he removed):", hpStart);
        console2.log("A1 honest kill: bob damage / bob claimable / alice claimable");
        console2.log(honestDmg, honestShare, honestAlice);
        console2.log("A1 attack: bob damage / bob claimable / alice claimable");
        console2.log(hook.damage(1, bob), hook.claimableDamage(1, bob), hook.claimableDamage(1, alice));
        console2.log("A1 extra quote spent by the attack (fees of the round trip):", attackCost - honestCost);
        console2.log("A1 damage pool:", _pool(1));
        _assertSums();
        assertAccounting();
        assertLe(hook.damage(1, bob), hpStart, "FIX CLAIM: kill credit <= HP the transaction removed");
    }

    /// @dev A1 on a day whose ability makes sells heal 4x (clamped max): the heal costs a quarter of
    /// the volume, so the same inflated credit costs about a quarter of the fees.
    function test_r3_A5_sellFirstFlash_onAHealDay_isCheaper() public {
        stdstore.target(address(hook)).sig("activeAbility()").checked_write(address(new FixedAbility(10_000, 40_000)));
        buyExactIn(alice, 0.9 ether);
        uint256 hpStart = hook.hp();
        uint256 flashBoss = boss.balanceOf(alice) / 4; // a quarter of the BOSS heals everything
        vm.prank(bob, bob);
        ra.run(
            _4(
                _A(R3Router.Kind.SellIn, address(0), flashBoss),
                _A(R3Router.Kind.BuyBackLast, address(0), 0),
                _A(R3Router.Kind.BuyIn, address(0), 2 ether),
                _A(R3Router.Kind.TakeBoss, bob, MAX)
            )
        );
        console2.log("A5 bob damage / hp before / alice damage:", hook.damage(1, bob), hpStart, hook.damage(1, alice));
        console2.log("A5 quote spent by bob's router:", 100 ether - _quoteBalance(address(ra)));
        _assertSums();
        assertAccounting();
        assertLe(hook.damage(1, bob), hpStart, "FIX CLAIM: kill credit <= HP the transaction removed");
    }

    /// @dev A1 split over two senders inside one unlock (SplitHealer heals, SplitHitter buys back and
    /// kills). A fix that re-anchors the cap when the locker changes is bypassed this way; a cap anchored
    /// once per transaction is not.
    function test_r3_A6_sellFirstSplitAcrossTwoSendersInOneUnlock_creditExceedsNetDamage() public {
        SplitHealer healer = new SplitHealer(IPoolManager(address(manager)), key, boss);
        _fundRouter(address(healer.hitter()));
        buyExactIn(alice, 0.9 ether);
        uint256 hpStart = hook.hp();
        uint256 flashBoss = boss.balanceOf(alice);
        vm.prank(bob, bob);
        healer.run(flashBoss, 2 ether, bob);
        assertEq(_killer(1), bob);
        console2.log("A6 bob damage / hp before:", hook.damage(1, bob), hpStart);
        _assertSums();
        assertAccounting();
        assertLe(hook.damage(1, bob), hpStart, "FIX CLAIM: kill credit <= HP the transaction removed");
    }

    /// @dev Same shape, no kill: the arrival path slices pending by BOSS, so a sell-first round trip
    /// that delivers part of the BOSS gives no more than the net damage. Expected PASS.
    function test_r3_A2_sellFirstFlash_noKill_arrivalCreditBoundedByNetDamage() public {
        buyExactIn(alice, 0.5 ether);
        uint256 hp0 = hook.hp();
        uint256 flashBoss = boss.balanceOf(alice);
        vm.prank(bob, bob);
        ra.run(
            _4(
                _A(R3Router.Kind.SellIn, address(0), flashBoss),
                _A(R3Router.Kind.BuyBackLast, address(0), 0),
                _A(R3Router.Kind.BuyIn, address(0), 0.2 ether),
                _A(R3Router.Kind.TakeBoss, bob, MAX)
            )
        );
        uint256 netRemoved = hp0 > hook.hp() ? hp0 - hook.hp() : 0;
        console2.log("A2 bob damage / net HP removed:", hook.damage(1, bob), netRemoved);
        assertLe(hook.damage(1, bob), netRemoved + 2, "arrival credit <= net damage");
        _assertSums();
        assertAccounting();
    }

    /// @dev Judge's order with an exact-OUTPUT flash sell (the shape whose fee is pre-taken in
    /// beforeSwap) between a buy and the kill. Expected PASS: `_unpend` slices by the BOSS paid in and
    /// the cap bounds the rest.
    function test_r3_A3_buyThenExactOutFlashSell_thenKill_creditBounded() public {
        buyExactIn(alice, 0.5 ether);
        uint256 hpStart = hook.hp();
        vm.prank(bob, bob);
        ra.run(
            _4(
                _A(R3Router.Kind.BuyIn, address(0), 0.3 ether),
                _A(R3Router.Kind.SellOut, address(0), 0.25 ether),
                _A(R3Router.Kind.BuyIn, address(0), 2 ether),
                _A(R3Router.Kind.TakeBoss, bob, MAX)
            )
        );
        assertEq(_killer(1), bob);
        assertLe(hook.damage(1, bob), hpStart, "kill credit <= HP the tx removed");
        _assertSums();
        assertAccounting();
    }

    /// @dev Many judge-order round trips with exact-in buys and exact-in sells of the bought BOSS.
    /// Expected PASS.
    function test_r3_A4_manyBuyThenSellRoundTrips_thenKill_creditBounded() public {
        buyExactIn(alice, 0.5 ether);
        uint256 hpStart = hook.hp();
        R3Router.Action[] memory s = new R3Router.Action[](18);
        for (uint256 i = 0; i < 8; i++) {
            s[2 * i] = _A(R3Router.Kind.BuyIn, address(0), 0.4 ether);
            // sell exactly what was just bought: owed BOSS is sold back (flash, no token moves)
            s[2 * i + 1] = _A(R3Router.Kind.SellIn, address(0), 0); // placeholder, replaced below
        }
        // An exact-in sell of "what was bought" needs the amount: use buy-out / sell-in of a fixed BOSS amount.
        uint256 unit = boss.balanceOf(alice) / 2;
        for (uint256 i = 0; i < 8; i++) {
            s[2 * i] = _A(R3Router.Kind.BuyOut, address(0), unit);
            s[2 * i + 1] = _A(R3Router.Kind.SellIn, address(0), unit);
        }
        s[16] = _A(R3Router.Kind.BuyIn, address(0), 2 ether);
        s[17] = _A(R3Router.Kind.TakeBoss, bob, MAX);
        vm.prank(bob, bob);
        ra.run(s);
        assertEq(_killer(1), bob);
        assertLe(hook.damage(1, bob), hpStart, "kill credit <= HP the tx removed");
        _assertSums();
        assertAccounting();
    }

    // =================================================================== B. High 2 fix: credit scoped to the locker

    /// @dev `_scope` runs only in BossHook.afterSwap. BOSS that leaves the PoolManager WITHOUT a swap
    /// on this pool (another locker burning ERC-6909 BOSS claims it holds from earlier) still goes
    /// through `_arrive`, which hands out whatever T_KILL_* / T_PEND_* is left. Same bundle as the
    /// fix's own test (victim's router delivers 40% of the blow to carol, keeps 60% as claims); the
    /// bundler's router then turns ITS OWN old claims into BOSS for its wallet.
    function test_r3_B1_limit_claimsBurnByAnotherLocker_takesTheBlowLeftInside() public {
        // Earlier transaction: the bundler parks old, credit-free BOSS as claims on its router.
        giveBoss(address(rb), 30_000_000 ether);
        vm.prank(bundlerEOA, bundlerEOA);
        rb.run(_1(_A(R3Router.Kind.DepositOwn, address(0), 30_000_000 ether)));
        buyExactIn(alice, 0.8 ether);

        _bundle2(
            address(ra),
            abi.encodeCall(
                ra.run,
                (_3(
                        _A(R3Router.Kind.BuyIn, address(0), 0.4 ether),
                        _share(carol, 2, 5),
                        _A(R3Router.Kind.KeepClaims, address(0), MAX)
                    ))
            ),
            address(rb),
            abi.encodeCall(rb.run, (_1(_A(R3Router.Kind.ClaimsToBoss, bundlerWallet, 30_000_000 ether))))
        );

        console2.log("B1 killer:", _killer(1));
        console2.log("B1 carol / bundlerWallet:", carol, bundlerWallet);
        console2.log("B1 unclaimedKill carol / bundlerWallet:", hook.unclaimedKill(carol), hook.unclaimedKill(bundlerWallet));
        console2.log("B1 damage carol / bundlerWallet:", hook.damage(1, carol), hook.damage(1, bundlerWallet));
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits): BOSS a router leaves inside the PoolManager carries its
        // credit, and the rest of a killing blow, to whoever next takes BOSS out of it in that transaction
        // (from this pool, another BOSS pool or claims) unless another router swaps on this pool first.
        // The hook cannot tell that taker from the router itself. Standard routers take everything out (B4).
        assertEq(_killer(1), bundlerWallet, "documented limit: the next taker carries what was left inside");
        assertGt(hook.damage(1, bundlerWallet), 0, "documented limit: with its share of the blow's credit");
    }

    /// @dev Same bypass with no capital parked: the bundler simply BUYS BOSS on a hookless BOSS pool
    /// (anyone can create one) and takes it to its wallet. No BossHook.afterSwap, no `_scope`.
    function test_r3_B2_limit_buyOnAHooklessBossPool_takesTheBlowLeftInside() public {
        buyExactIn(alice, 0.8 ether);
        _bundle2(
            address(ra),
            abi.encodeCall(
                ra.run,
                (_3(
                        _A(R3Router.Kind.BuyIn, address(0), 0.4 ether),
                        _share(carol, 2, 5),
                        _A(R3Router.Kind.KeepClaims, address(0), MAX)
                    ))
            ),
            address(rx),
            abi.encodeCall(
                rx.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 0.3 ether), _A(R3Router.Kind.TakeBoss, bundlerWallet, MAX)))
            )
        );
        console2.log("B2 killer:", _killer(1));
        console2.log("B2 unclaimedKill carol / bundlerWallet:", hook.unclaimedKill(carol), hook.unclaimedKill(bundlerWallet));
        console2.log("B2 damage carol / bundlerWallet:", hook.damage(1, carol), hook.damage(1, bundlerWallet));
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits): BOSS a router leaves inside the PoolManager carries its
        // credit, and the rest of a killing blow, to whoever next takes BOSS out of it in that transaction
        // (from this pool, another BOSS pool or claims) unless another router swaps on this pool first.
        // The hook cannot tell that taker from the router itself. Standard routers take everything out (B4).
        assertEq(_killer(1), bundlerWallet, "documented limit: the next taker carries what was left inside");
        assertGt(hook.damage(1, bundlerWallet), 0, "documented limit: with its share of the blow's credit");
    }

    /// @dev Pending (no kill): a player's router buys and keeps the BOSS as claims (credit given up by
    /// the rules); another party's hookless-pool buy, later in the same transaction, collects it.
    function test_r3_B3_limit_hooklessBuyByAnotherParty_collectsCreditLeftInside() public {
        _bundle2(
            address(ra),
            abi.encodeCall(
                ra.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 0.3 ether), _A(R3Router.Kind.KeepClaims, address(0), MAX)))
            ),
            address(rx),
            abi.encodeCall(
                rx.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 0.2 ether), _A(R3Router.Kind.TakeBoss, bundlerWallet, MAX)))
            )
        );
        console2.log("B3 damage bundlerWallet (never bought on the game pool):", hook.damage(1, bundlerWallet));
        _assertSums();
        assertAccounting();
        // Documented limit (README, Known limits): BOSS a router leaves inside the PoolManager carries its
        // credit, and the rest of a killing blow, to whoever next takes BOSS out of it in that transaction
        // (from this pool, another BOSS pool or claims) unless another router swaps on this pool first.
        // The hook cannot tell that taker from the router itself. Standard routers take everything out (B4).
        assertGt(hook.damage(1, bundlerWallet), 0, "documented limit: the next taker collects what was left inside");
    }

    /// @dev Calibration: when the victim's router delivers the whole blow (stock router, Universal
    /// Router TAKE_ALL), nothing is left for the bypass. Expected PASS.
    function test_r3_B4_victimDeliversWholeBlow_hooklessBuyAfterwardsGetsNothing() public {
        buyExactIn(alice, 0.2 ether);
        _bundle2(
            address(ra),
            abi.encodeCall(
                ra.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 1.6 ether), _A(R3Router.Kind.TakeBoss, carol, MAX)))
            ),
            address(rx),
            abi.encodeCall(
                rx.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 1 ether), _A(R3Router.Kind.TakeBoss, bundlerWallet, MAX)))
            )
        );
        assertEq(_killer(1), carol);
        assertEq(hook.unclaimedKill(carol), _prize(1));
        assertEq(hook.damage(1, bundlerWallet), 0);
        _assertSums();
        assertAccounting();
    }

    /// @dev A different locker's SWAP on the game pool voids the leftovers (the fix as designed), also
    /// when that swap is an exact-output sell. Expected PASS.
    function test_r3_B5_otherLockersExactOutSell_voidsLeftovers() public {
        buyExactIn(alice, 0.5 ether); // quote liquidity for the exact-out sell
        buyExactIn(carol, 0.1 ether);
        _bundle2(
            address(ra),
            abi.encodeCall(
                ra.run,
                (_3(
                        _A(R3Router.Kind.BuyIn, address(0), 1.6 ether),
                        _share(carol, 2, 5),
                        _A(R3Router.Kind.KeepClaims, address(0), MAX)
                    ))
            ),
            address(rb),
            abi.encodeCall(
                rb.run,
                (_2(_A(R3Router.Kind.SellOut, address(0), 0.01 ether), _A(R3Router.Kind.BuyIn, address(0), 0.5 ether)))
            )
        );
        assertEq(_killer(1), carol);
        _assertSums();
        assertAccounting();
    }

    // =================================================================== C. accounting and liveness

    /// @dev Two kills in one transaction with a sell-first flash, a claim between unlocks and
    /// partial deliveries. Nothing reverts and every book closes.
    function test_r3_C1_twoKillsOneTx_flashAndMidTxClaims_booksClose() public {
        buyExactIn(alice, 0.4 ether);
        uint256 flashBoss = boss.balanceOf(alice) / 2;
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(
            ra.run,
            (_4(
                    _A(R3Router.Kind.SellIn, address(0), flashBoss),
                    _A(R3Router.Kind.BuyBackLast, address(0), 0),
                    _A(R3Router.Kind.BuyIn, address(0), 2 ether),
                    _A(R3Router.Kind.KeepClaims, address(0), MAX)
                ))
        );
        calls[1] = abi.encodeCall(ra.tryClaimDamage, (uint64(1), bob));
        calls[2] = abi.encodeCall(
            ra.run,
            (_4(
                    _A(R3Router.Kind.BuyIn, address(0), 3 ether), // kills boss 2 (HP 1.5)
                    _share(carol, 1, 3),
                    _A(R3Router.Kind.ClaimsToBoss, alice, MAX),
                    _A(R3Router.Kind.TakeBoss, address(hook), MAX)
                ))
        );
        calls[3] = abi.encodeCall(ra.tryClaimKill, (carol));
        vm.prank(bob, bob);
        ra.multi(calls);
        assertEq(hook.round(), 3);
        _assertSums();
        assertAccounting();
        for (uint64 c = 1; c < 3; c++) {
            (,,,, uint256 elig) = hook.results(c);
            uint256 maxHpC = c == 1 ? INITIAL_HP : INITIAL_HP * 3 / 2;
            console2.log("C1 round / eligible / maxHp:", c, elig, maxHpC);
        }
    }

    /// @dev `_recount` scans every wallet that ever held blow BOSS in the transaction. The killer's
    /// custodian sprays 1 wei of the blow to N wallets, then delivers the rest: the delivering
    /// transfer costs O(N). Only blow holders (inside the kill transaction) can grow the list.
    function test_r3_C2_recountGas_growsWithHolders() public {
        uint256 n = 300;
        bytes[] memory calls = new bytes[](n + 2);
        calls[0] = abi.encodeCall(
            ra.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 2 ether), _A(R3Router.Kind.TakeBoss, address(ra), MAX)))
        );
        for (uint256 i = 0; i < n; i++) {
            calls[i + 1] = abi.encodeCall(ra.forward, (address(uint160(0x10000 + i)), 1));
        }
        calls[n + 1] = abi.encodeCall(ra.forwardMeasured, (alice));
        vm.prank(bob, bob);
        ra.multi(calls);
        console2.log("C2 gas of the delivering transfer after N dust holders, N =", n, ":", ra.lastGas());
        assertEq(_killer(1), alice);
        _assertSums();

        // Baseline with no dust holders.
        // (new kill on round 2: HP 1.5)
        bytes[] memory c2 = new bytes[](2);
        c2[0] = abi.encodeCall(
            ra.run, (_2(_A(R3Router.Kind.BuyIn, address(0), 3 ether), _A(R3Router.Kind.TakeBoss, address(ra), MAX)))
        );
        c2[1] = abi.encodeCall(ra.forwardMeasured, (carol));
        vm.prank(bob, bob);
        ra.multi(c2);
        console2.log("C2 gas of the same transfer with no dust holders:", ra.lastGas());
    }

    // =================================================================== D. multi-locker single-transaction fuzz

    struct Step {
        uint256 kind;
        address to;
        uint256 q;
        uint256 b;
        uint256 pct;
    }

    function _stepCall(uint256 r, uint256 unitBoss) internal view returns (address target, bytes memory data) {
        Step memory st;
        st.kind = r % 12;
        R3Router who = (r >> 8) % 3 == 0 ? ra : ((r >> 8) % 3 == 1 ? rb : rx);
        // The hookless pool is shallow: only plain buys there (a partial fill could leave a BOSS debt).
        if (who == rx && (st.kind == 2 || st.kind == 3 || st.kind == 9 || st.kind == 11)) st.kind = 0;
        address[4] memory ws = [alice, bob, carol, bundlerWallet];
        st.to = ws[(r >> 16) % 4];
        st.q = 0.01 ether + (r >> 24) % 2 ether;
        st.b = unitBoss * (1 + (r >> 40) % 200) / 100;
        st.pct = 1 + (r >> 56) % 99;
        target = address(who);
        if (st.kind == 5) return (target, abi.encodeCall(who.forward, (st.to, st.b / 3)));
        if (st.kind == 6) return (target, abi.encodeCall(who.forward, (address(hook), st.b / 5)));
        // (claims go through a router of the game pool: the hookless router has no hook to call)
        if (st.kind == 7) return (address(ra), abi.encodeCall(ra.tryClaimKill, (st.to)));
        if (st.kind == 8) return (address(rb), abi.encodeCall(rb.tryClaimDamage, (uint64(1 + (r >> 48) % 3), st.to)));
        data = abi.encodeCall(who.run, (_script(st, address(who))));
    }

    function _script(Step memory st, address self) internal view returns (R3Router.Action[] memory) {
        R3Router.Kind K;
        if (st.kind == 0) return _2(_A(R3Router.Kind.BuyIn, address(0), st.q), _A(R3Router.Kind.TakeBoss, st.to, MAX));
        if (st.kind == 1) {
            return _2(_A(R3Router.Kind.BuyIn, address(0), st.q), _A(R3Router.Kind.KeepClaims, address(0), MAX));
        }
        if (st.kind == 2) {
            return _4(
                _A(R3Router.Kind.SellIn, address(0), st.b),
                _A(R3Router.Kind.BuyBackLast, address(0), 0),
                _A(R3Router.Kind.BuyIn, address(0), st.q),
                _A(R3Router.Kind.TakeBoss, st.to, MAX)
            );
        }
        if (st.kind == 3) {
            return _4(
                _A(R3Router.Kind.BuyOut, address(0), st.b),
                _A(R3Router.Kind.SellIn, address(0), st.b / 2),
                _share(st.to, 1, 3),
                _A(R3Router.Kind.KeepClaims, address(0), MAX)
            );
        }
        if (st.kind == 4) return _1(_A(R3Router.Kind.ClaimsToBoss, st.to, st.b));
        if (st.kind == 9) {
            return _3(
                _A(R3Router.Kind.BuyIn, address(0), st.q),
                R3Router.Action(R3Router.Kind.SellOwnShare, address(0), 0, st.pct, 100),
                _A(R3Router.Kind.TakeBoss, st.to, MAX)
            );
        }
        if (st.kind == 10) {
            return _3(
                _A(R3Router.Kind.BuyIn, address(0), st.q),
                _A(R3Router.Kind.TakeBoss, self, MAX),
                _A(R3Router.Kind.DepositOwn, address(0), 1)
            );
        }
        K = R3Router.Kind.TakeBoss;
        return _3(_A(R3Router.Kind.BuyIn, address(0), st.q), _share(st.to, 1, 2), _A(K, address(hook), MAX));
    }

    function testFuzz_r3_D1_multiLockerOneTx_neverReverts_booksClose(uint256 seed, uint8 steps, bool relayed)
        public
    {
        buyExactIn(alice, 0.2 ether);
        uint256 unitBoss = boss.balanceOf(alice); // BOSS a 0.2 buy yields: scales BOSS amounts to the pairing
        giveBoss(address(ra), unitBoss / 2);
        giveBoss(address(rb), unitBoss / 2);
        giveBoss(address(rx), unitBoss / 2);
        steps = uint8(bound(steps, 1, 10));
        address[] memory t = new address[](steps);
        bytes[] memory c = new bytes[](steps);
        uint256 r = seed;
        for (uint256 i = 0; i < steps; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            (t[i], c[i]) = _stepCall(r, unitBoss);
        }
        address signer = relayed ? bundlerEOA : alice;
        vm.prank(signer, signer);
        bundle.run(t, c);

        _assertSums();
        assertAccounting();
        uint64 open = hook.round();
        address[] memory w = _wallets();
        for (uint256 i = 0; i < w.length; i++) {
            assertLe(hook.bought(open, w[i]), boss.balanceOf(w[i]), "round BOSS counted never exceeds the balance");
            assertEq(hook.damage(open, address(hook)), 0, "the hook never holds credit");
        }
        for (uint64 cr = 1; cr < open; cr++) {
            (,,,, uint256 elig) = hook.results(cr);
            uint256 sumClaimable;
            for (uint256 i = 0; i < w.length; i++) {
                sumClaimable += hook.claimableDamage(cr, w[i]);
            }
            assertLe(sumClaimable, _pool(cr), "claimable never exceeds the pool");
            assertEq(_sumDamage(cr), elig);
        }
    }
}

contract Review3BossFirstTest is Review3Base {}

contract Review3BossSecondTest is Review3Base {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review3NativeTest is Review3Base {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
