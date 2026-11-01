// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2} from "../BountyBoxV2.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev Poster acceptClaim, grace window, refunds, hasAccepted, effectiveStatus, views.
contract BountyBoxV2PosterTest is BountyBoxV2TestBase {
    // ---------------------------------------------------------------- acceptClaim
    function test_Accept_PaysFullPotToHunter() public {
        uint256 id = _createP();
        _contribute(alice, id, 50e6);
        _contribute(bob, id, 25e6);
        _claim(hunter, id);
        _claim(hunter2, id);
        uint256 before = usdc.balanceOf(hunter2);

        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBoxV2.ClaimAccepted(id, 1, hunter2, AMT + 75e6);
        vm.prank(poster);
        box.acceptClaim(id, 1);

        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(usdc.balanceOf(hunter2), before + AMT + 75e6);
        assertEq(usdc.balanceOf(address(box)), 0);
        assertEq(uint8(b.status), uint8(BountyBoxV2.Status.Paid));
        assertTrue(b.hasAccepted);
        assertEq(b.winner, hunter2);
        assertEq(b.winningClaimId, 1);
        assertEq(b.paidAmount, AMT + 75e6);
        assertEq(b.pot, 0);
        // no verdict recorded for poster mode
        (bytes32 h, string memory u) = box.getVerdict(id);
        assertEq(h, bytes32(0));
        assertEq(u, "");
    }

    function test_Accept_NonPosterReverts() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(stranger);
        vm.expectRevert(BountyBoxV2.OnlyPoster.selector);
        box.acceptClaim(id, 0);
        vm.prank(hunter);
        vm.expectRevert(BountyBoxV2.OnlyPoster.selector);
        box.acceptClaim(id, 0);
    }

    function test_Accept_ClaimNotFound() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.ClaimNotFound.selector, id, 1));
        box.acceptClaim(id, 1);
    }

    function test_Accept_NoClaimsRevertsClaimNotFound() public {
        uint256 id = _createP();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.ClaimNotFound.selector, id, 0));
        box.acceptClaim(id, 0);
    }

    function test_Accept_DoubleAcceptReverts() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_Accept_BountyNotFound() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 5));
        box.acceptClaim(5, 0);
    }

    function test_Accept_AfterFullRefundReverts() public {
        uint256 id = _createP();
        vm.warp(expiry);
        _refund(poster, id);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_Accept_WorksAfterExpiryDuringGrace() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.warp(expiry); // expired, grace running
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Paid));
    }

    function test_Accept_StrictlyBeforeSettlementOk_AtSettlementReverts() public {
        uint256 id = _createP();
        _claim(hunter, id);
        uint256 settle = expiry + GRACE;
        assertEq(box.refundOpensAt(id), settle);

        vm.warp(settle);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);

        vm.warp(settle - 1);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertTrue(box.getBounty(id).hasAccepted);
    }

    function test_Accept_NoClaims_WindowClosedAtExpiry() public {
        uint256 id = _createP();
        assertEq(box.refundOpensAt(id), expiry);
        vm.warp(expiry);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
    }

    // ---------------------------------------------------------------- grace boundaries (refund side)
    function test_Refund_BlockedUntilSettlementWithClaims() public {
        uint256 id = _createP();
        _claim(hunter, id);
        uint256 settle = expiry + GRACE;

        vm.warp(settle - 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, settle));
        box.refund(id);

        vm.warp(settle);
        _refund(poster, id);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
    }

    function test_Refund_AtExpiryWhenNoClaims() public {
        uint256 id = _createP();
        vm.warp(expiry - 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, uint256(expiry)));
        box.refund(id);
        vm.warp(expiry);
        _refund(poster, id);
        assertEq(usdc.balanceOf(poster), 10_000e6);
    }

    function test_Refund_NoOverlapWithAccept() public {
        // for every t around settlement exactly one of accept / refund is possible
        uint256 id = _createP();
        _claim(hunter, id);
        uint256 settle = expiry + GRACE;
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 3; i++) {
            uint256 t = settle - 1 + i; // settle-1, settle, settle+1
            vm.warp(t);
            bool canAccept = _tryAccept(id);
            vm.revertToState(snap);
            vm.warp(t);
            bool canRefund = _tryRefund(id);
            vm.revertToState(snap);
            assertTrue(canAccept != canRefund, "overlap or gap");
            assertEq(canAccept, t < settle);
        }
    }

    function _tryAccept(uint256 id) internal returns (bool ok) {
        vm.prank(poster);
        try box.acceptClaim(id, 0) { ok = true; } catch {}
    }

    function _tryRefund(uint256 id) internal returns (bool ok) {
        vm.prank(poster);
        try box.refund(id) { ok = true; } catch {}
    }

    // ---------------------------------------------------------------- refunds
    function test_Refund_ThreeContributorsOneByOne() public {
        uint256 id = _createP();
        _contribute(alice, id, 30e6);
        _contribute(bob, id, 20e6);
        vm.warp(expiry);

        uint256 pBefore = usdc.balanceOf(poster);
        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);

        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBoxV2.Refunded(id, alice, 30e6);
        _refund(alice, id);
        assertEq(usdc.balanceOf(alice), aBefore + 30e6);
        assertEq(box.getBounty(id).pot, AMT + 20e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(box.contributionOf(id, alice), 0);

        _refund(poster, id);
        assertEq(usdc.balanceOf(poster), pBefore + AMT);
        assertEq(box.getBounty(id).pot, 20e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));

        _refund(bob, id);
        assertEq(usdc.balanceOf(bob), bBefore + 20e6);
        assertEq(box.getBounty(id).pot, 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_Refund_NoContributionAndDoubleRefund() public {
        uint256 id = _createP();
        _contribute(alice, id, AMT);
        vm.warp(expiry);
        vm.prank(stranger);
        vm.expectRevert(BountyBoxV2.NoContribution.selector);
        box.refund(id);
        _refund(alice, id);
        vm.prank(alice);
        vm.expectRevert(BountyBoxV2.NoContribution.selector);
        box.refund(id);
    }

    function test_Refund_RevertsWhenPaid() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.warp(expiry + GRACE + 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.refund(id);
    }

    function test_Refund_BountyNotFound() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 3));
        box.refund(3);
    }

    function test_Refund_FullyRefundedCannotRefundAgain() public {
        uint256 id = _createP();
        vm.warp(expiry);
        _refund(poster, id);
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.NoContribution.selector);
        box.refund(id);
    }

    function test_Refund_ContributionPlusClaimsAfterPartialRefundsStillGraceBound() public {
        // claims submitted before expiry delay refunds for every contributor
        uint256 id = _createP();
        _contribute(alice, id, AMT);
        _claim(hunter, id);
        vm.warp(expiry + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, uint256(expiry) + GRACE));
        box.refund(id);
    }

    // ---------------------------------------------------------------- hasAccepted
    function test_HasAccepted_WinningClaimIdZero() public {
        uint256 id = _createP();
        _claim(hunter, id);
        assertFalse(box.getBounty(id).hasAccepted);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertTrue(b.hasAccepted);
        assertEq(b.winningClaimId, 0);
        assertEq(b.winner, hunter);
    }

    function test_HasAccepted_FalseAfterRefund() public {
        uint256 id = _createP();
        vm.warp(expiry);
        _refund(poster, id);
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertFalse(b.hasAccepted);
        assertEq(b.winner, address(0));
        assertEq(b.paidAmount, 0);
    }

    function test_PosterCannotClaim() public {
        uint256 id = _createP();
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.PosterCannotSubmitClaim.selector);
        box.submitClaim(id, "u", "", "h");
    }

    // ---------------------------------------------------------------- (h) effectiveStatus
    function test_Effective_OpenBeforeExpiry() public {
        uint256 id = _createP();
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Open));
        vm.warp(expiry - 1);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Open));
    }

    function test_Effective_ExpiredAtExpiryEvenIfStoredOpen() public {
        uint256 id = _createP();
        vm.warp(expiry);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        vm.warp(expiry + 100 days);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
    }

    function test_Effective_ExpiredDuringGrace() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.warp(expiry + 1 days);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
    }

    function test_Effective_ExpiredAfterPartialRefunds() public {
        uint256 id = _createP();
        _contribute(alice, id, AMT);
        vm.warp(expiry);
        _refund(alice, id);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
    }

    function test_Effective_PaidAfterAccept() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Paid));
        vm.warp(expiry + 365 days);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Paid));
    }

    function test_Effective_PaidAfterJudgeAccept() public {
        uint256 id = _createAI();
        _claim(hunter, id);
        _judgeAccept(id, 0);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Paid));
    }

    function test_Effective_RefundedAfterLastRefund() public {
        uint256 id = _createP();
        _contribute(alice, id, AMT);
        vm.warp(expiry);
        _refund(alice, id);
        _refund(poster, id);
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Refunded));
    }

    function test_Effective_NotFoundReverts() public {
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 9));
        box.effectiveStatus(9);
    }

    // ---------------------------------------------------------------- views
    function test_Views_RevertOnUnknownBounty() public {
        bytes memory err = abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 42);
        vm.expectRevert(err);
        box.getBounty(42);
        vm.expectRevert(err);
        box.getClaims(42);
        vm.expectRevert(err);
        box.getContributors(42);
        vm.expectRevert(err);
        box.contributionOf(42, alice);
        vm.expectRevert(err);
        box.claimsBy(42, alice);
        vm.expectRevert(err);
        box.refundOpensAt(42);
        vm.expectRevert(err);
        box.getVerdict(42);
    }

    function test_Views_GetClaimOutOfRange() public {
        uint256 id = _createP();
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.ClaimNotFound.selector, id, 0));
        box.getClaim(id, 0);
    }

    function test_Views_ContributorsAfterRefundShowZero() public {
        uint256 id = _createP();
        _contribute(alice, id, 40e6);
        vm.warp(expiry);
        _refund(alice, id);
        (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
        assertEq(cs.length, 2);
        assertEq(sh[0], AMT);
        assertEq(sh[1], 0);
        assertEq(box.getBounty(id).contributorCount, 2);
    }

    function test_Views_RefundOpensAtMovesWithFirstClaim() public {
        uint256 id = _createP();
        assertEq(box.refundOpensAt(id), expiry);
        _claim(hunter, id);
        assertEq(box.refundOpensAt(id), expiry + GRACE);
    }
}
