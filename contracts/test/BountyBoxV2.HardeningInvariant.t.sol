// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2} from "../BountyBoxV2.sol";
import {ReviewInvariantBase} from "./BountyBoxV2.ReviewInvariantBase.t.sol";

/// @dev Hardening invariants with a small AI cap (300 USDC) so the cap boundary is hit constantly, plus
///      guardian-as-user, funded judge, donations and a random retirement.
///      Replaces the old `balance == unpaid pots` and `guardian never holds USDC` assertions.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
contract BountyBoxV2HardeningInvariantTest is ReviewInvariantBase {
    uint256 internal constant CAP = 300e6;

    function setUp() public {
        _init(CAP, CAP, 0);
    }

    function _minimums() internal view override {
        super._minimums();
        assertGe(handler.capRejections(), 1, "cap boundary hit at least once per run");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_NoAIPotExceedsCap() public view {
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            BountyBoxV2.Bounty memory b = box.getBounty(id);
            if (b.judgeMode == BountyBoxV2.JudgeMode.AI) {
                assertLe(b.pot, CAP, "AI pot <= cap");
                assertLe(b.paidAmount, CAP, "AI paid <= cap");
            }
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_UsdcBalanceCoversUnpaidPots() public view {
        _checkBalanceCoversPots();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_SurplusEqualsExactlyTheDonations() public view {
        _checkSurplusEqualsDonations();
    }

    /// @dev Replaces "guardian never holds USDC": the guardian is a normal user now. What must still hold:
    ///      the judge keeps exactly its own funding, holds no share anywhere, retireJudge never changed any
    ///      balance / pot / bounty (ghost-checked inside the handler) and the guardian holds no share it
    ///      could not have earned (shares reconcile with pots).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_JudgeNeverPaid_RetireNeverMovesFunds_GuardianIsAnOrdinaryUser() public view {
        _checkJudgeNeverPaid();
        _checkNoViolation();
        _checkSharesAndStatus();
        _checkTokenConservation();
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            assertEq(box.contributionOf(id, judge), 0);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_RetirementAndCapRulesNeverViolated() public view {
        assertFalse(handler.violation(), handler.violationWhy());
        _checkClaimCapJudgeAndPaging();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_NoAIBountyCreatedAfterRetire() public view {
        if (!box.judgeRetired()) return;
        // every AI bounty must predate retirement: bounties after retiredAtCount are Poster-mode
        for (uint256 id = handler.retiredAtCount() + 1; id <= box.bountyCount(); id++) {
            assertEq(uint8(box.getBounty(id).judgeMode), uint8(BountyBoxV2.JudgeMode.Poster));
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_zz_ExplorationSummary() public view {
        _logSummary();
    }
}
