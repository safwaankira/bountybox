// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";
import {MockUSDC} from "./BountyBox.t.sol";

/// @dev Shared, directed-random handler for the V2 invariant suites. Actors: 6 users + the GUARDIAN
///      (who contributes, creates, claims, wins, refunds and also calls retireJudge). The judge is funded
///      and approved like a real deployment and keeps trying forbidden actions. Anyone can donate USDC
///      straight to the contract. Violations are recorded in ghost state (reverting inside a handler would
///      be silently swallowed). Counters feed the minimum-exploration assertions.
contract ReviewInvariantHandler is Test {
    uint256 internal constant MIN = 10_000;
    uint256 internal constant K_ACTIVE = 0; // contributable / claimable
    uint256 internal constant K_POSTER_ACCEPT = 1;
    uint256 internal constant K_JUDGE_ACCEPT = 2;
    uint256 internal constant K_REFUNDABLE = 3;

    BountyBoxV2 public box;
    MockUSDC public usdc;
    address public judge;
    address public guardian;
    address public donor = address(0xD0D0);
    uint256 public cap;
    uint256 public unit; // typical amount scale
    uint256 public guardianBias; // % of actor picks that return the guardian
    uint256 public judgeFunding = 10_000e6;

    address[] public actors; // 0..5 users, 6 guardian
    uint256 public maxId;
    uint256 public retiredAtCount;
    uint256 public createAttempts;
    uint256 public bootSeed;
    uint256 public retireAt;
    uint256 public fuzzSuccess; // successful state-changing actions outside the scripted opening
    bool internal scripting;

    bool public violation;
    string public violationWhy;

    // ---- coverage counters (per run: handler state is reset between invariant runs)
    uint256 public calls;
    uint256 public createPoster;
    uint256 public createAI;
    uint256 public contributes;
    uint256 public claims;
    uint256 public posterAccepts;
    uint256 public judgeAccepts;
    uint256 public refunds;
    uint256 public donations;
    uint256 public totalDonated;
    uint256 public retireCalls;
    uint256 public retireOk;
    uint256 public judgeMisuse;
    uint256 public capRejections;
    uint256 public guardianCreates;
    uint256 public guardianContribs;
    uint256 public guardianClaims;
    uint256 public guardianWins;
    uint256 public guardianRefunds;

    constructor(BountyBoxV2 box_, MockUSDC usdc_, address judge_, address guardian_, uint256 unit_, uint256 bias_) {
        box = box_;
        usdc = usdc_;
        judge = judge_;
        guardian = guardian_;
        cap = box_.maxAIPot();
        unit = unit_;
        guardianBias = bias_;
        for (uint256 i = 0; i < 7; i++) {
            address a = i == 6 ? guardian_ : address(uint160(0xB000 + i));
            actors.push(a);
            usdc.mint(a, 1_000_000e6);
            vm.prank(a);
            usdc.approve(address(box_), type(uint256).max);
        }
        // the judge is funded + approved as in a real deployment (it must still never move funds through the box)
        usdc.mint(judge_, judgeFunding);
        vm.prank(judge_);
        usdc.approve(address(box_), type(uint256).max);
    }

    /// @dev Every action first advances the call counter. The first call also runs a scripted opening
    ///      (see _bootstrap) so each run is guaranteed to touch every action class no matter how the fuzzer
    ///      distributes selectors; a scripted retirement lands at a pseudo-random call index. All of the
    ///      remaining calls are free-form fuzzing on top of that state.
    modifier tick() {
        ++calls;
        if (calls == 1) {
            bootSeed = uint256(keccak256(msg.data));
            retireAt = 45 + bootSeed % 45;
            _bootstrap();
        }
        if (calls == retireAt) _retire();
        _;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ------------------------------------------------------------ helpers
    function _flag(string memory why) internal {
        if (!violation) {
            violation = true;
            violationWhy = why;
        }
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        if (err.length >= 4) {
            assembly {
                s := mload(add(err, 32))
            }
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        if (guardianBias > 0 && (s >> 128) % 100 < guardianBias) return guardian;
        return actors[s % actors.length];
    }

    function _rid(uint256 s) internal view returns (uint256) {
        return (s % maxId) + 1;
    }

    function _settle(BountyBoxV2.Bounty memory b) internal pure returns (uint256) {
        return b.claimCount > 0 ? uint256(b.expiry) + 7 days : uint256(b.expiry);
    }

    function _matches(BountyBoxV2.Bounty memory b, uint256 kind) internal view returns (bool) {
        bool isAI = b.judgeMode == BountyBoxV2.JudgeMode.AI;
        bool retired = box.judgeRetired();
        if (kind == K_ACTIVE) {
            return b.status == BountyBoxV2.Status.Open && block.timestamp < b.expiry && !(isAI && retired);
        }
        if (kind == K_POSTER_ACCEPT) {
            return !isAI && b.status == BountyBoxV2.Status.Open && b.claimCount > 0
                && block.timestamp < _settle(b);
        }
        if (kind == K_JUDGE_ACCEPT) {
            return isAI && !retired && b.status == BountyBoxV2.Status.Open && b.claimCount > 0
                && block.timestamp < _settle(b);
        }
        return b.status != BountyBoxV2.Status.Paid && b.pot > 0 && block.timestamp >= _settle(b);
    }

    /// @dev First bounty of `kind` scanning cyclically from `start`; 0 if none.
    function _scan(uint256 start, uint256 kind) internal view returns (uint256) {
        for (uint256 k = 0; k < maxId; k++) {
            uint256 id = ((start % maxId) + k) % maxId + 1;
            if (_matches(box.getBounty(id), kind)) return id;
        }
        return 0;
    }

    function unpaidPots() public view returns (uint256 sum) {
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            BountyBoxV2.Bounty memory b = box.getBounty(id);
            if (b.status != BountyBoxV2.Status.Paid) sum += b.pot;
        }
    }

    function _worldHash() internal view returns (bytes32 h) {
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            h = keccak256(abi.encode(h, box.getBounty(id)));
        }
    }

    // ------------------------------------------------------------ internal ops (shared by fuzz + script)
    function _bump() internal {
        if (!scripting) ++fuzzSuccess;
    }

    function _doCreate(address who, bool ai, uint256 amt, uint256 dur, bool rh) internal returns (uint256 id) {
        bool retired = box.judgeRetired();
        vm.prank(who);
        try box.createBounty(
            "T", "", ai ? "crit" : "", uint64(block.timestamp + dur), amt,
            ai ? BountyBoxV2.JudgeMode.AI : BountyBoxV2.JudgeMode.Poster, rh
        ) returns (uint256 newId) {
            id = newId;
            maxId = newId;
            _bump();
            if (who == guardian) ++guardianCreates;
            if (ai) {
                ++createAI;
                if (retired) _flag("AI create succeeded after retire");
                if (amt > cap) _flag("AI create above cap succeeded");
            } else {
                ++createPoster;
            }
        } catch (bytes memory err) {
            if (ai && !retired && amt > cap) {
                ++capRejections;
                if (_sel(err) != BountyBoxV2.AIPotCapExceeded.selector) _flag("wrong error for over-cap create");
            }
            if (!ai && _sel(err) == BountyBoxV2.AIPotCapExceeded.selector) _flag("poster create hit AI cap");
        }
    }

    function _doContribute(address who, uint256 id, uint256 amt) internal {
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        bool retired = box.judgeRetired();
        vm.prank(who);
        try box.contribute(id, amt) {
            ++contributes;
            _bump();
            if (who == guardian) ++guardianContribs;
            if (b.judgeMode == BountyBoxV2.JudgeMode.AI) {
                if (retired) _flag("AI contribute succeeded after retire");
                if (b.pot + amt > cap) _flag("AI contribute above cap succeeded");
            }
        } catch (bytes memory err) {
            bool active = b.status == BountyBoxV2.Status.Open && block.timestamp < b.expiry;
            if (b.judgeMode == BountyBoxV2.JudgeMode.AI && !retired && active && b.pot + amt > cap) {
                ++capRejections;
                if (_sel(err) != BountyBoxV2.AIPotCapExceeded.selector) _flag("wrong error for over-cap contribute");
            }
            if (b.judgeMode == BountyBoxV2.JudgeMode.Poster && _sel(err) == BountyBoxV2.AIPotCapExceeded.selector) {
                _flag("poster contribute hit AI cap");
            }
        }
    }

    function _doClaim(address who, uint256 id) internal {
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        bool retired = box.judgeRetired();
        vm.prank(who);
        try box.submitClaim(id, "u", "", "h") {
            ++claims;
            _bump();
            if (who == guardian) ++guardianClaims;
            if (retired && b.judgeMode == BountyBoxV2.JudgeMode.AI) _flag("AI claim succeeded after retire");
        } catch {}
    }

    function _doAccept(uint256 id, uint256 c) internal {
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        uint256 cc = b.claimCount == 0 ? 0 : c % b.claimCount;
        address hunterAddr = b.claimCount == 0 ? address(0) : box.getClaim(id, cc).hunter;
        vm.prank(b.poster);
        try box.acceptClaim(id, cc) {
            ++posterAccepts;
            _bump();
            if (b.judgeMode == BountyBoxV2.JudgeMode.AI) _flag("poster accepted an AI bounty");
            if (hunterAddr == guardian) ++guardianWins;
            if (hunterAddr == judge) _flag("judge won a bounty");
        } catch {}
    }

    function _doJudgeAccept(uint256 id, uint256 c, bytes32 h) internal {
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        uint256 cc = b.claimCount == 0 ? 0 : c % b.claimCount;
        address hunterAddr = b.claimCount == 0 ? address(0) : box.getClaim(id, cc).hunter;
        bool retired = box.judgeRetired();
        vm.prank(judge);
        try box.judgeAccept(id, cc, h == bytes32(0) ? bytes32(uint256(1)) : h, "ipfs://v") {
            ++judgeAccepts;
            _bump();
            if (retired) _flag("judgeAccept succeeded after retire");
            if (hunterAddr == guardian) ++guardianWins;
            if (hunterAddr == judge) _flag("judge won a bounty");
        } catch {}
    }

    function _doRefund(address who, uint256 id) internal {
        uint256 share = box.contributionOf(id, who);
        uint256 balBefore = usdc.balanceOf(who);
        vm.prank(who);
        try box.refund(id) {
            ++refunds;
            _bump();
            if (who == guardian) ++guardianRefunds;
            if (usdc.balanceOf(who) != balBefore + share) _flag("refund paid a different amount than the share");
            if (box.contributionOf(id, who) != 0) _flag("share not cleared by refund");
        } catch {}
    }

    function _doDonate(uint256 amt) internal {
        usdc.mint(donor, amt);
        vm.prank(donor);
        usdc.transfer(address(box), amt);
        totalDonated += amt;
        ++donations;
        _bump();
    }

    /// @dev Guardian retires; also proves non-guardians (incl. the judge) never can, and that retirement
    ///      never changes any balance, pot or bounty.
    function _retire() internal {
        uint256 balBefore = usdc.balanceOf(address(box));
        uint256 potsBefore = unpaidPots();
        bytes32 worldBefore = _worldHash();
        bool was = box.judgeRetired();
        vm.prank(guardian);
        try box.retireJudge() {
            ++retireCalls;
            _bump();
            if (was) _flag("second retire succeeded");
            else {
                ++retireOk;
                retiredAtCount = box.bountyCount();
            }
        } catch {
            ++retireCalls;
            if (!was) _flag("guardian retire failed");
        }
        if (usdc.balanceOf(address(box)) != balBefore) _flag("retire changed contract balance");
        if (unpaidPots() != potsBefore) _flag("retire changed pots");
        if (_worldHash() != worldBefore) _flag("retire changed a bounty");
    }

    function _judgeMisuse(uint256 s) internal {
        ++judgeMisuse;
        uint256 id = maxId == 0 ? 1 : _rid(s);
        vm.startPrank(judge);
        try box.contribute(id, MIN) {
            _flag("judge contributed");
        } catch {}
        try box.refund(id) {
            _flag("judge refunded");
        } catch {}
        try box.submitClaim(id, "u", "", "") {
            _flag("judge claimed");
        } catch {}
        try box.createBounty("T", "", "", uint64(block.timestamp + 1 days), MIN, BountyBoxV2.JudgeMode.Poster, false) {
            _flag("judge created a bounty");
        } catch {}
        vm.stopPrank();
    }

    /// @dev Scripted opening, executed once at the start of every run: 3 poster + 3 AI bounties (the guardian
    ///      creates one of each kind), contributions, claims (incl. the guardian's), a donation, a poster
    ///      accept that the guardian WINS, a judgeAccept, a time warp to settlement, refunds (incl. the
    ///      guardian's), and judge misuse. Rotation of actors, amounts and durations derives from the first call.
    function _bootstrap() internal {
        scripting = true;
        uint256 r = bootSeed % 6;
        address u0 = actors[r];
        address u1 = actors[(r + 1) % 6];
        address u2 = actors[(r + 2) % 6];
        address u3 = actors[(r + 3) % 6];
        address u4 = actors[(r + 4) % 6];
        address u5 = actors[(r + 5) % 6];
        uint256 a = unit / 4 + (bootSeed >> 8) % (unit / 4);
        uint256 longDur = 20 days + (bootSeed >> 16) % 20 days;

        uint256 p1 = _doCreate(u0, false, a, longDur, false);
        uint256 ai1 = _doCreate(u1, true, a, longDur, true);
        uint256 p2 = _doCreate(guardian, false, a, 2 days, false);
        uint256 ai2 = _doCreate(u2, true, a, longDur, false);
        uint256 p3 = _doCreate(u3, false, a, longDur, false);
        _doCreate(guardian, true, a, longDur, false);

        _doContribute(guardian, p1, MIN * 3);
        _doContribute(guardian, ai1, MIN * 2);
        _doContribute(u4, p1, MIN * 5);
        _doContribute(u5, ai1, MIN * 7);
        _doContribute(u4, p3, MIN * 4);
        _doContribute(u2, p2, MIN * 6);

        // cap boundary: both over-cap paths must be rejected with AIPotCapExceeded
        _doCreate(u0, true, cap + 1, longDur, false);
        _doContribute(u4, ai2, cap);

        _doClaim(guardian, p1);
        _doClaim(u4, ai1);
        _doClaim(u5, p3);
        _doClaim(u5, ai2);

        _doDonate(7e6);
        _doDonate(1);

        _doAccept(p1, 0); // the guardian wins as a normal hunter
        _doJudgeAccept(ai1, 0, keccak256(abi.encode(bootSeed)));
        _judgeMisuse(bootSeed);

        vm.warp(block.timestamp + 2 days); // p2 has no claims: settles at its expiry
        _doRefund(guardian, p2);
        _doRefund(u2, p2);
        scripting = false;
    }

    // ------------------------------------------------------------ fuzzed actions
    function create(uint256 a, uint256 amt, uint256 dur, bool flip, bool rh) external tick {
        bool ai = (createAttempts++ % 2 == 0);
        if (flip && a % 7 == 0) ai = !ai;
        amt = amt % 4 == 0 ? bound(amt >> 2, unit + 1, 2 * unit) : bound(amt >> 2, MIN, unit / 2);
        dur = dur % 4 == 0 ? bound(dur >> 2, 1 hours, 1 days) : bound(dur >> 2, 1 days, 30 days);
        _doCreate(_actor(a), ai, amt, dur, rh);
    }

    function contribute(uint256 a, uint256 i, uint256 amt) external tick {
        if (maxId == 0) return;
        amt = bound(amt, MIN, unit / 2);
        uint256 id = _scan(i, K_ACTIVE);
        if (id == 0 || a % 8 == 0) id = _rid(i);
        _doContribute(_actor(a), id, amt);
    }

    function claim(uint256 a, uint256 i) external tick {
        if (maxId == 0) return;
        uint256 id = _scan(i, K_ACTIVE);
        if (id == 0 || a % 8 == 0) id = _rid(i);
        address poster_ = box.getBounty(id).poster;
        address who = _actor(a);
        for (uint256 k = 0; k < actors.length && (who == poster_ || box.claimsBy(id, who) >= 3); k++) {
            who = actors[((a % actors.length) + k + 1) % actors.length];
        }
        _doClaim(who, id);
    }

    function accept(uint256 i, uint256 c) external tick {
        if (maxId == 0) return;
        uint256 id = _scan(i, K_POSTER_ACCEPT);
        if (id == 0 || c % 8 == 0) id = _rid(i);
        _doAccept(id, c);
    }

    function judgeAccept(uint256 i, uint256 c, bytes32 h) external tick {
        if (maxId == 0) return;
        uint256 id = _scan(i, K_JUDGE_ACCEPT);
        if (id == 0 || c % 8 == 0) id = _rid(i);
        _doJudgeAccept(id, c, h);
    }

    function refund(uint256 a, uint256 i) external tick {
        if (maxId == 0) return;
        uint256 id = _scan(i, K_REFUNDABLE);
        address who = _actor(a);
        if (id != 0 && a % 8 != 0) {
            for (uint256 k = 0; k < actors.length && box.contributionOf(id, who) == 0; k++) {
                who = actors[((a % actors.length) + k + 1) % actors.length];
            }
        } else {
            id = _rid(i);
        }
        _doRefund(who, id);
    }

    function donate(uint256 amt, uint256 tiny) external tick {
        _doDonate(tiny % 4 == 0 ? 1 : bound(amt, 1, 50e6));
    }

    /// @dev Non-guardians (incl. the judge) never retire; the guardian retires at a random moment once the
    ///      run is under way (a scripted retirement is guaranteed at index `retireAt` regardless).
    function retire(uint256 s) external tick {
        vm.prank(actors[s % 6]);
        try box.retireJudge() {
            _flag("non-guardian retired");
        } catch {}
        vm.prank(judge);
        try box.retireJudge() {
            _flag("judge retired itself");
        } catch {}
        if (calls >= 25 && s % 3 != 0) _retire();
    }

    /// @dev The judge (funded, approved) keeps trying every forbidden entry point.
    function judgeMisuseAttempt(uint256 s) external tick {
        _judgeMisuse(s);
    }

    function warp(uint256 dt) external tick {
        uint256 m = dt % 4;
        if (m >= 2 && maxId > 0) {
            BountyBoxV2.Bounty memory b = box.getBounty(_rid(dt >> 2));
            uint256 target = m == 2 ? _settle(b) : uint256(b.expiry);
            // toward expiry / settlement, but never a giant leap that would wipe every live bounty
            if (target > block.timestamp && target - block.timestamp <= 12 days) {
                vm.warp(target);
                return;
            }
        }
        dt = m == 1 ? bound(dt >> 2, 2 days, 8 days) : bound(dt >> 2, 1 hours, 2 days);
        vm.warp(block.timestamp + dt);
    }

    function logSummary() external view {
        console2.log("calls", calls);
        console2.log("createPoster/createAI", createPoster, createAI);
        console2.log("contributes/claims", contributes, claims);
        console2.log("posterAccepts/judgeAccepts", posterAccepts, judgeAccepts);
        console2.log("refunds/donations", refunds, donations);
        console2.log("retireCalls/retireOk", retireCalls, retireOk);
        console2.log("fuzzSuccess", fuzzSuccess);
    }
}
