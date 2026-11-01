// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";
import {MockUSDC} from "./BountyBox.t.sol";
import {ReviewInvariantHandler} from "./BountyBoxV2.ReviewHandler.t.sol";

/// @dev Shared wiring + assertion helpers for every V2 invariant suite. NO invariant_/test functions here
///      (except the afterInvariant hook, which forge calls once at the end of every run).
abstract contract ReviewInvariantBase is Test {
    BountyBoxV2 internal box;
    MockUSDC internal usdc;
    ReviewInvariantHandler internal handler;
    address internal judge = makeAddr("judge");
    address internal guardian = makeAddr("guardian");

    function _init(uint256 cap, uint256 unit, uint256 bias) internal {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBoxV2(address(usdc), judge, guardian, cap);
        handler = new ReviewInvariantHandler(box, usdc, judge, guardian, unit, bias);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](22);
        sels[0] = handler.create.selector;
        sels[1] = handler.create.selector;
        sels[2] = handler.create.selector;
        sels[3] = handler.contribute.selector;
        sels[4] = handler.contribute.selector;
        sels[5] = handler.contribute.selector;
        sels[6] = handler.claim.selector;
        sels[7] = handler.claim.selector;
        sels[8] = handler.claim.selector;
        sels[9] = handler.accept.selector;
        sels[10] = handler.accept.selector;
        sels[11] = handler.judgeAccept.selector;
        sels[12] = handler.judgeAccept.selector;
        sels[13] = handler.refund.selector;
        sels[14] = handler.refund.selector;
        sels[15] = handler.donate.selector;
        sels[16] = handler.retire.selector;
        sels[17] = handler.retire.selector;
        sels[18] = handler.retire.selector;
        sels[19] = handler.judgeMisuseAttempt.selector;
        sels[20] = handler.warp.selector;
        sels[21] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    // ------------------------------------------------ shared assertions
    function _sumUnpaidPots() internal view returns (uint256 sum) {
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            BountyBoxV2.Bounty memory b = box.getBounty(id);
            if (b.status != BountyBoxV2.Status.Paid) sum += b.pot;
        }
    }

    function _checkBalanceCoversPots() internal view {
        assertGe(usdc.balanceOf(address(box)), _sumUnpaidPots(), "balance >= sum of unpaid pots");
    }

    /// @dev Surplus above the unpaid pots is exactly what was donated directly: nothing else is ever left behind.
    function _checkSurplusEqualsDonations() internal view {
        assertEq(
            usdc.balanceOf(address(box)) - _sumUnpaidPots(), handler.totalDonated(), "surplus == total donated"
        );
    }

    function _checkSharesAndStatus() internal view {
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            BountyBoxV2.Bounty memory b = box.getBounty(id);
            if (b.status == BountyBoxV2.Status.Paid) {
                assertTrue(b.hasAccepted);
                assertEq(b.pot, 0);
                assertGt(b.paidAmount, 0);
                assertTrue(b.winner != address(0));
                assertLt(b.winningClaimId, b.claimCount);
                assertEq(box.getClaim(id, b.winningClaimId).hunter, b.winner);
                assertTrue(b.winner != judge, "judge never wins");
                if (b.judgeMode == BountyBoxV2.JudgeMode.Poster) {
                    (bytes32 h,) = box.getVerdict(id);
                    assertEq(h, bytes32(0));
                }
                continue;
            }
            assertFalse(b.hasAccepted);
            assertEq(b.paidAmount, 0);
            (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
            uint256 s;
            for (uint256 i = 0; i < cs.length; i++) {
                s += sh[i];
            }
            assertEq(s, b.pot, "shares == pot");
            assertEq(cs.length, b.contributorCount);
            assertEq(b.status == BountyBoxV2.Status.Refunded, b.pot == 0, "Refunded iff pot==0");
        }
    }

    function _checkClaimCapJudgeAndPaging() internal view {
        uint256 n = handler.actorCount();
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            uint256 total;
            for (uint256 i = 0; i < n; i++) {
                uint256 c = box.claimsBy(id, handler.actors(i));
                assertLe(c, 3);
                total += c;
            }
            BountyBoxV2.Bounty memory b = box.getBounty(id);
            assertEq(total, b.claimCount);
            assertEq(box.getClaims(id).length, total);
            assertEq(box.contributionOf(id, judge), 0);
            // paged views agree with the counters
            (BountyBoxV2.Claim[] memory page, uint256 pt) = box.getClaimsPage(id, 0, 100);
            assertEq(pt, b.claimCount);
            assertEq(box.claimCount(id), b.claimCount);
            assertEq(page.length, pt > 100 ? 100 : pt);
            (,, uint256 ct) = box.getContributorsPage(id, 0, 100);
            assertEq(ct, b.contributorCount);
            assertEq(box.contributorCount(id), b.contributorCount);
        }
    }

    /// @dev The judge was funded like in production, yet it never gains or loses USDC through the contract.
    function _checkJudgeNeverPaid() internal view {
        assertEq(usdc.balanceOf(judge), handler.judgeFunding(), "judge holds exactly its own funding");
    }

    function _checkTokenConservation() internal view {
        uint256 sum = usdc.balanceOf(address(box)) + usdc.balanceOf(judge) + usdc.balanceOf(handler.donor());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += usdc.balanceOf(handler.actors(i));
        }
        assertEq(sum, usdc.totalSupply(), "token conservation");
    }

    function _checkNoViolation() internal view {
        assertFalse(handler.violation(), handler.violationWhy());
    }

    // ------------------------------------------- minimum exploration
    /// @dev Run once after every invariant run. A green suite therefore proves each run really exercised
    ///      every action class (counts are per run: handler state is reset between runs).
    function afterInvariant() public view {
        _minimums();
    }

    function _minimums() internal view virtual {
        assertGe(handler.createPoster(), 3, "min poster-mode creates");
        assertGe(handler.createAI(), 3, "min AI-mode creates");
        assertGe(handler.contributes(), 3, "min contributions");
        assertGe(handler.claims(), 3, "min claims");
        assertGe(handler.posterAccepts(), 1, "min poster accepts");
        assertGe(handler.judgeAccepts(), 1, "min judgeAccepts");
        assertGe(handler.refunds(), 1, "min refunds");
        assertGe(handler.donations(), 1, "min donations");
        assertGe(handler.retireCalls(), 1, "min guardian retire calls");
        assertEq(handler.retireOk(), 1, "judge retired exactly once per run");
        assertGe(handler.judgeMisuse(), 1, "min judge misuse attempts");
        assertGe(handler.capRejections(), 2, "cap boundary hit (create + contribute)");
        assertGe(handler.guardianCreates(), 2, "guardian created poster + AI bounties");
        assertGe(handler.guardianContribs(), 1, "guardian contributed");
        assertGe(handler.guardianClaims(), 1, "guardian claimed");
        assertGe(handler.guardianWins(), 1, "guardian won as a normal hunter");
        assertGe(handler.guardianRefunds(), 1, "guardian refunded");
        assertGe(handler.fuzzSuccess(), 5, "fuzz phase did real work after the scripted opening");
    }

    function _logSummary() internal view {
        console2.log("bounties", box.bountyCount());
        console2.log("donated", handler.totalDonated());
        console2.log("retired", box.judgeRetired() ? 1 : 0);
    }
}
