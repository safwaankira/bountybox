// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {BountyBoxV2, BountyBoxV2Errors} from "../BountyBoxV2.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev Guardian kill switch (retireJudge) and the behaviour of the box after retirement.
contract BountyBoxV2HardeningTest is BountyBoxV2TestBase {
    bytes4 internal RETIRED = BountyBoxV2Errors.JudgeRetired.selector;

    function _retire() internal {
        vm.prank(guardian);
        box.retireJudge();
    }

    /// poster 100, alice 60, bob 30, carol 20 (=210e6) on one AI bounty.
    function _multiAI(bool withClaim) internal returns (uint256 id) {
        id = _createAI();
        _contribute(alice, id, 50e6);
        _contribute(bob, id, 30e6);
        _contribute(carol, id, 20e6);
        _contribute(alice, id, 10e6);
        if (withClaim) _claim(hunter, id);
    }

    function _fingerprint() internal view returns (bytes32 h) {
        address[9] memory who = [poster, alice, bob, carol, hunter, hunter2, stranger, judge, guardian];
        h = keccak256(abi.encode(usdc.balanceOf(address(box)), box.bountyCount()));
        for (uint256 i = 0; i < who.length; i++) {
            h = keccak256(abi.encode(h, usdc.balanceOf(who[i])));
        }
        for (uint256 id = 1; id <= box.bountyCount(); id++) {
            (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
            h = keccak256(
                abi.encode(
                    h,
                    box.getBounty(id),
                    box.getClaims(id),
                    cs,
                    sh,
                    box.refundOpensAt(id),
                    uint8(box.effectiveStatus(id))
                )
            );
        }
    }

    // ---------------------------------------------------------------- access control
    function test_Retire_GuardianSucceeds() public {
        assertFalse(box.judgeRetired());
        _retire();
        assertTrue(box.judgeRetired());
    }

    function test_Retire_OnlyGuardian() public {
        address[6] memory bad = [judge, poster, stranger, hunter, alice, address(this)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(BountyBoxV2.OnlyGuardian.selector);
            box.retireJudge();
        }
        assertFalse(box.judgeRetired());
    }

    function test_Retire_NonGuardianAfterRetireStillSeesOnlyGuardian() public {
        _retire();
        vm.prank(stranger);
        vm.expectRevert(BountyBoxV2.OnlyGuardian.selector);
        box.retireJudge();
    }

    // ---------------------------------------------------------------- irreversible / once
    function test_Retire_SecondCallReverts() public {
        _retire();
        vm.prank(guardian);
        vm.expectRevert(BountyBoxV2.JudgeAlreadyRetired.selector);
        box.retireJudge();
        assertTrue(box.judgeRetired());
    }

    function test_Retire_EmitsEventOnceWithGuardian() public {
        vm.expectEmit(true, false, false, true, address(box));
        emit BountyBoxV2.JudgeRetired(guardian);
        _retire();

        // exactly one log, correct topic/emitter, and none on the failed repeat
        BountyBoxV2 other = new BountyBoxV2(address(usdc), judge, guardian, CAP);
        vm.recordLogs();
        vm.prank(guardian);
        other.retireJudge();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one log");
        assertEq(logs[0].emitter, address(other));
        assertEq(logs[0].topics[0], keccak256("JudgeRetired(address)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(guardian))));

        vm.prank(guardian);
        vm.expectRevert(BountyBoxV2.JudgeAlreadyRetired.selector);
        other.retireJudge();
        assertEq(vm.getRecordedLogs().length, 0, "no log on repeat");
    }

    function test_Retire_StaysRetiredForever() public {
        _retire();
        vm.warp(block.timestamp + 365 days);
        assertTrue(box.judgeRetired());
        vm.prank(guardian);
        vm.expectRevert(BountyBoxV2.JudgeAlreadyRetired.selector);
        box.retireJudge();
    }

    // ---------------------------------------------------------------- changes nothing else
    function test_Retire_MovesNoFundsAndChangesNoBounty() public {
        uint256 ai = _multiAI(true);
        uint256 aiNoClaim = _createAI();
        uint256 p = _createP();
        _claim(hunter2, p);
        _contribute(bob, p, 5e6);
        bytes32 before = _fingerprint();
        uint256 boxBal = usdc.balanceOf(address(box));
        assertEq(boxBal, 210e6 + AMT + AMT + 5e6);

        _retire();

        assertEq(_fingerprint(), before, "state + balances unchanged");
        assertEq(usdc.balanceOf(address(box)), boxBal);
        assertEq(usdc.balanceOf(guardian), 0);
        // the AI bounties are still Open and unpaid
        assertEq(uint8(_status(ai)), uint8(BountyBoxV2.Status.Open));
        assertEq(uint8(_status(aiNoClaim)), uint8(BountyBoxV2.Status.Open));
        assertEq(box.getBounty(ai).pot, 210e6);
        assertEq(box.refundOpensAt(ai), uint256(expiry) + GRACE);
        assertEq(box.refundOpensAt(aiNoClaim), uint256(expiry));
    }

    function test_Retire_GuardianBalanceUntouched() public {
        uint256 g = usdc.balanceOf(guardian);
        _multiAI(true);
        _retire();
        assertEq(usdc.balanceOf(guardian), g);
    }

    // ---------------------------------------------------------------- judgeAccept after retire
    function test_AfterRetire_JudgeAcceptRevertsForJudge() public {
        uint256 id = _multiAI(true);
        _retire();
        vm.expectRevert(RETIRED);
        _judgeAccept(id, 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        assertEq(box.getBounty(id).pot, 210e6);
    }

    function test_AfterRetire_JudgeAcceptRevertsForEveryCallerOnEveryBounty() public {
        uint256 ai = _multiAI(true);
        uint256 p = _createP();
        _claim(hunter2, p);
        _retire();
        address[7] memory callers = [judge, stranger, poster, guardian, hunter, alice, address(this)];
        uint256[3] memory ids = [ai, p, uint256(999)]; // AI bounty, poster bounty, nonexistent
        for (uint256 i = 0; i < callers.length; i++) {
            for (uint256 j = 0; j < ids.length; j++) {
                vm.prank(callers[i]);
                vm.expectRevert(RETIRED);
                box.judgeAccept(ids[j], 0, keccak256("v"), "ipfs://v");
            }
        }
        // junk args are still the retirement error (check is first)
        vm.prank(stranger);
        vm.expectRevert(RETIRED);
        box.judgeAccept(ai, 77, bytes32(0), "");
        assertEq(box.getBounty(ai).pot, 210e6);
        assertEq(usdc.balanceOf(hunter), 10_000e6);
    }

    function test_AfterRetire_JudgeAcceptRevertsAtLastSecondOfAcceptWindow() public {
        uint256 id = _multiAI(true);
        _retire();
        vm.warp(uint256(expiry) + GRACE - 1);
        vm.expectRevert(RETIRED);
        _judgeAccept(id, 0);
    }

    function test_BeforeRetire_JudgeAcceptStillWorks() public {
        uint256 id = _multiAI(true);
        uint256 before = usdc.balanceOf(hunter);
        _judgeAccept(id, 0);
        assertEq(usdc.balanceOf(hunter), before + 210e6);
    }

    // ---------------------------------------------------------------- refunds of pre-existing AI bounties
    function test_AfterRetire_RefundsWithClaimOpenAtExpiryPlusGrace() public {
        uint256 id = _multiAI(true);
        _retire();

        address[4] memory cs = [poster, alice, bob, carol];
        uint256[4] memory sh = [uint256(100e6), 60e6, 30e6, 20e6];
        uint256 settle = uint256(expiry) + GRACE;
        bytes memory notOpen = abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, settle);

        // blocked before settlement exactly as before: during life, at expiry, 1s before grace end
        uint256[3] memory ts = [block.timestamp, uint256(expiry), settle - 1];
        for (uint256 k = 0; k < ts.length; k++) {
            vm.warp(ts[k]);
            vm.prank(poster);
            vm.expectRevert(notOpen);
            box.refund(id);
        }

        vm.warp(settle);
        uint256 remaining = 210e6;
        for (uint256 i = 0; i < cs.length; i++) {
            uint256 bal = usdc.balanceOf(cs[i]);
            vm.expectEmit(true, true, false, true, address(box));
            emit BountyBoxV2.Refunded(id, cs[i], sh[i]);
            _refund(cs[i], id);
            assertEq(usdc.balanceOf(cs[i]), bal + sh[i], "exact share");
            remaining -= sh[i];
            assertEq(box.getBounty(id).pot, remaining);
            assertEq(usdc.balanceOf(address(box)), remaining);
            if (i < cs.length - 1) assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
        }
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_AfterRetire_RefundsWithoutClaimOpenAtExpiry() public {
        uint256 id = _multiAI(false);
        _retire();

        vm.warp(uint256(expiry) - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, id, uint256(expiry)));
        box.refund(id);

        vm.warp(expiry);
        address[4] memory cs = [carol, poster, bob, alice]; // arbitrary order
        uint256[4] memory sh = [uint256(20e6), 100e6, 30e6, 60e6];
        for (uint256 i = 0; i < cs.length; i++) {
            uint256 bal = usdc.balanceOf(cs[i]);
            _refund(cs[i], id);
            assertEq(usdc.balanceOf(cs[i]), bal + sh[i]);
        }
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_AfterRetire_SettlementTimeUnchanged() public {
        uint256 withClaim = _multiAI(true);
        uint256 noClaim = _multiAI(false);
        uint256 a = box.refundOpensAt(withClaim);
        uint256 b = box.refundOpensAt(noClaim);
        _retire();
        assertEq(box.refundOpensAt(withClaim), a);
        assertEq(box.refundOpensAt(noClaim), b);
        assertEq(a, uint256(expiry) + GRACE);
        assertEq(b, uint256(expiry));
    }

    function test_AfterRetire_NonContributorAndJudgeStillCannotRefund() public {
        uint256 id = _multiAI(false);
        _retire();
        vm.warp(expiry);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.NoContribution.selector));
        box.refund(id);
        vm.prank(judge);
        vm.expectRevert(BountyBoxV2.JudgeCannotRefund.selector);
        box.refund(id);
    }

    // ---------------------------------------------------------------- AI paths blocked
    function test_AfterRetire_CreateAIReverts() public {
        _retire();
        vm.prank(poster);
        vm.expectRevert(RETIRED);
        box.createBounty("T", "", "crit", expiry, AMT, AI_MODE, false);
        assertEq(box.bountyCount(), 0);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_AfterRetire_CreateAIRevertsEvenWithOtherwiseInvalidArgs() public {
        _retire();
        vm.prank(poster);
        vm.expectRevert(RETIRED); // JudgeRetired check precedes validation
        box.createBounty("", "", "", 0, 0, AI_MODE, false);
    }

    function test_AfterRetire_ContributeToAIReverts() public {
        uint256 id = _multiAI(false);
        _retire();
        vm.prank(stranger);
        vm.expectRevert(RETIRED);
        box.contribute(id, AMT);
        assertEq(box.getBounty(id).pot, 210e6);
        // still retired-error after expiry (check precedes expiry check)
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(RETIRED);
        box.contribute(id, AMT);
    }

    function test_AfterRetire_SubmitClaimToAIReverts() public {
        uint256 id = _multiAI(false);
        _retire();
        vm.prank(hunter);
        vm.expectRevert(RETIRED);
        box.submitClaim(id, "ipfs://p", "", "");
        assertEq(box.getBounty(id).claimCount, 0);
        assertEq(box.refundOpensAt(id), uint256(expiry), "no grace can be added after retire");
    }

    function test_AfterRetire_UnknownBountyStillBountyNotFound() public {
        _retire();
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 42));
        box.contribute(42, AMT);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, 42));
        box.submitClaim(42, "u", "", "");
    }

    // ---------------------------------------------------------------- poster mode unaffected
    function test_AfterRetire_PosterModeFullLifecycleWorks() public {
        uint256 p1 = _createP();
        _claim(hunter, p1);
        uint256 p2 = _createP();
        _retire();

        // create
        vm.prank(alice);
        uint256 p3 = box.createBounty("T3", "", "", expiry, 40e6, POSTER_MODE, true);
        assertEq(box.getBounty(p3).pot, 40e6);
        // contribute
        _contribute(bob, p1, 25e6);
        _contribute(bob, p3, 5e6);
        // submitClaim (new claim + handle-required bounty)
        uint256 c2 = _claim(hunter2, p1);
        assertEq(c2, 1);
        _claimH(hunter, p3, "@h");
        // acceptClaim
        uint256 bal = usdc.balanceOf(hunter2);
        vm.prank(poster);
        box.acceptClaim(p1, c2);
        assertEq(usdc.balanceOf(hunter2), bal + AMT + 25e6);
        assertEq(uint8(_status(p1)), uint8(BountyBoxV2.Status.Paid));
        vm.prank(alice);
        box.acceptClaim(p3, 0);
        assertEq(uint8(_status(p3)), uint8(BountyBoxV2.Status.Paid));
        // refund
        vm.warp(expiry);
        uint256 pb = usdc.balanceOf(poster);
        _refund(poster, p2);
        assertEq(usdc.balanceOf(poster), pb + AMT);
        assertEq(uint8(_status(p2)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_AfterRetire_PosterModeSettlementAndRefundAfterGrace() public {
        uint256 p = _createP();
        _contribute(alice, p, 10e6);
        _claim(hunter, p);
        _retire();
        vm.warp(expiry);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.RefundNotOpen.selector, p, uint256(expiry) + GRACE));
        box.refund(p);
        vm.warp(uint256(expiry) + GRACE);
        _refund(alice, p);
        _refund(poster, p);
        assertEq(uint8(_status(p)), uint8(BountyBoxV2.Status.Refunded));
    }

    function test_AfterRetire_PosterCannotUseAcceptClaimOnAIBounty() public {
        uint256 id = _multiAI(true);
        _retire();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.JudgedByAI.selector, id));
        box.acceptClaim(id, 0);
    }
}
