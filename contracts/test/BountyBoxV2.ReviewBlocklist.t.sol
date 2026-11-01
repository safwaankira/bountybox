// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewBase} from "./BountyBoxV2.ReviewBase.t.sol";
import {BountyBoxV2, BountyBoxV2Errors} from "../BountyBoxV2.sol";
import {ConfigurableUSDC} from "../test-helpers/ConfigurableUSDC.sol";

/// @dev (B) USDC-blocklist behaviour: a blocked refund recipient reverts atomically, nothing changes,
///      other contributors are unaffected, and everything is recoverable after unblocking.
contract ReviewBlocklistTest is ReviewBase {
    uint256 internal constant A_SHARE = 40e6;
    uint256 internal constant B_SHARE = 25e6;
    uint256 internal constant C_SHARE = 10e6;

    struct Snap {
        uint256 pot;
        uint256 contributorCount;
        uint8 status;
        uint256 boxBal;
        uint256 shareA;
        uint256 shareB;
        uint256 shareC;
        uint256 sharePoster;
        bool hasAccepted;
        uint256 paid;
        address winner;
    }

    function _snap(uint256 id) internal view returns (Snap memory s) {
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        s.pot = b.pot;
        s.contributorCount = b.contributorCount;
        s.status = uint8(b.status);
        s.boxBal = usdc.balanceOf(address(box));
        s.shareA = box.contributionOf(id, alice);
        s.shareB = box.contributionOf(id, bob);
        s.shareC = box.contributionOf(id, carol);
        s.sharePoster = box.contributionOf(id, poster);
        s.hasAccepted = b.hasAccepted;
        s.paid = b.paidAmount;
        s.winner = b.winner;
    }

    function _eq(Snap memory a, Snap memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// @dev Poster-mode, no claims (settlement == expiry), 4 contributors.
    function _fourBacker() internal returns (uint256 id) {
        id = _createP();
        _contribute(alice, id, A_SHARE);
        _contribute(bob, id, B_SHARE);
        _contribute(carol, id, C_SHARE);
        _toSettlement(id);
    }

    function _blockedErr(address who) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(ConfigurableUSDC.Blocklisted.selector, who);
    }

    // ---------------------------------------------------- blocked contributor
    function test_BlockedContributorRefundRevertsAndNothingChanges() public {
        uint256 id = _fourBacker();
        usdc.setBlocklisted(bob, true);
        Snap memory before_ = _snap(id);
        uint256 bobBal = usdc.balanceOf(bob);

        vm.prank(bob);
        vm.expectRevert(_blockedErr(bob));
        box.refund(id);

        assertTrue(_eq(before_, _snap(id)), "state unchanged");
        assertEq(usdc.balanceOf(bob), bobBal);
        assertEq(box.contributionOf(id, bob), B_SHARE);
        assertEq(_pots(id), AMT + A_SHARE + B_SHARE + C_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(box.contributorCount(id), 4);
    }

    function test_OthersRefundWhileBlocked_PotDecreasesByExactlyTheirShares() public {
        uint256 id = _fourBacker();
        usdc.setBlocklisted(bob, true);
        uint256 pot = _pots(id);

        _refund(alice, id);
        pot -= A_SHARE;
        assertEq(_pots(id), pot);
        assertEq(box.contributionOf(id, alice), 0);

        _refund(carol, id);
        pot -= C_SHARE;
        assertEq(_pots(id), pot);

        _refund(poster, id);
        pot -= AMT;
        assertEq(_pots(id), pot);

        // only the blocked share remains; bounty is still Open, nothing leaked
        assertEq(pot, B_SHARE);
        assertEq(box.contributionOf(id, bob), B_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(uint8(box.effectiveStatus(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
        assertEq(usdc.balanceOf(address(box)), B_SHARE);
        assertEq(box.contributorCount(id), 4);

        // blocked refund still reverts, and does not disturb the remaining state
        vm.prank(bob);
        vm.expectRevert(_blockedErr(bob));
        box.refund(id);
        assertEq(usdc.balanceOf(address(box)), B_SHARE);
        assertEq(_pots(id), B_SHARE);
    }

    function test_AfterUnblockBlockedContributorRefundReachesRefunded() public {
        uint256 id = _fourBacker();
        usdc.setBlocklisted(bob, true);
        _refund(alice, id);
        _refund(carol, id);
        _refund(poster, id);

        usdc.setBlocklisted(bob, false);
        uint256 bobBal = usdc.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBoxV2.Refunded(id, bob, B_SHARE);
        _refund(bob, id);

        assertEq(usdc.balanceOf(bob), bobBal + B_SHARE);
        assertEq(_pots(id), 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0, "contract fully drained");
        assertEq(box.contributorCount(id), 4);
        assertEq(box.contributionOf(id, bob), 0);
    }

    function test_BlockedContributorWithPendingClaimsUsesGraceWindow() public {
        uint256 id = _createP();
        _contribute(bob, id, B_SHARE);
        _claim(hunter, id);
        usdc.setBlocklisted(bob, true);
        vm.warp(expiry); // refunds are not open yet because a claim extends settlement
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, uint256(expiry) + GRACE));
        box.refund(id);
        _toSettlement(id);
        vm.prank(bob);
        vm.expectRevert(_blockedErr(bob));
        box.refund(id);
        _refund(poster, id);
        assertEq(_pots(id), B_SHARE);
        usdc.setBlocklisted(bob, false);
        _refund(bob, id);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    // ------------------------------------------------------- blocked poster
    function test_BlockedPosterRefundRevertsOthersUnaffectedThenRecoverable() public {
        uint256 id = _fourBacker();
        usdc.setBlocklisted(poster, true);
        Snap memory before_ = _snap(id);

        vm.prank(poster);
        vm.expectRevert(_blockedErr(poster));
        box.refund(id);
        assertTrue(_eq(before_, _snap(id)), "state unchanged");

        _refund(alice, id);
        _refund(bob, id);
        _refund(carol, id);
        assertEq(_pots(id), AMT);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(box.contributionOf(id, poster), AMT);
        assertEq(usdc.balanceOf(address(box)), AMT);

        usdc.setBlocklisted(poster, false);
        _refund(poster, id);
        assertEq(_pots(id), 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_BlockedPosterCanStillAcceptBecauseOutflowIsFromTheContract() public {
        uint256 id = _createP();
        uint256 cid = _claim(hunter, id);
        usdc.setBlocklisted(poster, true);
        uint256 hb = usdc.balanceOf(hunter);
        _accept(id, cid);
        assertEq(usdc.balanceOf(hunter), hb + AMT);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Paid));
    }

    // -------------------------------------------------------- blocked hunter
    function test_BlockedHunterMakesAcceptRevertAtomically_PosterPicksAnother() public {
        uint256 id = _createP();
        uint256 c0 = _claim(hunter, id);
        uint256 c1 = _claim(hunter2, id);
        usdc.setBlocklisted(hunter, true);
        Snap memory before_ = _snap(id);

        vm.prank(poster);
        vm.expectRevert(_blockedErr(hunter));
        box.acceptClaim(id, c0);
        assertTrue(_eq(before_, _snap(id)), "atomic");

        _accept(id, c1);
        assertEq(box.getBounty(id).winner, hunter2);
        assertEq(box.getBounty(id).winningClaimId, c1);
    }

    function test_BlockedHunterOnAIBountyMakesJudgeAcceptRevertAtomically() public {
        uint256 id = _createAI();
        uint256 c0 = _claim(hunter, id);
        uint256 c1 = _claim(hunter2, id);
        usdc.setBlocklisted(hunter, true);
        Snap memory before_ = _snap(id);

        vm.prank(judge);
        vm.expectRevert(_blockedErr(hunter));
        box.judgeAccept(id, c0, keccak256("v"), "ipfs://v");
        assertTrue(_eq(before_, _snap(id)), "atomic");
        (bytes32 h,) = box.getVerdict(id);
        assertEq(h, bytes32(0), "verdict not recorded on rollback");

        _judgeAccept(id, c1);
        assertEq(box.getBounty(id).winner, hunter2);
    }

    // ----------------------------------------------- blocked contract itself
    function test_ContractBlocklisted_AllOutgoingTransfersRevertAtomically_RecoverableAfterUnblock() public {
        uint256 idP = _createP(); // claim -> settles at expiry + GRACE
        uint256 cP = _claim(hunter, idP);
        uint256 idA = _createAI();
        uint256 cA = _claim(hunter2, idA);
        // a claim-less bounty that becomes refundable at expiry
        uint256 idR = _create(alice, "", POSTER_MODE, AMT);
        _contribute(bob, idR, B_SHARE);

        usdc.setBlocklisted(address(box), true);
        Snap memory sP = _snap(idP);
        Snap memory sA = _snap(idA);

        // accepts revert and roll back
        vm.prank(poster);
        vm.expectRevert(_blockedErr(address(box)));
        box.acceptClaim(idP, cP);
        vm.prank(judge);
        vm.expectRevert(_blockedErr(address(box)));
        box.judgeAccept(idA, cA, keccak256("v"), "ipfs://v");
        assertTrue(_eq(sP, _snap(idP)));
        assertTrue(_eq(sA, _snap(idA)));
        (bytes32 vh,) = box.getVerdict(idA);
        assertEq(vh, bytes32(0));

        // incoming deposits are blocked too: nothing is recorded
        uint256 countBefore = box.bountyCount();
        vm.prank(carol);
        vm.expectRevert(_blockedErr(address(box)));
        box.contribute(idP, AMT);
        vm.prank(carol);
        vm.expectRevert(_blockedErr(address(box)));
        box.createBounty("T", "", "", expiry, AMT, POSTER_MODE, false);
        assertEq(box.bountyCount(), countBefore);
        assertEq(box.contributorCount(idP), 1);
        assertEq(box.contributionOf(idP, carol), 0);

        // refunds revert once open
        vm.warp(expiry);
        Snap memory sR = _snap(idR);
        vm.prank(alice);
        vm.expectRevert(_blockedErr(address(box)));
        box.refund(idR);
        vm.prank(bob);
        vm.expectRevert(_blockedErr(address(box)));
        box.refund(idR);
        assertTrue(_eq(sR, _snap(idR)));
        assertEq(box.contributionOf(idR, bob), B_SHARE);
        assertEq(box.contributionOf(idR, alice), AMT);

        // unblock: everything is recoverable (accept windows are still open until expiry + GRACE)
        usdc.setBlocklisted(address(box), false);
        uint256 hb = usdc.balanceOf(hunter);
        _accept(idP, cP);
        assertEq(usdc.balanceOf(hunter), hb + AMT);
        uint256 h2 = usdc.balanceOf(hunter2);
        _judgeAccept(idA, cA);
        assertEq(usdc.balanceOf(hunter2), h2 + AMT);
        _refund(alice, idR);
        _refund(bob, idR);
        assertEq(uint8(_status(idR)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_ContractBlocklisted_RefundsRecoverableAfterUnblockWhenNoAccept() public {
        uint256 id = _fourBacker();
        usdc.setBlocklisted(address(box), true);
        address[4] memory who = [poster, alice, bob, carol];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            vm.expectRevert(_blockedErr(address(box)));
            box.refund(id);
        }
        assertEq(_pots(id), AMT + A_SHARE + B_SHARE + C_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        usdc.setBlocklisted(address(box), false);
        for (uint256 i = 0; i < who.length; i++) {
            _refund(who[i], id);
        }
        assertEq(_pots(id), 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }
}
