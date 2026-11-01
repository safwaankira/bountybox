// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2} from "../BountyBoxV2.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev AI mode: judgeAccept, access control, judge powers, judge offline.
contract BountyBoxV2JudgeTest is BountyBoxV2TestBase {
    bytes32 internal constant VH = keccak256("verdict");

    // ---------------------------------------------------------------- (e) access control
    function test_AI_PosterAcceptClaimReverts_JudgedByAI() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.JudgedByAI.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_AI_PosterAcceptClaimRevertsEvenBeforeExpiryWithoutClaims() public {
        uint256 id = _createAI();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.JudgedByAI.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_AI_PosterAcceptClaimRevertsAfterSettlement() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.warp(expiry + GRACE + 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.JudgedByAI.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_AI_StrangerJudgeAcceptReverts_OnlyJudge() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(stranger);
        vm.expectRevert(BountyBoxV2.OnlyJudge.selector);
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_AI_HunterJudgeAcceptReverts_OnlyJudge() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(hunter);
        vm.expectRevert(BountyBoxV2.OnlyJudge.selector);
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_AI_PosterJudgeAcceptReverts_OnlyJudge() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.OnlyJudge.selector);
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_JudgeAcceptOnPosterBountyReverts_NotAIJudged() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.NotAIJudged.selector);
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_PosterJudgeAcceptOnPosterBountyReverts_OnlyJudge() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.OnlyJudge.selector);
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_JudgeAcceptUnknownBounty_NotFound() public {
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 8));
        box.judgeAccept(8, 0, VH, "ipfs://v");
    }

    function test_JudgeAcceptClaimOnAIBounty_JudgedByAI() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.JudgedByAI.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_JudgeAcceptClaimOnPosterBounty_OnlyPoster() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.OnlyPoster.selector);
        box.acceptClaim(id, 0);
    }

    // ---------------------------------------------------------------- judgeAccept happy path
    function test_JudgeAccept_PaysFullMultiContributorPotToClaimHunter() public {
        uint256 id = _createAI();
        _contribute(alice, id, 40e6);
        _contribute(bob, id, 60e6);
        _contribute(carol, id, 15e6);
        _claim(hunter, id);
        _claim(hunter2, id);
        uint256 total = AMT + 115e6;
        uint256 hBefore = usdc.balanceOf(hunter);
        uint256 h2Before = usdc.balanceOf(hunter2);
        uint256 jBefore = usdc.balanceOf(judge);

        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBoxV2.ClaimAccepted(id, 1, hunter2, total);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBoxV2.ClaimJudged(id, 1, hunter2, VH, "ipfs://verdict", total);
        vm.prank(judge);
        box.judgeAccept(id, 1, VH, "ipfs://verdict");

        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(usdc.balanceOf(hunter2), h2Before + total);
        assertEq(usdc.balanceOf(hunter), hBefore);
        assertEq(usdc.balanceOf(judge), jBefore, "judge never receives funds");
        assertEq(usdc.balanceOf(address(box)), 0);
        assertEq(uint8(b.status), uint8(BountyBoxV2.Status.Paid));
        assertTrue(b.hasAccepted);
        assertEq(b.winner, hunter2);
        assertEq(b.winningClaimId, 1);
        assertEq(b.paidAmount, total);
        assertEq(b.pot, 0);
        (bytes32 h, string memory u) = box.getVerdict(id);
        assertEq(h, VH);
        assertEq(u, "ipfs://verdict");
    }

    function test_JudgeAccept_ClaimZero_HasAcceptedTrue() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        _judgeAccept(id, 0);
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertTrue(b.hasAccepted);
        assertEq(b.winningClaimId, 0);
        assertEq(b.winner, hunter);
    }

    function test_GetVerdict_EmptyBeforeJudging() public {
        uint256 id = _createAI();
        (bytes32 h, string memory u) = box.getVerdict(id);
        assertEq(h, bytes32(0));
        assertEq(u, "");
    }

    // ---------------------------------------------------------------- judgeAccept validation
    function test_JudgeAccept_ClaimOutOfRange() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.ClaimNotFound.selector, id, 1));
        box.judgeAccept(id, 1, VH, "ipfs://v");
    }

    function test_JudgeAccept_ZeroVerdictHash() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.EmptyVerdict.selector);
        box.judgeAccept(id, 0, bytes32(0), "ipfs://v");
    }

    function test_JudgeAccept_VerdictURILength() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.startPrank(judge);
        vm.expectRevert(BountyBoxV2.InvalidVerdictURILength.selector);
        box.judgeAccept(id, 0, VH, "");
        vm.expectRevert(BountyBoxV2.InvalidVerdictURILength.selector);
        box.judgeAccept(id, 0, VH, _str(301));
        box.judgeAccept(id, 0, VH, _str(300)); // boundary ok
        vm.stopPrank();
        (, string memory u) = box.getVerdict(id);
        assertEq(bytes(u).length, 300);
    }

    function test_JudgeAccept_DoubleAcceptReverts_BountyNotOpen() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        _claim(hunter2, id);
        _judgeAccept(id, 0);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.judgeAccept(id, 1, VH, "ipfs://v");
    }

    function test_JudgeAccept_DuringGraceSucceeds() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.warp(expiry + GRACE - 1);
        _judgeAccept(id, 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Paid));
    }

    function test_JudgeAccept_AtSettlementReverts_AcceptWindowClosed() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.warp(uint256(expiry) + GRACE);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, id));
        box.judgeAccept(id, 0, VH, "ipfs://v");
        vm.warp(uint256(expiry) + GRACE + 1 days);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, id));
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_JudgeAccept_ExpiredNoClaimsReverts() public {
        uint256 id = _createAI();
        // before expiry: no claim to pick
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.ClaimNotFound.selector, id, 0));
        box.judgeAccept(id, 0, VH, "ipfs://v");
        // at expiry: window closed (no claims => settlement == expiry)
        vm.warp(expiry);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, id));
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    function test_JudgeAccept_FullyRefundedReverts() public {
        uint256 id = _createAI();
        vm.warp(expiry);
        _refund(poster, id);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.judgeAccept(id, 0, VH, "ipfs://v");
    }

    // ---------------------------------------------------------------- (f) judge powers
    function test_Judge_CannotRefund() public {
        uint256 id = _createAI();
        uint256 id2 = _createAI();
        _claim(hunter, id2);
        vm.warp(expiry);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotRefund.selector);
        box.refund(id);
        // also after settlement with claims
        vm.warp(box.refundOpensAt(id2));
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotRefund.selector);
        box.refund(id2);
    }

    function test_Judge_CannotContribute() public {
        uint256 id = _createAI();
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotContribute.selector);
        box.contribute(id, AMT);
    }

    function test_Judge_CannotCreateBounty() public {
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotContribute.selector);
        box.createBounty("T", "", "c", expiry, AMT, AI_MODE, false);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotContribute.selector);
        box.createBounty("T", "", "", expiry, AMT, POSTER_MODE, false);
    }

    function test_Judge_CannotSubmitClaim() public {
        uint256 id = _createAI();
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotSubmitClaim.selector);
        box.submitClaim(id, "u", "", "");
    }

    function test_Judge_HoldsNoShareSoHasNothingToRefund() public {
        uint256 id = _createAI();
        assertEq(box.contributionOf(id, judge), 0);
    }

    function test_Judge_CannotRedirectFunds_RecipientIsClaimHunter() public {
        uint256 id = _createAI();
        _contribute(alice, id, AMT);
        _claim(hunter, id);
        uint256 jBefore = usdc.balanceOf(judge);
        uint256 hBefore = usdc.balanceOf(hunter);
        _judgeAccept(id, 0);
        assertEq(usdc.balanceOf(judge), jBefore);
        assertEq(usdc.balanceOf(hunter), hBefore + 2 * AMT);
        assertEq(box.getBounty(id).winner, box.getClaim(id, 0).hunter);
        // poster / contributors get nothing back
        assertEq(usdc.balanceOf(poster), 10_000e6 - AMT);
        assertEq(usdc.balanceOf(alice), 10_000e6 - AMT);
    }

    function test_Judge_BlocklistedHunterRevertsAtomically_ThenOtherClaimOk() public {
        uint256 id = _createAI();
        _contribute(alice, id, 50e6);
        _claim(hunter, id);
        _claim(hunter2, id);
        uint256 pot = AMT + 50e6;
        vm.mockCallRevert(
            address(usdc), abi.encodeWithSelector(usdc.transfer.selector, hunter, pot), "blocked"
        );

        vm.prank(judge);
        vm.expectRevert();
        box.judgeAccept(id, 0, VH, "ipfs://v");

        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBoxV2.Status.Open));
        assertFalse(b.hasAccepted);
        assertEq(b.pot, pot);
        assertEq(b.paidAmount, 0);
        assertEq(b.winner, address(0));
        assertEq(usdc.balanceOf(address(box)), pot);
        (bytes32 h,) = box.getVerdict(id);
        assertEq(h, bytes32(0));

        // judge picks a different, payable claim
        _judgeAccept(id, 1);
        b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBoxV2.Status.Paid));
        assertEq(b.winner, hunter2);
        assertEq(usdc.balanceOf(hunter2), 10_000e6 + pot);
    }

    function test_Judge_BlocklistedHunterCannotLockFundsRefundsStillWork() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        vm.mockCallRevert(
            address(usdc), abi.encodeWithSelector(usdc.transfer.selector, hunter, AMT), "blocked"
        );
        vm.prank(judge);
        vm.expectRevert();
        box.judgeAccept(id, 0, VH, "ipfs://v");
        vm.warp(expiry + GRACE);
        _refund(poster, id); // poster is not blocked
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
    }

    // ---------------------------------------------------------------- (g) judge offline
    function test_JudgeOffline_WithClaims_ContributorsRefundTheirShares() public {
        uint256 id = _createAI();
        _contribute(alice, id, 30e6);
        _contribute(bob, id, 20e6);
        _claim(hunter, id);

        uint256 settle = uint256(expiry) + GRACE;
        // acceptance window open and refunds closed until settle
        vm.warp(settle - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, settle));
        box.refund(id);

        vm.warp(settle);
        vm.prank(judge);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, id));
        box.judgeAccept(id, 0, VH, "ipfs://v");

        _refund(alice, id);
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
        _refund(bob, id);
        assertEq(usdc.balanceOf(bob), 10_000e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        _refund(poster, id);
        assertEq(usdc.balanceOf(poster), 10_000e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
        assertEq(usdc.balanceOf(hunter), 10_000e6, "hunter got nothing");
    }

    function test_JudgeOffline_NoClaims_RefundsAtExpiry() public {
        uint256 id = _createAI();
        _contribute(alice, id, 30e6);
        vm.warp(expiry - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, uint256(expiry)));
        box.refund(id);
        vm.warp(expiry);
        _refund(alice, id);
        _refund(poster, id);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(usdc.balanceOf(poster), 10_000e6);
    }
}
