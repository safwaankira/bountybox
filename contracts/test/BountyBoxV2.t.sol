// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2} from "../BountyBoxV2.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev Constructor, createBounty, criteria, contribute, submitClaim, handle.
contract BountyBoxV2Test is BountyBoxV2TestBase {
    // ---------------------------------------------------------------- (d) constructor
    function test_Constructor_StoresUsdcAndJudge() public view {
        assertEq(address(box.usdc()), address(usdc));
        assertEq(box.aiJudge(), judge);
        assertEq(box.guardian(), guardian);
        assertEq(box.maxAIPot(), CAP);
        assertFalse(box.judgeRetired());
        assertEq(box.bountyCount(), 0);
        assertEq(box.MIN_AMOUNT(), MIN);
        assertEq(box.GRACE_PERIOD(), GRACE);
        assertEq(box.MAX_DURATION(), 90 days);
        assertEq(box.MAX_CLAIMS_PER_HUNTER(), 3);
    }

    function test_Constructor_RevertsOnZeroUsdc() public {
        vm.expectRevert(BountyBoxV2.ZeroAddress.selector);
        new BountyBoxV2(address(0), judge, guardian, CAP);
    }

    function test_Constructor_RevertsOnZeroJudge() public {
        vm.expectRevert(BountyBoxV2.ZeroAddress.selector);
        new BountyBoxV2(address(usdc), address(0), guardian, CAP);
    }

    function test_Constructor_RevertsOnZeroGuardian() public {
        vm.expectRevert(BountyBoxV2.ZeroAddress.selector);
        new BountyBoxV2(address(usdc), judge, address(0), CAP);
    }

    function test_Constructor_RevertsOnBothZero() public {
        vm.expectRevert(BountyBoxV2.ZeroAddress.selector);
        new BountyBoxV2(address(0), address(0), address(0), CAP);
    }

    function test_Constructor_RevertsWhenJudgeIsToken() public {
        vm.expectRevert(BountyBoxV2.JudgeIsToken.selector);
        new BountyBoxV2(address(usdc), address(usdc), guardian, CAP);
    }

    function test_Constructor_RevertsWhenGuardianIsJudge() public {
        vm.expectRevert(BountyBoxV2.InvalidGuardian.selector);
        new BountyBoxV2(address(usdc), judge, judge, CAP);
    }

    function test_Constructor_RevertsWhenGuardianIsToken() public {
        vm.expectRevert(BountyBoxV2.InvalidGuardian.selector);
        new BountyBoxV2(address(usdc), judge, address(usdc), CAP);
    }

    function test_Constructor_RevertsOnZeroCap() public {
        vm.expectRevert(BountyBoxV2.InvalidMaxAIPot.selector);
        new BountyBoxV2(address(usdc), judge, guardian, 0);
    }

    function test_Constructor_RevertsOnCapBelowMin() public {
        vm.expectRevert(BountyBoxV2.InvalidMaxAIPot.selector);
        new BountyBoxV2(address(usdc), judge, guardian, MIN - 1);
    }

    function test_Constructor_AcceptsCapExactlyMin() public {
        BountyBoxV2 b = new BountyBoxV2(address(usdc), judge, guardian, MIN);
        assertEq(b.maxAIPot(), MIN);
    }

    // ---------------------------------------------------------------- createBounty
    function test_Create_SetsStateAndEscrows() public {
        uint256 before = usdc.balanceOf(poster);
        uint256 id = _createP();
        assertEq(id, 1);
        assertEq(box.bountyCount(), 1);
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(b.id, 1);
        assertEq(b.poster, poster);
        assertEq(b.title, "Title");
        assertEq(b.description, "Desc");
        assertEq(b.criteria, "");
        assertEq(b.expiry, expiry);
        assertEq(b.pot, AMT);
        assertEq(uint8(b.status), uint8(BountyBoxV2.Status.Open));
        assertFalse(b.hasAccepted);
        assertEq(uint8(b.judgeMode), uint8(POSTER_MODE));
        assertFalse(b.requireHandle);
        assertEq(b.winner, address(0));
        assertEq(b.winningClaimId, 0);
        assertEq(b.paidAmount, 0);
        assertEq(b.claimCount, 0);
        assertEq(b.contributorCount, 1);
        assertEq(b.createdAt, block.timestamp);
        assertEq(usdc.balanceOf(poster), before - AMT);
        assertEq(usdc.balanceOf(address(box)), AMT);
        assertEq(box.contributionOf(id, poster), AMT);
    }

    function test_Create_EmitsBountyCreated() public {
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBoxV2.BountyCreated(1, poster, "Title", expiry, AMT, AI_MODE, true);
        vm.prank(poster);
        box.createBounty("Title", "Desc", "crit", expiry, AMT, AI_MODE, true);
    }

    function test_Create_IdsIncrement() public {
        assertEq(_createP(), 1);
        assertEq(_createP(), 2);
        assertEq(box.bountyCount(), 2);
    }

    function test_Create_RevertsInvalidExpiry() public {
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.InvalidExpiry.selector);
        box.createBounty("T", "", "", uint64(block.timestamp), AMT, POSTER_MODE, false);
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.InvalidExpiry.selector);
        box.createBounty("T", "", "", uint64(block.timestamp - 1), AMT, POSTER_MODE, false);
    }

    function test_Create_Exactly90DaysOk() public {
        vm.prank(poster);
        uint256 id = box.createBounty("T", "", "", uint64(block.timestamp + 90 days), AMT, POSTER_MODE, false);
        assertEq(box.getBounty(id).expiry, block.timestamp + 90 days);
    }

    function test_Create_Beyond90DaysReverts() public {
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.ExpiryTooFar.selector);
        box.createBounty("T", "", "", uint64(block.timestamp + 90 days + 1), AMT, POSTER_MODE, false);
    }

    function test_Create_RevertsAmountTooSmall() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AmountTooSmall.selector, MIN - 1));
        box.createBounty("T", "", "", expiry, MIN - 1, POSTER_MODE, false);
    }

    function test_Create_MinAmountOk() public {
        vm.prank(poster);
        uint256 id = box.createBounty("T", "", "", expiry, MIN, POSTER_MODE, false);
        assertEq(box.getBounty(id).pot, MIN);
    }

    function test_Create_TitleLimits() public {
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.InvalidTitleLength.selector);
        box.createBounty("", "", "", expiry, AMT, POSTER_MODE, false);
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.InvalidTitleLength.selector);
        box.createBounty(_str(101), "", "", expiry, AMT, POSTER_MODE, false);
        vm.prank(poster);
        box.createBounty(_str(100), "", "", expiry, AMT, POSTER_MODE, false);
    }

    function test_Create_DescriptionLimits() public {
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.DescriptionTooLong.selector);
        box.createBounty("T", _str(2001), "", expiry, AMT, POSTER_MODE, false);
        vm.prank(poster);
        box.createBounty("T", _str(2000), "", expiry, AMT, POSTER_MODE, false);
    }

    // ---------------------------------------------------------------- (b) criteria / modes
    function test_Criteria_AIEmptyReverts() public {
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.CriteriaRequired.selector);
        box.createBounty("T", "", "", expiry, AMT, AI_MODE, false);
    }

    function test_Criteria_TooLongReverts() public {
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.CriteriaTooLong.selector);
        box.createBounty("T", "", _str(1001), expiry, AMT, AI_MODE, false);
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.CriteriaTooLong.selector);
        box.createBounty("T", "", _str(1001), expiry, AMT, POSTER_MODE, false);
    }

    function test_Criteria_Exactly1000Ok() public {
        uint256 id = _createFull(poster, _str(1000), AI_MODE, false);
        assertEq(bytes(box.getBounty(id).criteria).length, 1000);
    }

    function test_Criteria_PosterModeEmptyOk() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, false);
        assertEq(box.getBounty(id).criteria, "");
    }

    function test_Criteria_PosterModeNonEmptyStored() public {
        uint256 id = _createFull(poster, "poster criteria", POSTER_MODE, false);
        assertEq(box.getBounty(id).criteria, "poster criteria");
    }

    function test_Criteria_StoredAndReturnedForAI() public {
        uint256 id = _createFull(poster, "Must include a demo", AI_MODE, false);
        assertEq(box.getBounty(id).criteria, "Must include a demo");
    }

    function test_ModeAndRequireHandle_StoredAndImmutable() public {
        uint256 id = _createFull(poster, "c", AI_MODE, true);
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.judgeMode), uint8(AI_MODE));
        assertTrue(b.requireHandle);

        // run the bounty through its lifecycle; immutable fields never change
        _contribute(alice, id, AMT);
        _claimH(hunter, id, "@h");
        b = box.getBounty(id);
        assertEq(uint8(b.judgeMode), uint8(AI_MODE));
        assertTrue(b.requireHandle);
        _judgeAccept(id, 0);
        b = box.getBounty(id);
        assertEq(uint8(b.judgeMode), uint8(AI_MODE));
        assertTrue(b.requireHandle);

        uint256 id2 = _createFull(poster, "", POSTER_MODE, false);
        b = box.getBounty(id2);
        assertEq(uint8(b.judgeMode), uint8(POSTER_MODE));
        assertFalse(b.requireHandle);
    }

    // ---------------------------------------------------------------- contribute
    function test_Contribute_SharesAndEvent() public {
        uint256 id = _createP();
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBoxV2.Contributed(id, alice, 50e6, AMT + 50e6);
        _contribute(alice, id, 50e6);
        _contribute(bob, id, 25e6);
        _contribute(alice, id, 10e6);

        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(b.pot, AMT + 85e6);
        assertEq(b.contributorCount, 3);
        assertEq(box.contributionOf(id, poster), AMT);
        assertEq(box.contributionOf(id, alice), 60e6);
        assertEq(box.contributionOf(id, bob), 25e6);
        (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
        assertEq(cs.length, 3);
        assertEq(cs[0], poster);
        assertEq(cs[1], alice);
        assertEq(cs[2], bob);
        assertEq(sh[1], 60e6);
        assertEq(usdc.balanceOf(address(box)), AMT + 85e6);
    }

    function test_Contribute_Reverts() public {
        uint256 id = _createP();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AmountTooSmall.selector, MIN - 1));
        box.contribute(id, MIN - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 99));
        box.contribute(99, AMT);
    }

    function test_Contribute_RevertsAtExpiry() public {
        uint256 id = _createP();
        vm.warp(expiry - 1);
        _contribute(alice, id, AMT); // last second ok
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyExpired.selector, id));
        box.contribute(id, AMT);
    }

    function test_Contribute_RevertsWhenPaid() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.contribute(id, AMT);
    }

    // ---------------------------------------------------------------- submitClaim
    function test_SubmitClaim_StoresAndEmits() public {
        uint256 id = _createP();
        vm.warp(block.timestamp + 5);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBoxV2.ClaimSubmitted(id, 0, hunter, "ipfs://proof", "@hunter");
        uint256 cid = _claimH(hunter, id, "@hunter");
        assertEq(cid, 0);
        assertEq(_claim(hunter2, id), 1);
        BountyBoxV2.Claim memory c = box.getClaim(id, 0);
        assertEq(c.hunter, hunter);
        assertEq(c.proofURL, "ipfs://proof");
        assertEq(c.note, "note");
        assertEq(c.handle, "@hunter");
        assertEq(c.timestamp, block.timestamp);
        assertEq(box.getBounty(id).claimCount, 2);
        assertEq(box.claimsBy(id, hunter), 1);
        assertEq(box.getClaims(id).length, 2);
    }

    function test_SubmitClaim_Limits() public {
        uint256 id = _createP();
        vm.startPrank(hunter);
        vm.expectRevert(BountyBoxV2.InvalidProofURLLength.selector);
        box.submitClaim(id, "", "", "");
        vm.expectRevert(BountyBoxV2.InvalidProofURLLength.selector);
        box.submitClaim(id, _str(501), "", "");
        vm.expectRevert(BountyBoxV2.NoteTooLong.selector);
        box.submitClaim(id, "u", _str(501), "");
        box.submitClaim(id, _str(500), _str(500), "");
        vm.stopPrank();
    }

    function test_SubmitClaim_PosterCannot() public {
        uint256 id = _createP();
        vm.prank(poster);
        vm.expectRevert(BountyBoxV2.PosterCannotSubmitClaim.selector);
        box.submitClaim(id, "u", "", "");
    }

    function test_SubmitClaim_ThreeClaimCap() public {
        uint256 id = _createP();
        _claim(hunter, id);
        _claim(hunter, id);
        _claim(hunter, id);
        assertEq(box.claimsBy(id, hunter), 3);
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.TooManyClaims.selector, id, hunter));
        box.submitClaim(id, "u", "", "");
        // another hunter and another bounty are unaffected
        _claim(hunter2, id);
        uint256 id2 = _createP();
        _claim(hunter, id2);
        assertEq(box.claimsBy(id2, hunter), 1);
    }

    function test_SubmitClaim_RevertsAtExpiryAndNotFound() public {
        uint256 id = _createP();
        vm.warp(expiry);
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyExpired.selector, id));
        box.submitClaim(id, "u", "", "");
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 77));
        box.submitClaim(77, "u", "", "");
    }

    function test_SubmitClaim_RevertsWhenNotOpen() public {
        uint256 id = _createP();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.prank(hunter2);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotOpen.selector, id));
        box.submitClaim(id, "u", "", "");
    }

    // ---------------------------------------------------------------- (c) handle
    function test_Handle_RequiredRejectsEmpty() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, true);
        vm.prank(hunter);
        vm.expectRevert(BountyBoxV2.HandleRequired.selector);
        box.submitClaim(id, "u", "", "");
    }

    function test_Handle_RequiredAcceptsNonEmpty() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, true);
        _claimH(hunter, id, "gh:alice");
        assertEq(box.getClaim(id, 0).handle, "gh:alice");
    }

    function test_Handle_TooLongReverts() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, false);
        vm.prank(hunter);
        vm.expectRevert(BountyBoxV2.HandleTooLong.selector);
        box.submitClaim(id, "u", "", _str(65));
        uint256 id2 = _createFull(poster, "", POSTER_MODE, true);
        vm.prank(hunter);
        vm.expectRevert(BountyBoxV2.HandleTooLong.selector);
        box.submitClaim(id2, "u", "", _str(65));
    }

    function test_Handle_Exactly64Ok() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, true);
        _claimH(hunter, id, _str(64));
        assertEq(bytes(box.getClaim(id, 0).handle).length, 64);
    }

    function test_Handle_NotRequiredAcceptsEmptyAndNonEmpty() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, false);
        _claimH(hunter, id, "");
        _claimH(hunter2, id, "@x");
        assertEq(box.getClaim(id, 0).handle, "");
        assertEq(box.getClaim(id, 1).handle, "@x");
    }

    function test_Handle_EmittedInClaimSubmitted() public {
        uint256 id = _createFull(poster, "c", AI_MODE, true);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBoxV2.ClaimSubmitted(id, 0, hunter, "ipfs://proof", "@emitted");
        _claimH(hunter, id, "@emitted");
    }
}
