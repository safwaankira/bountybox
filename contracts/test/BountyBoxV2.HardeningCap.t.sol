// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2} from "../BountyBoxV2.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev maxAIPot enforcement on AI create/contribute (unit + fuzz). Poster-mode is never capped.
contract BountyBoxV2HardeningCapTest is BountyBoxV2TestBase {
    uint256 internal constant CAPX = 1_000e6;

    function setUp() public override {
        super.setUp();
        _redeploy(CAPX);
    }

    /// Replace `box` with one using `cap`, re-approving every fixture actor.
    function _redeploy(uint256 cap) internal {
        box = new BountyBoxV2(address(usdc), judge, guardian, cap);
        address[7] memory who = [poster, alice, bob, carol, hunter, hunter2, stranger];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    function _acct(uint256 i) internal pure returns (address) {
        return address(uint160(0x20000 + i));
    }

    function _fund(address a) internal {
        usdc.mint(a, type(uint128).max);
        vm.prank(a);
        usdc.approve(address(box), type(uint256).max);
    }

    function _createAIAmt(address who, uint256 amt) internal returns (uint256 id) {
        vm.prank(who);
        id = box.createBounty("T", "", "crit", expiry, amt, AI_MODE, false);
    }

    function _capErr(uint256 attempted) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, attempted, CAPX);
    }

    // ---------------------------------------------------------------- create
    function test_CreateAI_ExactlyCapAllowed() public {
        uint256 id = _createAIAmt(poster, CAPX);
        assertEq(box.getBounty(id).pot, CAPX);
        assertEq(usdc.balanceOf(address(box)), CAPX);
    }

    function test_CreateAI_CapPlusOneReverts() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAPX + 1, CAPX));
        box.createBounty("T", "", "crit", expiry, CAPX + 1, AI_MODE, false);
        assertEq(box.bountyCount(), 0);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_CreateAI_HugeAmountRevertsWithCapError() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, type(uint256).max, CAPX));
        box.createBounty("T", "", "crit", expiry, type(uint256).max, AI_MODE, false);
    }

    function test_CreateAI_BelowMinStillAmountTooSmall() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AmountTooSmall.selector, MIN - 1));
        box.createBounty("T", "", "crit", expiry, MIN - 1, AI_MODE, false);
    }

    function test_CreateAI_MinimumCapBoxAcceptsExactlyMin() public {
        _redeploy(MIN);
        uint256 id = _createAIAmt(poster, MIN);
        assertEq(box.getBounty(id).pot, MIN);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, MIN + 1, MIN));
        box.createBounty("T", "", "crit", expiry, MIN + 1, AI_MODE, false);
    }

    // ---------------------------------------------------------------- contribute
    function test_ContributeAI_ExactlyCapAllowed() public {
        uint256 id = _createAIAmt(poster, 400e6);
        _contribute(alice, id, 600e6);
        assertEq(box.getBounty(id).pot, CAPX);
    }

    function test_ContributeAI_OneBaseUnitOverCapReverts() public {
        uint256 id = _createAIAmt(poster, 400e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAPX + 1, CAPX));
        box.contribute(id, 600e6 + 1);
        assertEq(box.getBounty(id).pot, 400e6, "failed contribute changes nothing");
        assertEq(box.contributionOf(id, alice), 0);
        assertEq(box.getBounty(id).contributorCount, 1);
        // the exact remaining headroom still works afterwards
        _contribute(alice, id, 600e6);
        assertEq(box.getBounty(id).pot, CAPX);
    }

    function test_ContributeAI_FullPotRejectsAnyFurtherContribution() public {
        uint256 id = _createAIAmt(poster, CAPX);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAPX + MIN, CAPX));
        box.contribute(id, MIN);
    }

    function test_ContributeAI_MultipleContributorsHitCapTogether() public {
        uint256 id = _createAIAmt(poster, 100e6);
        _contribute(alice, id, 300e6);
        _contribute(bob, id, 250e6);
        _contribute(carol, id, 200e6);
        _contribute(alice, id, 100e6); // repeat contributor
        assertEq(box.getBounty(id).pot, 950e6);

        // 50e6 of headroom: 50e6+1 fails for everyone, 50e6 passes for the next one
        address[3] memory tries = [bob, stranger, poster];
        for (uint256 i = 0; i < tries.length; i++) {
            vm.prank(tries[i]);
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAPX + 1, CAPX));
            box.contribute(id, 50e6 + 1);
        }
        _contribute(stranger, id, 50e6);
        assertEq(box.getBounty(id).pot, CAPX);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAPX + MIN, CAPX));
        box.contribute(id, MIN);
        assertEq(usdc.balanceOf(address(box)), CAPX);
    }

    function test_ContributeAI_CapIsPerBounty() public {
        uint256 a = _createAIAmt(poster, CAPX);
        uint256 b = _createAIAmt(poster, CAPX);
        assertEq(box.getBounty(a).pot, CAPX);
        assertEq(box.getBounty(b).pot, CAPX);
        assertEq(usdc.balanceOf(address(box)), 2 * CAPX, "no aggregate cap");
    }

    function test_ContributeAI_FreedHeadroomUnusableAfterExpiry() public {
        uint256 id = _createAIAmt(poster, 400e6);
        _contribute(alice, id, 600e6);
        vm.warp(expiry);
        _refund(alice, id); // partial refund frees 600e6 of headroom
        assertEq(box.getBounty(id).pot, 400e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyExpired.selector, id));
        box.contribute(id, MIN);
    }

    function test_ContributeAI_FreedHeadroomUnusableAfterExpiryWithClaim() public {
        uint256 id = _createAIAmt(poster, 400e6);
        _contribute(alice, id, 600e6);
        _claim(hunter, id);
        vm.warp(uint256(expiry) + GRACE);
        _refund(alice, id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyExpired.selector, id));
        box.contribute(id, MIN);
        assertEq(box.getBounty(id).pot, 400e6);
    }

    function test_ContributeAI_CapFailureDoesNotMaskExpiry() public {
        uint256 id = _createAIAmt(poster, CAPX);
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyExpired.selector, id));
        box.contribute(id, AMT);
    }

    // ---------------------------------------------------------------- poster mode uncapped
    function test_PosterMode_CreateAboveCapAllowed() public {
        vm.prank(poster);
        uint256 id = box.createBounty("T", "", "", expiry, 5 * CAPX, POSTER_MODE, false);
        assertEq(box.getBounty(id).pot, 5 * CAPX);
    }

    function test_PosterMode_ContributionsAboveCapAllowed() public {
        uint256 id = _createFull(poster, "", POSTER_MODE, false);
        _contribute(alice, id, 3 * CAPX);
        _contribute(bob, id, 10 * CAPX);
        assertEq(box.getBounty(id).pot, AMT + 13 * CAPX);
        assertGt(box.getBounty(id).pot, box.maxAIPot());
        // and it can still be paid out in full by the poster
        _claim(hunter, id);
        uint256 bal = usdc.balanceOf(hunter);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertEq(usdc.balanceOf(hunter), bal + AMT + 13 * CAPX);
    }

    // ---------------------------------------------------------------- fuzz
    /// (a) random AI create + contributions by random contributors never exceed the cap,
    ///     and every call reverts exactly with AIPotCapExceeded iff it would exceed.
    function testFuzz_AIPotNeverExceedsCap(uint256 firstAmt, uint256[10] memory amts, uint8[10] memory who) public {
        for (uint256 i = 0; i < 5; i++) _fund(_acct(i));
        firstAmt = bound(firstAmt, MIN, 2 * CAPX);
        if (firstAmt > CAPX) {
            vm.prank(_acct(0));
            vm.expectRevert(_capErr(firstAmt));
            box.createBounty("T", "", "crit", expiry, firstAmt, AI_MODE, false);
            firstAmt = CAPX / 4;
        }
        uint256 id = _createAIAmt(_acct(0), firstAmt);

        uint256 reverts;
        for (uint256 i = 0; i < amts.length; i++) {
            uint256 amt = bound(amts[i], MIN, CAPX / 3);
            address who_ = _acct(who[i] % 5);
            uint256 pot = box.getBounty(id).pot;
            vm.prank(who_);
            if (pot + amt > CAPX) {
                vm.expectRevert(_capErr(pot + amt));
                box.contribute(id, amt);
                reverts++;
                assertEq(box.getBounty(id).pot, pot, "reverted call changed nothing");
            } else {
                box.contribute(id, amt);
                assertEq(box.getBounty(id).pot, pot + amt);
            }
            assertLe(box.getBounty(id).pot, CAPX, "pot <= cap");
        }
        // conservation: shares sum to pot, pot equals escrowed balance
        (, uint256[] memory sh) = box.getContributors(id);
        uint256 s;
        for (uint256 i = 0; i < sh.length; i++) s += sh[i];
        assertEq(s, box.getBounty(id).pot);
        assertEq(usdc.balanceOf(address(box)), s);
    }

    /// (b) for random caps and amounts, AI create succeeds iff amount <= cap; poster-mode always succeeds.
    function testFuzz_CreateSucceedsIffAmountWithinCap(uint256 cap, uint256 amount) public {
        cap = bound(cap, MIN, 1e15);
        amount = bound(amount, MIN, 2e15);
        _redeploy(cap);
        address who = _acct(1);
        _fund(who);

        vm.prank(who);
        if (amount <= cap) {
            uint256 id = box.createBounty("T", "", "crit", expiry, amount, AI_MODE, false);
            assertEq(box.getBounty(id).pot, amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, amount, cap));
            box.createBounty("T", "", "crit", expiry, amount, AI_MODE, false);
            assertEq(box.bountyCount(), 0);
        }

        vm.prank(who);
        uint256 pid = box.createBounty("T", "", "", expiry, amount, POSTER_MODE, false);
        assertEq(box.getBounty(pid).pot, amount, "poster mode uncapped");
    }

    /// (c) contribute succeeds iff pot + amount <= cap, for random pot/cap/amount.
    function testFuzz_ContributeSucceedsIffWithinCap(uint256 cap, uint256 first, uint256 amount) public {
        cap = bound(cap, 2 * MIN, 1e15);
        _redeploy(cap);
        first = bound(first, MIN, cap);
        amount = bound(amount, MIN, 2e15);
        _fund(_acct(1));
        _fund(_acct(2));
        uint256 id = _createAIAmt(_acct(1), first);

        vm.prank(_acct(2));
        if (first + amount <= cap) {
            box.contribute(id, amount);
            assertEq(box.getBounty(id).pot, first + amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, first + amount, cap));
            box.contribute(id, amount);
            assertEq(box.getBounty(id).pot, first);
        }
    }
}
