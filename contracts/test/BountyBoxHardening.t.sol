// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BountyBox} from "../BountyBox.sol";
import {MockUSDC, Attacker} from "./BountyBox.t.sol";

/// @dev Tests for grace period, max duration, per-hunter claim cap, Refunded status and hasAccepted.
contract BountyBoxHardeningTest is Test {
    BountyBox internal box;
    MockUSDC internal usdc;

    address internal poster = makeAddr("poster");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal hunter = makeAddr("hunter");
    address internal hunter2 = makeAddr("hunter2");

    uint256 internal constant AMT = 100e6;
    uint256 internal constant MIN = 10_000;
    uint256 internal constant GRACE = 7 days;
    uint256 internal constant MAXD = 90 days;
    uint64 internal expiry;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBox(address(usdc));
        expiry = uint64(block.timestamp + 7 days);

        address[5] memory who = [poster, alice, bob, hunter, hunter2];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000e6);
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers
    function _create() internal returns (uint256 id) {
        vm.prank(poster);
        id = box.createBounty("Title", "Desc", expiry, AMT);
    }

    /// @dev Bounty with alice's contribution and one claim from `hunter`.
    function _createClaimed() internal returns (uint256 id) {
        id = _create();
        vm.prank(alice);
        box.contribute(id, 50e6);
        _claim(hunter, id);
    }

    function _claim(address who, uint256 id) internal returns (uint256 cid) {
        vm.prank(who);
        cid = box.submitClaim(id, "ipfs://proof", "note");
    }

    function _accept(uint256 id, uint256 cid) internal {
        vm.prank(poster);
        box.acceptClaim(id, cid);
    }

    function _settle() internal view returns (uint256) {
        return uint256(expiry) + GRACE;
    }

    // ---------------------------------------------------------------- constants
    function test_Constants() public view {
        assertEq(box.GRACE_PERIOD(), 7 days);
        assertEq(box.MAX_DURATION(), 90 days);
        assertEq(box.MAX_CLAIMS_PER_HUNTER(), 3);
    }

    // ---------------------------------------------------------------- (1) grace period
    function test_RefundOpensAt_NoClaimsIsExpiry() public {
        uint256 id = _create();
        assertEq(box.refundOpensAt(id), uint256(expiry));
    }

    function test_RefundOpensAt_WithClaimsIsExpiryPlusGrace() public {
        uint256 id = _create();
        _claim(hunter, id);
        assertEq(box.refundOpensAt(id), _settle());
    }

    function test_RefundOpensAt_RevertsUnknownBounty() public {
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 1));
        box.refundOpensAt(1);
    }

    function test_Grace_AcceptInsideGraceSucceeds() public {
        uint256 id = _createClaimed();
        vm.warp(uint256(expiry) + 3 days);
        uint256 before = usdc.balanceOf(hunter);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.ClaimAccepted(id, 0, hunter, AMT + 50e6);
        _accept(id, 0);
        assertEq(usdc.balanceOf(hunter), before + AMT + 50e6);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Paid));
    }

    function test_Grace_AcceptOneSecondBeforeSettlementSucceeds() public {
        uint256 id = _createClaimed();
        vm.warp(_settle() - 1);
        _accept(id, 0);
        assertEq(box.getBounty(id).winner, hunter);
    }

    function test_Grace_AcceptAtExactSettlementReverts() public {
        uint256 id = _createClaimed();
        vm.warp(_settle());
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_Grace_AcceptAfterSettlementReverts() public {
        uint256 id = _createClaimed();
        vm.warp(_settle() + 30 days);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_Grace_RefundDuringGraceReverts() public {
        uint256 id = _createClaimed();
        uint256[3] memory ts = [uint256(expiry), uint256(expiry) + 3 days, _settle() - 1];
        for (uint256 i = 0; i < ts.length; i++) {
            vm.warp(ts[i]);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(BountyBox.RefundNotOpen.selector, id, _settle()));
            box.refund(id);
        }
        assertEq(box.getBounty(id).pot, AMT + 50e6);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Open));
    }

    function test_Grace_RefundAtExactSettlementWorks() public {
        uint256 id = _createClaimed();
        vm.warp(_settle());
        uint256 before = usdc.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.Refunded(id, alice, 50e6);
        vm.prank(alice);
        box.refund(id);
        assertEq(usdc.balanceOf(alice), before + 50e6);
        assertEq(box.getBounty(id).pot, AMT);
    }

    function test_Grace_NoClaimsRefundsAtExpiryWithoutGrace() public {
        uint256 id = _create();
        vm.warp(uint256(expiry) - 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.RefundNotOpen.selector, id, uint256(expiry)));
        box.refund(id);
        vm.warp(expiry);
        uint256 before = usdc.balanceOf(poster);
        vm.prank(poster);
        box.refund(id);
        assertEq(usdc.balanceOf(poster), before + AMT);
    }

    function test_Grace_ContributeDuringGraceReverts() public {
        uint256 id = _createClaimed();
        uint256[3] memory ts = [uint256(expiry), uint256(expiry) + 3 days, _settle() - 1];
        for (uint256 i = 0; i < ts.length; i++) {
            vm.warp(ts[i]);
            vm.prank(bob);
            vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
            box.contribute(id, AMT);
        }
    }

    function test_Grace_NewClaimDuringGraceReverts() public {
        uint256 id = _createClaimed();
        uint256[3] memory ts = [uint256(expiry), uint256(expiry) + 3 days, _settle() - 1];
        for (uint256 i = 0; i < ts.length; i++) {
            vm.warp(ts[i]);
            vm.prank(hunter2);
            vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
            box.submitClaim(id, "ipfs://late", "");
        }
        assertEq(box.getBounty(id).claimCount, 1);
        assertEq(box.refundOpensAt(id), _settle()); // settlement time cannot shift after expiry
    }

    function test_Grace_NonPosterCannotAcceptInGrace() public {
        uint256 id = _createClaimed();
        vm.warp(uint256(expiry) + 1 days);
        vm.prank(hunter);
        vm.expectRevert(BountyBox.OnlyPoster.selector);
        box.acceptClaim(id, 0);
    }

    function test_Grace_LateClaimAtLastSecondExtendsSettlement() public {
        uint256 id = _create();
        vm.warp(uint256(expiry) - 1);
        _claim(hunter, id);
        assertEq(box.refundOpensAt(id), _settle());
        vm.warp(expiry);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.RefundNotOpen.selector, id, _settle()));
        box.refund(id);
    }

    function test_Grace_PaidBountyStillBlocksRefundAfterSettlement() public {
        uint256 id = _createClaimed();
        vm.warp(uint256(expiry) + 1 days);
        _accept(id, 0);
        vm.warp(_settle() + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.refund(id);
    }

    function test_Grace_ReentrantRefundDuringAcceptBlocked() public {
        usdc.setHook(true);
        Attacker a = new Attacker(box, usdc);
        uint256 id = _create();
        a.claim(id);
        vm.warp(uint256(expiry) + 6 days);
        a.setMode(0, id);
        _accept(id, 0);
        assertTrue(a.entered());
        assertFalse(a.reentrySucceeded());
        assertEq(bytes4(a.reentryRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    /// @dev For any timestamp, accept succeeds iff t < settlement and refund iff t >= settlement; never both.
    function testFuzz_AcceptAndRefundMutuallyExclusive(uint256 dt, bool withClaim) public {
        dt = bound(dt, 0, 120 days);
        uint256 id1 = _create();
        uint256 id2 = _create();
        for (uint256 id = id1; id <= id2; id++) {
            vm.prank(alice);
            box.contribute(id, 50e6);
            if (withClaim) _claim(hunter, id);
        }
        uint256 settle = box.refundOpensAt(id1);
        assertEq(settle, withClaim ? _settle() : uint256(expiry));
        vm.warp(block.timestamp + dt);

        bool acceptOk;
        bool refundOk;
        if (withClaim) {
            vm.prank(poster);
            try box.acceptClaim(id1, 0) { acceptOk = true; } catch {}
        }
        vm.prank(alice);
        try box.refund(id2) { refundOk = true; } catch {}

        assertEq(acceptOk, withClaim && block.timestamp < settle, "accept window");
        assertEq(refundOk, block.timestamp >= settle, "refund window");
        assertFalse(acceptOk && refundOk && id1 == id2);

        // Same bounty: whichever succeeded first must block the other.
        if (acceptOk) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id1));
            box.refund(id1);
        }
        if (refundOk && withClaim) {
            vm.prank(poster);
            vm.expectRevert();
            box.acceptClaim(id2, 0);
        }
    }

    // ---------------------------------------------------------------- (2) max duration
    function test_Create_ExactlyMaxDurationAllowed() public {
        vm.prank(poster);
        uint256 id = box.createBounty("T", "", uint64(block.timestamp + MAXD), AMT);
        assertEq(box.getBounty(id).expiry, block.timestamp + MAXD);
    }

    function test_Create_BeyondMaxDurationReverts() public {
        vm.prank(poster);
        vm.expectRevert(BountyBox.ExpiryTooFar.selector);
        box.createBounty("T", "", uint64(block.timestamp + MAXD + 1), AMT);
        assertEq(box.bountyCount(), 0);
    }

    function testFuzz_Create_DurationBoundary(uint64 dur) public {
        dur = uint64(bound(dur, 1, 365 days));
        vm.prank(poster);
        if (dur > MAXD) vm.expectRevert(BountyBox.ExpiryTooFar.selector);
        box.createBounty("T", "", uint64(block.timestamp) + dur, AMT);
    }

    // ---------------------------------------------------------------- (3) claim cap
    function test_Claims_FourthClaimBySameHunterReverts() public {
        uint256 id = _create();
        for (uint256 i = 0; i < 3; i++) {
            assertEq(_claim(hunter, id), i);
        }
        assertEq(box.claimsBy(id, hunter), 3);
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.TooManyClaims.selector, id, hunter));
        box.submitClaim(id, "ipfs://4", "");
        assertEq(box.claimsBy(id, hunter), 3);
        assertEq(box.getBounty(id).claimCount, 3);
    }

    function test_Claims_DifferentHuntersIndependent() public {
        uint256 id = _create();
        for (uint256 i = 0; i < 3; i++) _claim(hunter, id);
        _claim(hunter2, id);
        assertEq(box.claimsBy(id, hunter), 3);
        assertEq(box.claimsBy(id, hunter2), 1);
        assertEq(box.getBounty(id).claimCount, 4);
    }

    function test_Claims_DifferentBountiesIndependent() public {
        uint256 id1 = _create();
        uint256 id2 = _create();
        for (uint256 i = 0; i < 3; i++) _claim(hunter, id1);
        _claim(hunter, id2);
        assertEq(box.claimsBy(id1, hunter), 3);
        assertEq(box.claimsBy(id2, hunter), 1);
        assertEq(box.claimsBy(id2, hunter2), 0);
    }

    function test_Claims_FailedClaimDoesNotConsumeQuota() public {
        uint256 id = _create();
        vm.prank(hunter);
        vm.expectRevert(BountyBox.InvalidProofURLLength.selector);
        box.submitClaim(id, "", "");
        assertEq(box.claimsBy(id, hunter), 0);
        for (uint256 i = 0; i < 3; i++) _claim(hunter, id);
    }

    function test_ClaimsBy_RevertsUnknownBounty() public {
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 9));
        box.claimsBy(9, hunter);
    }

    // ---------------------------------------------------------------- (4) Status enum
    function test_Status_EnumValues() public pure {
        assertEq(uint8(BountyBox.Status.Open), 0);
        assertEq(uint8(BountyBox.Status.Paid), 1);
        assertEq(uint8(BountyBox.Status.Refunded), 2);
    }

    function test_Status_StaysOpenUntilLastRefundThenRefunded() public {
        uint256 id = _create();
        vm.prank(alice);
        box.contribute(id, 50e6);
        vm.prank(bob);
        box.contribute(id, 25e6);
        vm.warp(expiry);

        vm.prank(alice);
        box.refund(id);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Open));
        assertEq(b.pot, AMT + 25e6);

        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        box.refund(id);
        assertEq(usdc.balanceOf(bob), bBefore + 25e6);
        assertEq(box.getBounty(id).pot, AMT);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Open));

        vm.prank(poster);
        box.refund(id);
        assertEq(box.getBounty(id).pot, 0);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    /// @dev After a non-final refund the bounty is still Open but expired: contribute/claim hit
    ///      BountyExpired and accept hits AcceptWindowClosed (not BountyNotOpen).
    function test_Status_PartiallyRefundedOpenBountyRejectsContributeClaimAndAccept() public {
        uint256 id = _createClaimed();
        vm.warp(_settle());
        vm.prank(alice);
        box.refund(id);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Open));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
        box.contribute(id, AMT);
        vm.prank(hunter2);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
        box.submitClaim(id, "ipfs://p", "");
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
    }

    /// @dev Once the last share is withdrawn the bounty is Refunded and mutating calls hit BountyNotOpen.
    function test_Status_FullyRefundedRejectsContributeClaimAndAccept() public {
        uint256 id = _createClaimed();
        vm.warp(_settle());
        vm.prank(alice);
        box.refund(id);
        vm.prank(poster);
        box.refund(id);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Refunded));

        bytes memory err = abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id);
        vm.prank(bob);
        vm.expectRevert(err);
        box.contribute(id, AMT);
        vm.prank(hunter2);
        vm.expectRevert(err);
        box.submitClaim(id, "ipfs://p", "");
        vm.prank(poster);
        vm.expectRevert(err);
        box.acceptClaim(id, 0);
        // refunded bounty: repeat refund is NoContribution, not BountyNotOpen
        vm.prank(poster);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
    }

    function test_Status_PaidStillBlocksRefund() public {
        uint256 id = _createClaimed();
        _accept(id, 0);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Paid));
        vm.warp(_settle() + 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.refund(id);
    }

    function test_Status_ReFundDoubleStillNoContribution() public {
        uint256 id = _create();
        vm.warp(expiry);
        vm.startPrank(poster);
        box.refund(id);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- (5) hasAccepted
    function test_HasAccepted_FalseForOpenPartiallyRefundedAndRefunded() public {
        uint256 id = _create();
        vm.prank(alice);
        box.contribute(id, 50e6);
        assertFalse(box.getBounty(id).hasAccepted);
        vm.warp(expiry);

        // partially refunded: still Open, never accepted
        vm.prank(poster);
        box.refund(id);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Open));
        assertFalse(b.hasAccepted);
        assertEq(b.winner, address(0));
        assertEq(b.paidAmount, 0);

        // fully refunded
        vm.prank(alice);
        box.refund(id);
        b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Refunded));
        assertFalse(b.hasAccepted);
        assertEq(b.winner, address(0));
        assertEq(b.paidAmount, 0);
    }

    function test_HasAccepted_TrueAfterAcceptWithClaimIdZero() public {
        uint256 id = _createClaimed();
        _accept(id, 0);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertTrue(b.hasAccepted);
        assertEq(b.winningClaimId, 0);
        assertEq(b.winner, hunter);
        assertEq(b.paidAmount, AMT + 50e6);
    }

    function test_HasAccepted_TrueAfterAcceptWithNonZeroClaimId() public {
        uint256 id = _createClaimed();
        _claim(hunter2, id);
        _accept(id, 1);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertTrue(b.hasAccepted);
        assertEq(b.winningClaimId, 1);
        assertEq(b.winner, hunter2);
    }

    function test_Struct_FieldOrderViaRawEncoding() public {
        uint256 id = _createClaimed();
        _accept(id, 0);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(b.id, id);
        assertEq(b.poster, poster);
        assertEq(b.title, "Title");
        assertEq(b.description, "Desc");
        assertEq(b.expiry, expiry);
        assertEq(b.pot, 0);
        assertEq(uint8(b.status), 1);
        assertTrue(b.hasAccepted);
        assertEq(b.winner, hunter);
        assertEq(b.winningClaimId, 0);
        assertEq(b.paidAmount, AMT + 50e6);
        assertEq(b.claimCount, 1);
        assertEq(b.contributorCount, 2);
        assertEq(b.createdAt, 1_000_000);
    }
}

/// @dev Grace-aware action surface. Records ghost violations of the accept/refund windows.
contract HardeningHandler is Test {
    BountyBox public box;
    MockUSDC public usdc;
    address[] internal actors;
    bool public windowViolation;
    uint256 public acceptsOk;
    uint256 public refundsOk;
    uint256 public graceAccepts;

    constructor(BountyBox box_, MockUSDC usdc_) {
        box = box_;
        usdc = usdc_;
        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("hactor", vm.toString(i))));
            actors.push(a);
            vm.prank(a);
            usdc.approve(address(box_), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _id(uint256 seed) internal view returns (uint256) {
        uint256 n = box.bountyCount();
        return n == 0 ? 0 : (seed % n) + 1;
    }

    function create(uint256 actorSeed, uint256 amount, uint256 dur) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 10_000, 1_000e6);
        dur = bound(dur, 1, 20 days);
        usdc.mint(a, amount);
        vm.prank(a);
        box.createBounty("T", "", uint64(block.timestamp + dur), amount);
    }

    function contribute(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 10_000, 1_000e6);
        usdc.mint(a, amount);
        uint256 id = _id(idSeed);
        vm.prank(a);
        try box.contribute(id, amount) {} catch {}
    }

    function submitClaim(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _id(idSeed);
        vm.prank(_actor(actorSeed));
        try box.submitClaim(id, "ipfs://p", "") {} catch {}
    }

    function accept(uint256 idSeed, uint256 claimSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        BountyBox.Bounty memory b = box.getBounty(id);
        if (b.claimCount == 0) return;
        uint256 settle = box.refundOpensAt(id);
        vm.prank(b.poster);
        try box.acceptClaim(id, claimSeed % b.claimCount) {
            acceptsOk++;
            if (block.timestamp >= settle) windowViolation = true;
            if (block.timestamp >= b.expiry) graceAccepts++;
        } catch {
            if (b.status == BountyBox.Status.Open && block.timestamp < settle) windowViolation = true;
        }
    }

    function refund(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        uint256 settle = box.refundOpensAt(id);
        vm.prank(_actor(actorSeed));
        try box.refund(id) {
            refundsOk++;
            if (block.timestamp < settle) windowViolation = true;
        } catch {}
    }

    function warp(uint256 dt) external {
        skip(bound(dt, 1, 5 days));
    }
}

contract BountyBoxHardeningInvariantTest is Test {
    BountyBox internal box;
    MockUSDC internal usdc;
    HardeningHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBox(address(usdc));
        handler = new HardeningHandler(box, usdc);
        targetContract(address(handler));
    }

    /// @dev Contract USDC balance == sum of pots of all Open/Refunded bounties; Paid pots are zero.
    function invariant_BalanceEqualsSumOfUnpaidPots() public view {
        uint256 total;
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            if (b.status == BountyBox.Status.Paid) {
                assertEq(b.pot, 0, "paid bounty holds funds");
                assertTrue(b.hasAccepted);
            } else {
                total += b.pot;
                assertFalse(b.hasAccepted);
            }
        }
        assertEq(usdc.balanceOf(address(box)), total);
    }

    /// @dev Unpaid pot always equals the sum of recorded shares.
    function invariant_SharesSumEqualsPot() public view {
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            if (b.status == BountyBox.Status.Paid) continue;
            (, uint256[] memory sh) = box.getContributors(id);
            uint256 s;
            for (uint256 i = 0; i < sh.length; i++) s += sh[i];
            assertEq(s, b.pot, "shares != pot");
        }
    }

    /// @dev Refunded <=> (unpaid and pot == 0): an unpaid bounty stays Open until its last share is withdrawn.
    function invariant_RefundedIffPotZero() public view {
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            if (b.status == BountyBox.Status.Paid) continue;
            assertEq(b.status == BountyBox.Status.Refunded, b.pot == 0, "Refunded iff pot==0");
        }
    }

    /// @dev Accept never succeeds at/after settlement; refund never before; Open bounties inside window always accept-able.
    function invariant_AcceptAndRefundWindowsNeverOverlap() public view {
        assertFalse(handler.windowViolation());
    }

    /// @dev Per-hunter claim counts never exceed the cap and sum to claimCount is bounded accordingly.
    function invariant_ClaimCapRespected() public view {
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Claim[] memory cs = box.getClaims(id);
            for (uint256 i = 0; i < cs.length; i++) {
                assertLe(box.claimsBy(id, cs[i].hunter), box.MAX_CLAIMS_PER_HUNTER());
            }
        }
    }
}
