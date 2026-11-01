// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewBase} from "./BountyBoxV2.ReviewBase.t.sol";
import {BountyBoxV2, BountyBoxV2Errors} from "../BountyBoxV2.sol";

/// @dev (E) Compromised-judge scenarios and retireJudge / judgeAccept orderings.
contract ReviewJudgeTest is ReviewBase {
    uint256 internal constant MAXPOT = 500e6;
    address internal sybil = makeAddr("attackerAltWallet");

    function setUp() public override {
        super.setUp();
        // redeploy with a tight per-bounty cap so the cap is actually exercised
        box = new BountyBoxV2(address(usdc), judge, guardian, MAXPOT);
        address[7] memory who = [poster, alice, bob, carol, hunter, hunter2, guardian];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
        vm.prank(judge);
        usdc.approve(address(box), type(uint256).max);
    }

    function _honest(uint256 k) internal returns (address a) {
        a = address(uint160(0xE000 + k));
        usdc.mint(a, 2 * MAXPOT);
        vm.prank(a);
        usdc.approve(address(box), type(uint256).max);
    }

    function _retire() internal {
        vm.prank(guardian);
        box.retireJudge();
    }

    function _judgeAcceptExpectRevert(uint256 id, uint256 cid, bytes memory err) internal {
        vm.prank(judge);
        vm.expectRevert(err);
        box.judgeAccept(id, cid, keccak256("verdict"), "ipfs://verdict");
    }

    // ------------------------------------------------- malicious judge key
    function _attack(uint256 n, uint256 seed) internal {
        uint256 judgeBal = usdc.balanceOf(judge);
        uint256 sybilBal = usdc.balanceOf(sybil);
        uint256 sumPots;
        uint256 maxSeen;
        uint256[] memory ids = new uint256[](n);
        uint256[] memory pots = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            uint256 pot = k == 0 ? MAXPOT : bound(uint256(keccak256(abi.encode(seed, k))), MIN, MAXPOT);
            address p = _honest(k);
            vm.prank(p);
            ids[k] = box.createBounty("Honest", "d", "criteria", expiry, pot, AI_MODE, false);
            pots[k] = pot;
            sumPots += pot;
            if (pot > maxSeen) maxSeen = pot;
        }
        // a pot can never be pushed above the cap by anybody, so the exposure per bounty is bounded
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, MAXPOT + MIN, MAXPOT));
        box.contribute(ids[0], MIN);

        uint256 boxBefore = usdc.balanceOf(address(box));
        assertEq(boxBefore, sumPots);

        for (uint256 k = 0; k < n; k++) {
            // attacker submits the claim from the alternate wallet, then awards it with the judge key
            vm.prank(sybil);
            uint256 cid = box.submitClaim(ids[k], "ipfs://junk", "", "");
            _judgeAccept(ids[k], cid);
            BountyBoxV2.Bounty memory b = box.getBounty(ids[k]);
            assertEq(b.paidAmount, pots[k], "each bounty loses exactly its own pot");
            assertLe(b.paidAmount, MAXPOT, "never more than maxAIPot per bounty");
            assertEq(b.winner, sybil);
            assertEq(b.pot, 0);
        }
        // aggregate loss is the sum of the per-bounty pots - the cap is per bounty, NOT aggregate
        assertEq(usdc.balanceOf(sybil) - sybilBal, sumPots, "aggregate loss == sum of pots");
        assertEq(usdc.balanceOf(address(box)), boxBefore - sumPots);
        assertGt(sumPots, MAXPOT, "total exposure exceeds a single cap (documented: cap is per bounty)");
        assertLe(sumPots, n * MAXPOT);
        // the judge address itself never received anything
        assertEq(usdc.balanceOf(judge), judgeBal);
        for (uint256 k = 0; k < n; k++) {
            assertEq(box.contributionOf(ids[k], judge), 0);
        }
    }

    function test_CompromisedJudge_SixBounties_LossBoundedPerBountyAndSumsAcrossBounties() public {
        _attack(6, 1);
    }

    function testFuzz_CompromisedJudge_AggregateLossEqualsSumOfPots(uint8 n, uint256 seed) public {
        _attack(bound(n, 5, 14), seed);
    }

    function test_JudgeAddressCanNeverClaimContributeRefundOrCreate() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        uint256 bal = usdc.balanceOf(judge);

        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotSubmitClaim.selector);
        box.submitClaim(id, "ipfs://x", "", "");
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotContribute.selector);
        box.contribute(id, AMT);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotContribute.selector);
        box.createBounty("T", "", "c", expiry, AMT, AI_MODE, false);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotContribute.selector);
        box.createBounty("T", "", "", expiry, AMT, POSTER_MODE, false);
        _toSettlement(id);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotRefund.selector);
        box.refund(id);
        assertEq(usdc.balanceOf(judge), bal);
        assertEq(box.contributionOf(id, judge), 0);
    }

    function test_JudgeKeyCannotTouchPosterModeOrNonexistentBounties() public {
        uint256 id = _createP();
        uint256 cid = _claim(hunter, id);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.NotAIJudged.selector);
        box.judgeAccept(id, cid, keccak256("v"), "ipfs://v");
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 99));
        box.judgeAccept(99, 0, keccak256("v"), "ipfs://v");
        // nobody else may award an AI bounty
        uint256 ai = _createAI();
        uint256 c2 = _claim(hunter, ai);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.JudgedByAI.selector, ai));
        box.acceptClaim(ai, c2);
        vm.prank(guardian);
        vm.expectRevert(BountyBoxV2.OnlyJudge.selector);
        box.judgeAccept(ai, c2, keccak256("v"), "ipfs://v");
    }

    // ------------------------------------------------------- orderings
    function test_Ordering_JudgeAcceptFirstThenRetire_AwardStands_LaterAwardsRevert() public {
        uint256 x = _createAI();
        uint256 y = _create(alice, "c", AI_MODE, 50e6);
        uint256 cx = _claim(hunter, x);
        uint256 cy = _claim(hunter2, y);

        uint256 hb = usdc.balanceOf(hunter);
        _judgeAccept(x, cx);
        _retire();

        assertEq(usdc.balanceOf(hunter), hb + AMT, "award stands after retirement");
        assertEq(uint8(_status(x)), uint8(BountyBoxV2.Status.Paid));
        assertEq(box.getBounty(x).paidAmount, AMT);
        assertEq(_pots(x), 0);

        _judgeAcceptExpectRevert(y, cy, abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        // the second bounty is intact and refundable at settlement
        assertEq(_pots(y), 50e6);
        _toSettlement(y);
        _refund(alice, y);
        assertEq(uint8(_status(y)), uint8(BountyBoxV2.Status.Refunded));
        // the paid bounty can never be refunded
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, x));
        box.refund(x);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_Ordering_RetireFirstThenJudgeAccept_RevertsAndAllContributorsRefund() public {
        uint256 id = _createAI();
        _contribute(alice, id, 30e6);
        _contribute(bob, id, 20e6);
        uint256 cid = _claim(hunter, id);

        uint256 boxBal = usdc.balanceOf(address(box));
        uint256 pot = _pots(id);
        _retire();
        assertEq(usdc.balanceOf(address(box)), boxBal, "retire moves no funds");
        assertEq(_pots(id), pot, "retire changes no pot");

        _judgeAcceptExpectRevert(id, cid, abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        // rejects every caller too
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        box.judgeAccept(id, cid, keccak256("v"), "ipfs://v");
        assertEq(_pots(id), pot);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));

        // not refundable before settlement (claim exists => expiry + GRACE)
        uint256 opens = box.refundOpensAt(id);
        assertEq(opens, uint256(expiry) + GRACE);
        vm.warp(opens - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, opens));
        box.refund(id);

        vm.warp(opens);
        uint256 ab = usdc.balanceOf(alice);
        uint256 bb = usdc.balanceOf(bob);
        uint256 pb = usdc.balanceOf(poster);
        _refund(alice, id);
        _refund(bob, id);
        _refund(poster, id);
        assertEq(usdc.balanceOf(alice), ab + 30e6);
        assertEq(usdc.balanceOf(bob), bb + 20e6);
        assertEq(usdc.balanceOf(poster), pb + AMT);
        assertEq(_pots(id), 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
        assertEq(usdc.balanceOf(hunter), 10_000e6, "hunter never paid");
    }

    function test_Ordering_SameTimestamp_ClaimJudgeAcceptRetire() public {
        uint256 a = _createAI();
        uint256 b = _create(alice, "c", AI_MODE, 40e6);
        // all in the same block/timestamp: claim -> judgeAccept -> retire
        uint256 ca = _claim(hunter, a);
        uint256 cb = _claim(hunter, b);
        _judgeAccept(a, ca);
        _retire();
        assertEq(uint8(_status(a)), uint8(BountyBoxV2.Status.Paid));
        // same timestamp: retire already happened -> second award reverts
        _judgeAcceptExpectRevert(b, cb, abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        // same timestamp: new AI claim / contribution / creation are rejected
        vm.prank(hunter2);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        box.submitClaim(b, "ipfs://late", "", "");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        box.contribute(b, MIN);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        box.createBounty("T", "", "c", expiry, AMT, AI_MODE, false);
        // poster-mode flows still work in the same timestamp
        uint256 p = _createP();
        uint256 cp = _claim(hunter2, p);
        _accept(p, cp);
        assertEq(uint8(_status(p)), uint8(BountyBoxV2.Status.Paid));
    }

    function test_Ordering_SameTimestamp_RetireBeforeClaimAndAward() public {
        uint256 b = _create(alice, "c", AI_MODE, 40e6);
        _retire();
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        box.submitClaim(b, "ipfs://x", "", "");
        // no claim exists => settlement stays at expiry, refunds open there
        assertEq(box.refundOpensAt(b), expiry);
        vm.warp(expiry);
        _refund(alice, b);
        assertEq(uint8(_status(b)), uint8(BountyBoxV2.Status.Refunded));
    }

    function test_Ordering_PendingClaimAwardedAtBoundaryTimestamps() public {
        uint256 a = _createAI();
        uint256 b = _createAI();
        uint256 c = _createAI();
        uint256 ca = _claim(hunter, a);
        uint256 cb = _claim(hunter, b);
        uint256 cc = _claim(hunter, c);

        // exactly at expiry: contributions/claims closed, but the pending claim can still be awarded
        vm.warp(expiry);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyExpired.selector, a));
        box.contribute(a, MIN);
        _judgeAccept(a, ca);
        assertEq(uint8(_status(a)), uint8(BountyBoxV2.Status.Paid));

        // last second of the grace window: still awardable
        uint256 opens = box.refundOpensAt(b);
        vm.warp(opens - 1);
        _judgeAccept(b, cb);
        assertEq(uint8(_status(b)), uint8(BountyBoxV2.Status.Paid));

        // at settlement time: window closed (even without retirement) and refunds are open
        vm.warp(opens);
        _judgeAcceptExpectRevert(c, cc, abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, c));
        _refund(poster, c);
        assertEq(uint8(_status(c)), uint8(BountyBoxV2.Status.Refunded));
    }

    function test_Ordering_RetireAtLastSecondOfGrace_RefundsOpenNextSecond() public {
        uint256 id = _createAI();
        uint256 cid = _claim(hunter, id);
        uint256 opens = box.refundOpensAt(id);
        vm.warp(opens - 1);
        _retire(); // retire wins the race against a not-yet-sent judgeAccept
        _judgeAcceptExpectRevert(id, cid, abi.encodeWithSelector(BountyBoxV2Errors.JudgeRetired.selector));
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, opens));
        box.refund(id);
        vm.warp(opens);
        _refund(poster, id);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_Ordering_OnlyGuardianRetiresAndOnlyOnce() public {
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.OnlyGuardian.selector);
        box.retireJudge();
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.OnlyGuardian.selector);
        box.retireJudge();
        vm.expectEmit(true, false, false, false, address(box));
        emit BountyBoxV2.JudgeRetired(guardian);
        _retire();
        vm.prank(guardian);
        vm.expectRevert(BountyBoxV2.JudgeAlreadyRetired.selector);
        box.retireJudge();
    }
}
