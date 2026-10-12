// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BossFixture} from "./utils/BossFixture.sol";
import {BossHook} from "../src/BossHook.sol";
import {BossToken} from "../src/BossToken.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Holds no BOSS. Inside the caller's transaction it sells `x` BOSS it does not own and buys
/// them back in the same unlock (v4 flash accounting), paying only the round-trip fees. No BOSS
/// moves, so no credit moves (BossHook.FollowBoss.t.sol).
contract FlashBait is IUnlockCallback {
    IPoolManager internal immutable manager;
    PoolKey internal key;
    bool internal immutable bossIs0;
    MockERC20 internal immutable quote;

    constructor(IPoolManager manager_, PoolKey memory key_, bool bossIs0_, MockERC20 quote_) {
        manager = manager_;
        key = key_;
        bossIs0 = bossIs0_;
        quote = quote_;
    }

    function claimAirdrop(uint256 x) external {
        manager.unlock(abi.encode(x));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        uint256 x = abi.decode(data, (uint256));
        BalanceDelta s = manager.swap(key, SwapParams(bossIs0, -int256(x), _limit(bossIs0)), "");
        BalanceDelta b = manager.swap(key, SwapParams(!bossIs0, int256(x), _limit(!bossIs0)), "");
        int256 quoteNet =
            bossIs0 ? int256(s.amount1()) + int256(b.amount1()) : int256(s.amount0()) + int256(b.amount0());
        Currency q = bossIs0 ? key.currency1 : key.currency0;
        if (quoteNet < 0) {
            manager.sync(q);
            quote.transfer(address(manager), uint256(-quoteNet));
            manager.settle();
        } else if (quoteNet > 0) {
            manager.take(q, address(this), uint256(quoteNet));
        }
        return "";
    }

    function _limit(bool z) internal pure returns (uint160) {
        return z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }
}

/// @dev A contract a player is lured into calling (a fake airdrop claim). It sells its OWN BOSS
/// inside the player's transaction, so tx.origin is the player. Audit 2f96ed9f, finding 1.
contract SellBait {
    PoolSwapTest internal immutable router;
    PoolKey internal key;
    bool internal immutable sellZeroForOne;

    constructor(PoolSwapTest router_, PoolKey memory key_, bool sellZeroForOne_, BossToken boss) {
        router = router_;
        key = key_;
        sellZeroForOne = sellZeroForOne_;
        boss.approve(address(router_), type(uint256).max);
    }

    function claimAirdrop(int256 amountSpecified, uint160 limit) external {
        router.swap(
            key, SwapParams(sellZeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    receive() external payable {}
}

/// @dev Sell forfeits are proportional to the BOSS a wallet hands back to the pool out of the BOSS
/// it bought this round. Who is credited and who forfeits follows the BOSS itself; those identity
/// rules are in BossHook.FollowBoss.t.sol. Runs in both currency orderings.
abstract contract BossForfeitBase is BossFixture {
    address internal label = makeAddr("label");

    function _buyNaming(address actor, uint256 quoteAmount, bytes memory hookData) internal returns (BalanceDelta) {
        bool z = !bossIsCurrency0;
        return _swap(actor, SwapParams(z, -int256(quoteAmount), _limit(z)), hookData, useNative() ? quoteAmount : 0);
    }

    function _bait() internal returns (SellBait bait) {
        bait = new SellBait(swapRouter, key, bossIsCurrency0, boss);
    }

    // ---- Audit finding 1: a dust sell inside the victim's transaction must not wipe the victim

    function test_dustSellInsideVictimTx_leavesVictimDamage() public {
        buyExactIn(alice, 0.5 ether);
        buyExactIn(bob, 0.25 ether);
        SellBait bait = _bait();
        giveBoss(address(bait), 1 ether);
        vm.prank(alice, alice);
        bait.claimAirdrop(-1, _limit(bossIsCurrency0)); // exact-input sell of 1 wei of the bait's BOSS
        assertEq(hook.damage(1, alice), 0.5 ether, "a 1-wei sell costs the victim nothing");
        assertEq(hook.eligibleDamage(1), 0.75 ether, "nobody's share moved");
        assertAccounting();
    }

    // ---- Audit finding 2: a buy can't be credited to a label the signer controls

    function test_buyNamingAnotherAddress_creditsTheBuyer() public {
        _buyNaming(alice, 0.1 ether, abi.encode(label));
        assertEq(hook.damage(1, label), 0, "hookData never names the buyer");
        assertEq(hook.damage(1, alice), 0.1 ether, "the wallet that received the BOSS is credited");
    }

    function test_labelTrick_sellingEverythingStillForfeits() public {
        _buyNaming(alice, 0.5 ether, abi.encode(label));
        buyExactIn(bob, 0.25 ether);
        sellExactIn(alice, boss.balanceOf(alice));
        assertEq(hook.damage(1, label), 0, "the label never held damage");
        assertEq(hook.damage(1, alice), 0, "selling everything forfeits everything");
        assertEq(hook.eligibleDamage(1), 0.25 ether, "only bob stays eligible");
        assertAccounting();
    }

    // ---- The proportional rule

    function test_partialSell_forfeitsProportionally() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        assertEq(hook.bought(1, alice), got, "the buy is counted in BOSS");
        sellExactIn(alice, got / 2);
        assertApproxEqAbs(hook.damage(1, alice), 0.25 ether, 1, "half the BOSS, half the damage");
        assertApproxEqAbs(hook.eligibleDamage(1), 0.25 ether, 1);
        assertEq(hook.bought(1, alice), got - got / 2, "the sell lowers what is left to forfeit");
        sellExactIn(alice, got - got / 2);
        assertEq(hook.damage(1, alice), 0, "the rest goes with the rest");
        assertEq(hook.bought(1, alice), 0);
        assertAccounting();
    }

    function testFuzz_partialSell_forfeitsExactlyTheProportion(uint256 buyAmount, uint256 sellBps) public {
        buyAmount = bound(buyAmount, 0.01 ether, 0.9 ether); // below the 1 IMD HP: no kill
        sellBps = bound(sellBps, 1, 10_000);
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, buyAmount)));
        uint256 sold = got * sellBps / 10_000;
        vm.assume(sold > 0);
        sellExactIn(alice, sold);
        uint256 expected = buyAmount - buyAmount * sold / got;
        assertEq(hook.damage(1, alice), expected, "damage * (1 - sold / bought), rounded for the seller");
        assertEq(hook.eligibleDamage(1), expected);
        assertAccounting();
    }

    function test_partialSellExactOut_forfeitsByBossPaid() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        uint256 paid = uint256(-bossDeltaOf(sellExactOut(alice, 0.1 ether)));
        uint256 expected = 0.5 ether - 0.5 ether * paid / got;
        assertApproxEqAbs(hook.damage(1, alice), expected, 1, "forfeit follows the BOSS paid in");
        assertApproxEqAbs(hook.eligibleDamage(1), expected, 1);
        assertAccounting();
    }

    function test_sellAllBought_forfeitsAll() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.5 ether)));
        sellExactIn(alice, got);
        assertEq(hook.damage(1, alice), 0);
        assertEq(hook.eligibleDamage(1), 0);
        buyExactIn(bob, 2 ether); // bob kills
        vm.expectRevert(BossHook.NothingToClaim.selector);
        hook.claimDamage(1, alice);
        assertAccounting();
    }

    function test_sellAllThenBuyAgain_newDamageCounts() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.2 ether)));
        sellExactIn(alice, got);
        buyExactIn(alice, 0.2 ether);
        assertEq(hook.damage(1, alice), 0.2 ether, "only the new hit");
        assertEq(hook.eligibleDamage(1), 0.2 ether, "and it counts");
        assertAccounting();
    }

    function test_exactOutBuy_countsTheBossReceived() public {
        BalanceDelta d = buyExactOut(alice, 1_000 ether, 1 ether);
        assertEq(hook.bought(1, alice), uint256(bossDeltaOf(d)));
        assertEq(hook.bought(1, alice), 1_000 ether);
    }

    function test_sellAfterTheKill_leavesTheClosedRoundAlone() public {
        uint256 got = uint256(bossDeltaOf(buyExactIn(alice, 0.6 ether)));
        buyExactIn(bob, 0.5 ether); // bob kills, round 1 closes
        sellExactIn(alice, got); // alice sells in round 2
        assertEq(hook.damage(1, alice), 0.6 ether, "the closed round keeps her damage");
        (,,, uint256 dp, uint256 elig) = hook.results(1);
        assertEq(hook.claimableDamage(1, alice), dp * 0.6 ether / elig);
        assertAccounting();
    }

    // ---- Relayed sells, bait sells and flash round trips: see BossHook.FollowBoss.t.sol

    function test_sellInARoundWithoutBuying_forfeitsNothing() public {
        buyExactIn(alice, 1 ether); // kills boss 1, round 2 opens
        buyExactIn(bob, 0.3 ether);
        sellExactIn(alice, 1_000 ether); // alice sells round-1 BOSS, she has no round-2 damage
        assertEq(hook.damage(2, bob), 0.3 ether);
        assertEq(hook.eligibleDamage(2), 0.3 ether);
        assertAccounting();
    }
}

contract BossForfeitBossFirstTest is BossForfeitBase {}

contract BossForfeitBossSecondTest is BossForfeitBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
