// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewInvariantBase} from "./BountyBoxV2.ReviewInvariantBase.t.sol";

/// @dev Core V2 invariants. Differences from the original suite: the balance is `>=` the unpaid pots
///      (donations are inert surplus), a donate action exists, the guardian is a normal actor that also
///      retires the judge, the judge is funded, and afterInvariant() enforces minimum exploration.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
contract BountyBoxV2InvariantTest is ReviewInvariantBase {
    function setUp() public {
        _init(1_000_000e6, 100e6, 0);
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

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_SharesSumEqualsPotAndStatusConsistent() public view {
        _checkSharesAndStatus();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_ClaimCapRespectedPagingConsistentJudgeHoldsNothing() public view {
        _checkClaimCapJudgeAndPaging();
        _checkJudgeNeverPaid();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_TokenConservationAndNoGhostViolations() public view {
        _checkTokenConservation();
        _checkNoViolation();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_zz_ExplorationSummary() public view {
        _logSummary();
    }
}

/// @dev Same suite, but ~60% of actor picks are the GUARDIAN, so it provably creates, contributes, claims,
///      wins and refunds as a normal user while also being the only account that may retire the judge.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
contract BountyBoxV2GuardianBiasInvariantTest is ReviewInvariantBase {
    function setUp() public {
        _init(1_000_000e6, 100e6, 60);
    }

    function _minimums() internal view override {
        super._minimums();
        assertGe(handler.guardianCreates(), 1, "guardian created a bounty");
        assertGe(handler.guardianContribs(), 1, "guardian contributed");
        assertGe(handler.guardianClaims(), 1, "guardian claimed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_GuardianAsUser_BalanceCoversPotsAndSurplusIsDonations() public view {
        _checkBalanceCoversPots();
        _checkSurplusEqualsDonations();
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    function invariant_GuardianAsUser_AccountingAndJudgeConstraints() public view {
        _checkSharesAndStatus();
        _checkClaimCapJudgeAndPaging();
        _checkJudgeNeverPaid();
        _checkTokenConservation();
        _checkNoViolation();
    }
}
