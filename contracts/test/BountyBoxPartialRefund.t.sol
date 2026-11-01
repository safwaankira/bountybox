// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyBox} from "../BountyBox.sol";
import {MockUSDC} from "./BountyBox.t.sol";

/// @dev Refund semantics: the bounty stays Open (expired) until the LAST share is withdrawn; only then Refunded.
contract BountyBoxPartialRefundTest is Test {
    BountyBox internal box;
    MockUSDC internal usdc;

    address internal poster = makeAddr("poster");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal hunter = makeAddr("hunter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant POSTER_SHARE = 100e6;
    uint256 internal constant ALICE_SHARE = 50e6;
    uint256 internal constant BOB_SHARE = 25e6;
    uint256 internal constant MIN = 10_000;
    uint256 internal constant GRACE = 7 days;
    uint64 internal expiry;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBox(address(usdc));
        expiry = uint64(block.timestamp + 7 days);
        address[5] memory who = [poster, alice, bob, hunter, stranger];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000e6);
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers
    function _create3() internal returns (uint256 id) {
        vm.prank(poster);
        id = box.createBounty("Title", "Desc", expiry, POSTER_SHARE);
        vm.prank(alice);
        box.contribute(id, ALICE_SHARE);
        vm.prank(bob);
        box.contribute(id, BOB_SHARE);
    }

    function _status(uint256 id) internal view returns (BountyBox.Status) {
        return box.getBounty(id).status;
    }

    /// @dev On a still-Open expired bounty, mutating entry points revert with the expiry/window errors
    ///      (never BountyNotOpen, because status is still Open).
    function _assertStillOpenExpiredRejects(uint256 id) internal {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
        box.contribute(id, MIN);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
        box.submitClaim(id, "ipfs://late", "");
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
    }

    /// @dev Refund `who`'s `share`, checking event, balance delta, pot, share zeroing and escrow balance.
    function _refundAndCheck(uint256 id, address who, uint256 share, uint256 potAfter) internal {
        uint256 balBefore = usdc.balanceOf(who);
        uint256 boxBefore = usdc.balanceOf(address(box));
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.Refunded(id, who, share);
        vm.prank(who);
        box.refund(id);
        assertEq(usdc.balanceOf(who), balBefore + share, "refunder delta");
        assertEq(usdc.balanceOf(address(box)), boxBefore - share, "escrow delta");
        assertEq(box.getBounty(id).pot, potAfter, "pot");
        assertEq(box.contributionOf(id, who), 0, "share zeroed");
    }

    /// @dev Shared 3-refund flow, caller must have already warped to the refund-open time.
    function _runThreeRefunds(uint256 id) internal {
        uint256 total = POSTER_SHARE + ALICE_SHARE + BOB_SHARE;
        assertEq(box.getBounty(id).pot, total);
        assertEq(usdc.balanceOf(address(box)), total);

        // 1st refund (alice)
        _refundAndCheck(id, alice, ALICE_SHARE, POSTER_SHARE + BOB_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open), "after 1st");
        vm.prank(alice);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        _assertStillOpenExpiredRejects(id);

        // 2nd refund (bob)
        _refundAndCheck(id, bob, BOB_SHARE, POSTER_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open), "after 2nd");
        vm.prank(bob);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        vm.prank(alice);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        _assertStillOpenExpiredRejects(id);

        // 3rd (last) refund (poster)
        _refundAndCheck(id, poster, POSTER_SHARE, 0);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Refunded), "after 3rd");
        assertEq(b.pot, 0);
        assertEq(usdc.balanceOf(address(box)), 0, "contract holds nothing");
        assertFalse(b.hasAccepted);

        // everyone is now NoContribution; mutating calls hit BountyNotOpen
        address[3] memory all = [poster, alice, bob];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(all[i]);
            vm.expectRevert(BountyBox.NoContribution.selector);
            box.refund(id);
        }
        bytes memory err = abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id);
        vm.prank(stranger);
        vm.expectRevert(err);
        box.contribute(id, MIN);
        vm.prank(stranger);
        vm.expectRevert(err);
        box.submitClaim(id, "ipfs://late", "");
        vm.prank(poster);
        vm.expectRevert(err);
        box.acceptClaim(id, 0);
    }

    // ---------------------------------------------------------------- 3 contributors, no claims
    function test_ThreeContributors_RefundOneByOne_NoClaims() public {
        uint256 id = _create3();
        assertEq(box.getBounty(id).contributorCount, 3);
        vm.warp(expiry);
        _runThreeRefunds(id);
    }

    function test_ThreeContributors_RefundOneByOne_LongAfterExpiry() public {
        uint256 id = _create3();
        vm.warp(uint256(expiry) + 365 days);
        _runThreeRefunds(id);
    }

    /// @dev Different order (poster first, bob, alice last): same properties.
    function test_ThreeContributors_PosterRefundsFirst_StillOpen() public {
        uint256 id = _create3();
        vm.warp(expiry);
        _refundAndCheck(id, poster, POSTER_SHARE, ALICE_SHARE + BOB_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));
        _refundAndCheck(id, bob, BOB_SHARE, ALICE_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));
        _refundAndCheck(id, alice, ALICE_SHARE, 0);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_ThreeContributors_NonContributorCannotRefundMidway() public {
        uint256 id = _create3();
        vm.warp(expiry);
        _refundAndCheck(id, alice, ALICE_SHARE, POSTER_SHARE + BOB_SHARE);
        vm.prank(stranger);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        assertEq(box.getBounty(id).pot, POSTER_SHARE + BOB_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));
    }

    // ---------------------------------------------------------------- 3 contributors, claims present (grace)
    function test_ThreeContributors_RefundOneByOne_AfterGraceWindow() public {
        uint256 id = _create3();
        vm.prank(hunter);
        box.submitClaim(id, "ipfs://proof", "n");
        assertEq(box.refundOpensAt(id), uint256(expiry) + GRACE);

        // during grace: refund is closed for everyone, bounty Open and unchanged
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.RefundNotOpen.selector, id, uint256(expiry) + GRACE));
        box.refund(id);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));

        // at settlement time refunds open one by one
        vm.warp(uint256(expiry) + GRACE);
        uint256 total = POSTER_SHARE + ALICE_SHARE + BOB_SHARE;
        assertEq(box.getBounty(id).pot, total);

        _refundAndCheck(id, bob, BOB_SHARE, POSTER_SHARE + ALICE_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open), "after 1st");
        vm.prank(bob);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        _assertStillOpenExpiredRejects(id);
        // claim data is untouched and the claim count still gives the grace-extended settlement time
        assertEq(box.getBounty(id).claimCount, 1);

        _refundAndCheck(id, alice, ALICE_SHARE, POSTER_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open), "after 2nd");
        vm.prank(alice);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        _assertStillOpenExpiredRejects(id);

        _refundAndCheck(id, poster, POSTER_SHARE, 0);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Refunded), "after 3rd");
        assertEq(b.pot, 0);
        assertEq(usdc.balanceOf(address(box)), 0);
        assertFalse(b.hasAccepted);
        assertEq(b.claimCount, 1);

        bytes memory err = abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id);
        vm.prank(poster);
        vm.expectRevert(err);
        box.acceptClaim(id, 0);
        vm.prank(stranger);
        vm.expectRevert(err);
        box.contribute(id, MIN);
        vm.prank(stranger);
        vm.expectRevert(err);
        box.submitClaim(id, "ipfs://late", "");
    }

    /// @dev Grace-window flow that goes the other way: claims present, poster does not accept, the last
    ///      refunder is a non-poster; poster refunds mid-way and the bounty is still Open.
    function test_ThreeContributors_ClaimsPresent_LastRefunderIsNotPoster() public {
        uint256 id = _create3();
        vm.prank(hunter);
        box.submitClaim(id, "ipfs://proof", "");
        vm.warp(uint256(expiry) + GRACE + 1);

        _refundAndCheck(id, poster, POSTER_SHARE, ALICE_SHARE + BOB_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));
        _refundAndCheck(id, alice, ALICE_SHARE, BOB_SHARE);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));
        _refundAndCheck(id, bob, BOB_SHARE, 0);
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    // ---------------------------------------------------------------- isolation between bounties
    function test_PartialRefund_DoesNotTouchOtherBountyEscrow() public {
        uint256 id1 = _create3();
        vm.prank(alice);
        uint256 id2 = box.createBounty("Other", "", expiry, 40e6);
        vm.warp(expiry);
        _refundAndCheck(id1, alice, ALICE_SHARE, POSTER_SHARE + BOB_SHARE);
        assertEq(box.getBounty(id2).pot, 40e6);
        assertEq(uint8(_status(id2)), uint8(BountyBox.Status.Open));
        // alice's share in bounty 2 is independent of her refunded share in bounty 1
        assertEq(box.contributionOf(id2, alice), 40e6);
        assertEq(usdc.balanceOf(address(box)), POSTER_SHARE + BOB_SHARE + 40e6);
    }

    // ---------------------------------------------------------------- fuzz
    /// @dev 2..6 contributors with random shares refund in a random order; status != Refunded until the last
    ///      withdrawal, then Refunded with pot == 0 and an empty escrow. Optionally exercises the grace window.
    function testFuzz_RandomContributorsRandomOrder(
        uint8 nSeed,
        uint256[6] memory shareSeeds,
        uint256 orderSeed,
        bool withClaim
    ) public {
        uint256 n = bound(nSeed, 2, 6);
        address[] memory who = new address[](n);
        uint256[] memory shares = new uint256[](n);
        uint256 id;
        uint256 total;

        for (uint256 i = 0; i < n; i++) {
            shares[i] = bound(shareSeeds[i], MIN, 500e6);
            total += shares[i];
            who[i] = i == 0 ? poster : makeAddr(string(abi.encodePacked("fz", vm.toString(i))));
            if (i != 0) {
                usdc.mint(who[i], shares[i]);
                vm.prank(who[i]);
                usdc.approve(address(box), type(uint256).max);
            }
            if (i == 0) {
                vm.prank(poster);
                id = box.createBounty("Fz", "", expiry, shares[0]);
            } else {
                vm.prank(who[i]);
                box.contribute(id, shares[i]);
            }
        }
        assertEq(box.getBounty(id).pot, total);
        assertEq(box.getBounty(id).contributorCount, n);

        if (withClaim) {
            vm.prank(hunter);
            box.submitClaim(id, "ipfs://p", "");
            vm.warp(uint256(expiry) + GRACE);
        } else {
            vm.warp(expiry);
        }

        // Fisher-Yates permutation of indices driven by orderSeed
        uint256[] memory order = new uint256[](n);
        for (uint256 i = 0; i < n; i++) order[i] = i;
        for (uint256 i = n - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(orderSeed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }

        uint256 remaining = total;
        for (uint256 k = 0; k < n; k++) {
            address who_ = who[order[k]];
            uint256 share = shares[order[k]];
            remaining -= share;
            _refundAndCheck(id, who_, share, remaining);

            if (k < n - 1) {
                assertTrue(_status(id) != BountyBox.Status.Refunded, "Refunded too early");
                assertEq(uint8(_status(id)), uint8(BountyBox.Status.Open));
                assertEq(usdc.balanceOf(address(box)), remaining, "escrow == remaining shares");
                vm.prank(who_);
                vm.expectRevert(BountyBox.NoContribution.selector);
                box.refund(id);
            }
        }
        assertEq(uint8(_status(id)), uint8(BountyBox.Status.Refunded));
        assertEq(box.getBounty(id).pot, 0);
        assertEq(usdc.balanceOf(address(box)), 0);
    }
}
