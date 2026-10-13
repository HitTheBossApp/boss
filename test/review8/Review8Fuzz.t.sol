// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {R3Router} from "../review3/R3Router.sol";
import {R5Router, ExactForwarder} from "../review5/R5Router.sol";
import {R7Router, FeeWrapper} from "../review7/R7Router.sol";
import {BossToken} from "../../src/BossToken.sol";
import {Review8Base} from "./Review8.t.sol";

/// @dev Fuzz of the eighth review, on the probe hook (BossHook plus transient views; same behaviour). Every
/// transaction is a bundle of random steps (kills, custody lockers with fees, exact and quoted deliveries,
/// planted BOSS, direct-take fee splits, heals before kills, two kills through one custodian, non-locker fee
/// wrappers, sells, claims between unlocks, public sweeps, 1-wei exact-output buys) under a random signer
/// (players, a relayer, a bundler); its last step records the hook's transient kill state. Checks: no Panic,
/// books close, and the prize of the transaction's last kill sits with the majority holder of the blow by the
/// hook's own counts, else with the signer (claims between unlocks and a router that keeps most of the blow
/// excepted, both documented).
abstract contract Review8FuzzBase is Review8Base {
    function useProbe() internal pure override returns (bool) {
        return true;
    }

    struct P {
        uint256 kind;
        R7Router who;
        address to;
        address src;
        uint256 q;
        uint256 b;
        uint256 r;
    }

    function _wsAt(uint256 i) internal view returns (address) {
        address[10] memory ws =
            [alice, bob, carol, dave, address(ra), address(rb), address(fwd), eve, feeCollector, address(wrap)];
        return ws[i % 10];
    }

    function _eoaAt(uint256 i) internal view returns (address) {
        address[5] memory eoas = [alice, bob, carol, dave, eve];
        return eoas[i % 5];
    }

    function _step(uint256 r, uint256 unit, bool withClaims) internal view returns (address, bytes memory) {
        P memory p;
        p.kind = r % 27;
        if (!withClaims && (p.kind == 8 || p.kind == 9)) p.kind = 21;
        p.who = (r >> 8) % 2 == 0 ? ra : rb;
        p.to = _wsAt(r >> 16);
        p.src = _eoaAt(r >> 20);
        p.q = 0.005 ether + (r >> 24) % ((r >> 30) % 2 == 0 ? 0.1 ether : 1.6 ether);
        p.b = unit * (1 + (r >> 40) % 300) / 100;
        p.r = r;
        if (p.kind < 8) return (address(p.who), _stepA(p));
        if (p.kind < 15) return _stepB(p);
        if (p.kind < 21) return (address(p.who), _stepC(p));
        return _stepD(p);
    }

    function _stepA(P memory p) internal view returns (bytes memory) {
        if (p.kind == 0) return _run(_buyTake(p.q, p.to));
        if (p.kind == 1) {
            return _run(
                _3(_A(R3Router.Kind.BuyIn, address(0), p.q), _share(p.to, 1, 3), _A(R3Router.Kind.TakeBoss, address(p.who), MAX))
            );
        }
        if (p.kind == 2) {
            return _run(_2(_A(R3Router.Kind.BuyIn, address(0), p.q), _A(R3Router.Kind.KeepClaims, address(0), MAX)));
        }
        if (p.kind == 3) return _run(_1(_A(R3Router.Kind.ClaimsToBoss, p.to, p.b)));
        if (p.kind == 4) return abi.encodeCall(R3Router.forward, (p.to, p.b));
        if (p.kind == 5) return _pull(p.src, p.to, p.b);
        if (p.kind == 6) {
            return abi.encodeCall(R3Router.multi, (_c(_pull(p.src, address(p.who), p.b), _run(_1(_sellOwn(1, 1))))));
        }
        return _run(_1(_sellOwn(1 + (p.r >> 56) % 100, 200)));
    }

    function _stepB(P memory p) internal view returns (address, bytes memory) {
        address target = address(p.who);
        if (p.kind == 8) {
            return (target, abi.encodeCall(R3Router.tryClaimDamage, (uint64(1 + (p.r >> 48) % 3), _wsAt(p.r >> 52))));
        }
        if (p.kind == 9) return (target, abi.encodeCall(R3Router.tryClaimKill, (_wsAt(p.r >> 52))));
        if (p.kind == 10) return (target, abi.encodeCall(R5Router.toHook, (address(hook), p.b / 4)));
        if (p.kind == 11) {
            return (
                target,
                _run(_3(_A(R3Router.Kind.BuyIn, address(0), p.q), _share(p.to, 1, 2), _A(R3Router.Kind.TakeBoss, address(hook), MAX)))
            );
        }
        if (p.kind == 12) {
            return (
                target,
                _run(
                    _4(
                        _A(R3Router.Kind.SellIn, address(0), p.b / 4),
                        _A(R3Router.Kind.BuyBackLast, address(0), 0),
                        _A(R3Router.Kind.BuyIn, address(0), p.q),
                        _A(R3Router.Kind.TakeBoss, p.to, MAX)
                    )
                )
            );
        }
        if (p.kind == 13) {
            return (target, _run(_2(_A(R3Router.Kind.BuyOut, address(0), p.b), _A(R3Router.Kind.TakeBoss, p.to, MAX))));
        }
        R3Router.Action[] memory s2 =
            _2(_A(R3Router.Kind.BuyIn, address(0), p.q), _A(R3Router.Kind.TakeBoss, address(fwd), MAX));
        return (address(fwd), abi.encodeCall(ExactForwarder.route, (R3Router(payable(address(p.who))), s2, p.to)));
    }

    /// @dev Custody lockers (review 7's shapes).
    function _stepC(P memory p) internal view returns (bytes memory) {
        address self = address(p.who);
        if (p.kind == 15) {
            return abi.encodeCall(
                R3Router.multi, (_c(_run(_buyTake(p.q, self)), _portion(feeCollector, 25), _sweepB(p.to)))
            );
        }
        if (p.kind == 16) return abi.encodeCall(R7Router.buyDeliverExact, (p.q, p.to));
        if (p.kind == 17) return abi.encodeCall(R7Router.buyDeliverQuoted, (p.q, p.to, 9_900, feeCollector));
        if (p.kind == 18) return _pull(p.src, p.who == ra ? address(rb) : address(ra), p.b); // a plant mid-bundle
        if (p.kind == 19) {
            return abi.encodeCall(
                R3Router.multi,
                (_c(_run(_buyTake(p.q, self)), _portion(feeCollector, 25), _portion(dave, 15), _sweepBut(p.to, p.b / 10)))
            );
        }
        return abi.encodeCall(R3Router.multi, (_c(_run(_buyTake(p.q, self)), _run(_1(_sellOwn(1, 3))), _sweepB(p.to))));
    }

    /// @dev This review's shapes.
    function _stepD(P memory p) internal view returns (address, bytes memory) {
        address self = address(p.who);
        if (p.kind == 21) {
            // TAKE_PORTION: a fee of 1..500 bips straight from the PoolManager, then the rest to the player
            uint256 bp = 1 + (p.r >> 60) % 500;
            return (
                self,
                _run(_3(_A(R3Router.Kind.BuyIn, address(0), p.q), _share(feeCollector, bp, 10_000), _A(R3Router.Kind.TakeBoss, p.to, MAX)))
            );
        }
        if (p.kind == 22) {
            // a heal (older BOSS sold) and then a kill with a direct-take fee, one locker
            return (
                self,
                abi.encodeCall(
                    R3Router.multi,
                    (
                        _c(
                            _pull(p.src, self, p.b),
                            _run(_1(_sellOwn(1, 1))),
                            _run(
                                _3(
                                    _A(R3Router.Kind.BuyIn, address(0), p.q),
                                    _share(feeCollector, 2, 100),
                                    _A(R3Router.Kind.TakeBoss, p.to, MAX)
                                )
                            )
                        )
                    )
                )
            );
        }
        if (p.kind == 23) {
            // two buys through one custodian, then a sweep (two kills when both are large)
            uint256 q2 = 0.005 ether + (p.r >> 64) % 2 ether;
            return (
                self,
                abi.encodeCall(R3Router.multi, (_c(_run(_buyTake(p.q, self)), _run(_buyTake(q2, self)), _sweepB(p.to))))
            );
        }
        if (p.kind == 24) {
            // a non-locker fee wrapper: the locker executes to it, it pays 0.25% of its balance and sweeps
            return (
                address(wrap),
                abi.encodeCall(
                    FeeWrapper.route, (R3Router(payable(self)), _buyTake(p.q, address(wrap)), feeCollector, 25, p.to)
                )
            );
        }
        if (p.kind == 25) {
            // a 1..3 wei exact-output buy (damage of a few wei per wei of BOSS) taken to a wallet
            return (self, _run(_2(_A(R3Router.Kind.BuyOut, address(0), 1 + (p.r >> 60) % 3), _A(R3Router.Kind.TakeBoss, p.to, MAX))));
        }
        // a public sweep of a router's BOSS to anyone (another party's operation in the bundle)
        return (self, abi.encodeCall(R7Router.sweep, (address(boss), p.to)));
    }

    function _signer(uint8 sel) internal view returns (address) {
        address[5] memory s = [bob, carol, bundlerEOA, eve, relayer];
        return s[sel % 5];
    }

    struct Out {
        uint256 kills;
        uint256 checked;
        uint256 toSigner;
        uint256 toMajority;
    }

    function _fuzz(uint256 seed, uint8 steps, uint8 signerSel, bool withClaims) internal returns (Out memory o) {
        buyExactIn(alice, 0.2 ether);
        uint256 unit = boss.balanceOf(alice);
        uint256 per = unit;
        uint256 have = boss.balanceOf(address(this));
        if (per * 24 > have) per = have / 24;
        giveBoss(address(ra), per * 4); // plants on the lockers
        giveBoss(address(rb), per * 4);
        giveBoss(address(fwd), per);
        giveBoss(address(wrap), per * 2);
        giveBoss(carol, per * 3);
        giveBoss(dave, per * 3);
        giveBoss(eve, per * 3);
        steps = uint8(bound(steps, 1, 12));
        address[] memory t = new address[](steps + 1);
        bytes[] memory c = new bytes[](steps + 1);
        uint256 r = seed;
        for (uint256 i = 0; i < steps; i++) {
            r = uint256(keccak256(abi.encode(r, i)));
            (t[i], c[i]) = _step(r, unit, withClaims);
        }
        address[] memory ws = _wallets();
        t[steps] = address(rec);
        c[steps] = abi.encodeCall(rec.record, (probe, ws));
        address signer = _signer(signerSel);
        uint64 round0 = hook.round();
        vm.prank(signer, signer);
        lenient.run(t, c);
        bytes[] memory fails = lenient.failures();
        for (uint256 i = 0; i < fails.length; i++) {
            assertFalse(_hasPanic(fails[i]), "a step failed with a Panic");
        }
        _assertSums();
        assertAccounting();
        o.kills = hook.round() - round0;
        if (o.kills > 0) {
            o = _checkPrize(o, signer, ws);
        }
    }

    function _checkPrize(Out memory o, address signer, address[] memory ws) internal returns (Out memory) {
        uint64 kr = rec.kr();
        assertGt(kr, 0, "a kill in this transaction is recorded");
        uint256 total = rec.total();
        address k = _killer(kr);
        uint256 sumHeld;
        address maj;
        for (uint256 i = 0; i < ws.length; i++) {
            address w = ws[i];
            uint256 h = rec.held(w);
            sumHeld += h;
            if (w != address(manager) && w != address(hook)) {
                assertLe(h, boss.balanceOf(w), "blow BOSS held never exceeds the balance");
            } else {
                assertEq(h, 0, "sinks hold no blow");
            }
            assertLe(rec.blowDmg(w), hook.damage(kr, w), "blow credit held never exceeds the credit held");
            if (2 * rec.weight(w) > total) {
                assertEq(maj, address(0), "at most one majority");
                maj = w;
            }
        }
        assertLe(sumHeld, total, "blow BOSS held never exceeds the blow");
        bool claimed = hook.unclaimedKill(k) < _prize(kr);
        if (claimed) return o; // documented: a prize claimed between two unlocks stays paid
        address loc = rec.locker();
        if (k == loc && rec.paid() != 0 && 2 * rec.held(loc) > total) return o; // router keeps most of the blow
        address expected = maj != address(0) ? maj : signer;
        if (k != expected) {
            console2.log("kr / total / killer / expected:", kr, total);
            console2.log(k, expected, maj, signer);
        }
        assertEq(k, expected, "the prize: the majority holder of the blow, else the signer");
        o.checked++;
        if (expected == signer) o.toSigner++;
        else o.toMajority++;
        return o;
    }

    function test_r8_F0_generatorCoverage() public {
        Out memory sum;
        uint256 doubles;
        for (uint256 k = 0; k < 30; k++) {
            uint256 snap = vm.snapshotState();
            Out memory o = _fuzz(uint256(keccak256(abi.encode("cov8", k))), 12, uint8(k), k % 2 == 0);
            sum.kills += o.kills > 0 ? 1 : 0;
            if (o.kills > 1) doubles++;
            sum.checked += o.checked;
            sum.toSigner += o.toSigner;
            sum.toMajority += o.toMajority;
            vm.revertToState(snap);
        }
        console2.log("F0 txs with a kill / two kills / prize checked:", sum.kills, doubles, sum.checked);
        console2.log("F0 prize to the signer / to a majority holder:", sum.toSigner, sum.toMajority);
        assertGt(sum.kills, 10, "the generator closes rounds");
        assertGt(sum.toMajority, 0, "some prizes go to a majority holder");
        assertGt(sum.toSigner, 0, "some stay with the signer");
    }

    function testFuzz_r8_F1_mixed_withClaims_prizeMajorityOrSigner_booksClose(uint256 seed, uint8 steps, uint8 signerSel)
        public
    {
        _fuzz(seed, steps, signerSel, true);
    }

    function testFuzz_r8_F2_mixed_noClaims_prizeMajorityOrSigner_booksClose(uint256 seed, uint8 steps, uint8 signerSel)
        public
    {
        _fuzz(seed, steps, signerSel, false);
    }

    // =================================================================== C. the cap scales the pending BOSS (fix 3)

    /// @dev One transaction: a heal of older BOSS, a buy kept partly inside the PoolManager, a partial take, the
    /// state recorded, the rest taken. Checks: no revert, (pending damage == 0) iff (pending BOSS == 0) except dust,
    /// net credit <= HP removed, credit-carrying BOSS never exceeds what was received, and a later sell of all the
    /// credited BOSS forfeits all of the credit.
    function testFuzz_r8_C1_capScaling_consistent(uint256 healSeed, uint256 qSeed, uint256 num, bool oneWei) public {
        buyExactIn(alice, 0.5 ether);
        uint256 older = boss.balanceOf(alice) * (1 + healSeed % 100) / 100;
        giveBoss(dave, older);
        uint256 q = 1e9 + qSeed % 0.4 ether;
        num = 1 + num % 99;
        uint256 e0 = hook.eligibleDamage(1);
        uint256 h0 = hook.hp();
        R3Router.Action[] memory buy = _3(
            oneWei ? _A(R3Router.Kind.BuyOut, address(0), 1 + qSeed % 3) : _A(R3Router.Kind.BuyIn, address(0), q),
            _share(carol, num, 100),
            _A(R3Router.Kind.KeepClaims, address(0), MAX)
        );
        address[] memory t = new address[](4);
        bytes[] memory c = new bytes[](4);
        t[0] = address(rb);
        c[0] = abi.encodeCall(R3Router.multi, (_c(_pull(dave, address(rb), older), _run(_1(_sellOwn(1, 1))))));
        t[1] = address(ra);
        c[1] = _run(buy);
        address[] memory ws = new address[](0);
        t[2] = address(rec);
        c[2] = abi.encodeCall(rec.record, (probe, ws));
        t[3] = address(ra);
        c[3] = _run(_1(_A(R3Router.Kind.ClaimsToBoss, bob, MAX)));
        vm.prank(bundlerEOA, bundlerEOA);
        bundle.run(t, c);
        if (hook.round() != 1) return;
        uint256 pd = rec.pd();
        uint256 pb = rec.pb();
        assertTrue(pd <= 1 || pb != 0, "pending credit never sits without BOSS (beyond 1 wei)");
        uint256 e1 = hook.eligibleDamage(1);
        uint256 h1 = hook.hp();
        if (e1 > e0) assertLe(e1 - e0, h0 > h1 ? h0 - h1 : 0, "net credit <= HP removed");
        assertLe(hook.bought(1, carol), boss.balanceOf(carol));
        assertLe(hook.bought(1, bob), boss.balanceOf(bob));
        _assertSums();
        assertAccounting();
        uint256 bb = hook.bought(1, bob);
        if (bb > 0 && hook.damage(1, bob) > 0) {
            vm.prank(bob);
            boss.transfer(address(manager), bb); // hand back exactly the credited BOSS (a donation-free sink)
            assertEq(hook.damage(1, bob), 0, "handing back all credited BOSS forfeits all of its credit");
        }
        _assertSums();
    }

    /// @dev The "vice versa" state of fix 3: a 1-wei heal and then a 1-wei exact-output buy (2 wei of damage for
    /// 1 wei of BOSS) taken out: the cap scales the pending BOSS to 0 while 1 wei of damage stays pending. Checks it
    /// is reachable, harmless (no revert, net credit <= HP removed, books close) and only dust.
    function test_r8_C2_pendingDamageWithoutBoss_dustOnly() public {
        buyExactIn(alice, 0.5 ether);
        giveBoss(address(ra), 10_000_000);
        address[] memory ws = new address[](0);
        address[] memory t = new address[](4);
        bytes[] memory c = new bytes[](4);
        t[0] = address(ra);
        c[0] = _run(_1(_A(R3Router.Kind.SellIn, address(0), 500_000)));
        t[1] = address(ra);
        c[1] = _run(_2(_A(R3Router.Kind.BuyOut, address(0), 1), _A(R3Router.Kind.TakeBoss, carol, MAX)));
        t[2] = address(rec);
        c[2] = abi.encodeCall(rec.record, (probe, ws));
        t[3] = address(ra);
        c[3] = _run(_buyTake(0.01 ether, carol));
        uint256 e0 = hook.eligibleDamage(1);
        uint256 h0 = hook.hp();
        vm.prank(carol, carol);
        bundle.run(t, c);
        console2.log("C2 pending damage / BOSS after the 1-wei buy:", rec.pd(), rec.pb());
        uint256 e1 = hook.eligibleDamage(1);
        uint256 h1 = hook.hp();
        console2.log("C2 credit created / HP removed:", e1 - e0, h0 - h1);
        assertLe(e1 - e0, h0 - h1, "net credit <= HP removed");
        assertLe(rec.pd(), 1, "at most dust pending without BOSS");
        _assertSums();
        assertAccounting();
    }
}

contract Review8FuzzBossFirstTest is Review8FuzzBase {}

contract Review8FuzzBossSecondTest is Review8FuzzBase {
    function wantBossIsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract Review8FuzzNativeTest is Review8FuzzBase {
    function useNative() internal pure override returns (bool) {
        return true;
    }
}
