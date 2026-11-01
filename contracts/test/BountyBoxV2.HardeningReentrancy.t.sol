// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2, BountyBoxV2Errors} from "../BountyBoxV2.sol";
import {MockUSDC, ITokenHook} from "./BountyBox.t.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev Receives USDC (as hunter / contributor) and, inside the token callback, tries to call
///      retireJudge() twice. If it is the box's guardian the first call succeeds; otherwise it fails.
contract RetireReenter is ITokenHook {
    BountyBoxV2 public box;
    MockUSDC public usdc;
    bool public fired;
    bool public firstOk;
    bool public secondOk;
    bytes4 public firstSel;
    bytes4 public secondSel;
    uint256 public balanceSeenInHook;

    constructor(MockUSDC usdc_) {
        usdc = usdc_;
    }

    function setBox(BountyBoxV2 box_) external {
        box = box_;
        usdc.approve(address(box_), type(uint256).max);
    }

    function contribute(uint256 id, uint256 amt) external {
        box.contribute(id, amt);
    }

    function claim(uint256 id) external {
        box.submitClaim(id, "ipfs://proof", "", "");
    }

    function refund(uint256 id) external {
        box.refund(id);
    }

    function onTokenReceived() external {
        if (fired) return;
        fired = true;
        balanceSeenInHook = usdc.balanceOf(address(this));
        try box.retireJudge() {
            firstOk = true;
        } catch (bytes memory e) {
            firstSel = bytes4(e);
        }
        try box.retireJudge() {
            secondOk = true;
        } catch (bytes memory e) {
            secondSel = bytes4(e);
        }
    }
}

contract BountyBoxV2HardeningReentrancyTest is BountyBoxV2TestBase {
    RetireReenter internal att;

    function setUp() public override {
        super.setUp();
        att = new RetireReenter(usdc);
        usdc.mint(address(att), 1_000e6);
        usdc.setHook(true);
    }

    /// Redeploy the box with the attacker as guardian (or leave the EOA guardian).
    function _useAttackerAsGuardian() internal {
        box = new BountyBoxV2(address(usdc), judge, address(att), CAP);
        att.setBox(box);
        address[7] memory who = [poster, alice, bob, carol, hunter, hunter2, stranger];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    function _useAttackerAsNonGuardian() internal {
        att.setBox(box); // guardian remains the EOA
    }

    // -------- guardian contract retires from inside a judgeAccept payout
    function test_Reenter_GuardianRetiresDuringJudgeAcceptPayout() public {
        _useAttackerAsGuardian();
        uint256 id = _createAI();
        _contribute(alice, id, 50e6);
        att.claim(id);
        uint256 before = usdc.balanceOf(address(att));

        _judgeAccept(id, 0);

        assertTrue(att.fired(), "hook fired");
        assertTrue(att.firstOk(), "guardian's retire inside callback succeeds");
        assertFalse(att.secondOk(), "second retire inside callback fails");
        assertEq(att.secondSel(), BountyBoxV2.JudgeAlreadyRetired.selector);
        assertTrue(box.judgeRetired());
        // payout happened exactly once, state fully consistent
        assertEq(usdc.balanceOf(address(att)), before + AMT + 50e6, "paid exactly once");
        assertEq(usdc.balanceOf(address(box)), 0);
        BountyBoxV2.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBoxV2.Status.Paid));
        assertEq(b.paidAmount, AMT + 50e6);
        assertEq(b.pot, 0);
        assertEq(b.winner, address(att));
    }

    // -------- guardian contract retires from inside a refund payout
    function test_Reenter_GuardianRetiresDuringRefundPayout() public {
        _useAttackerAsGuardian();
        uint256 id = _createAI();
        att.contribute(id, 80e6);
        _contribute(alice, id, 20e6);
        vm.warp(expiry);
        uint256 before = usdc.balanceOf(address(att));

        att.refund(id);

        assertTrue(att.fired());
        assertTrue(att.firstOk());
        assertFalse(att.secondOk());
        assertTrue(box.judgeRetired());
        assertEq(usdc.balanceOf(address(att)), before + 80e6, "refunded exactly once");
        assertEq(box.contributionOf(id, address(att)), 0);
        assertEq(box.getBounty(id).pot, AMT + 20e6);
        assertEq(usdc.balanceOf(address(box)), AMT + 20e6, "others' shares untouched");
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));

        // remaining contributors still refund their exact shares
        uint256 pb = usdc.balanceOf(poster);
        uint256 ab = usdc.balanceOf(alice);
        _refund(poster, id);
        _refund(alice, id);
        assertEq(usdc.balanceOf(poster), pb + AMT);
        assertEq(usdc.balanceOf(alice), ab + 20e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    // -------- guardian contract retires from inside a Poster-mode acceptClaim payout
    function test_Reenter_GuardianRetiresDuringPosterAcceptPayout() public {
        _useAttackerAsGuardian();
        uint256 id = _createP();
        att.claim(id);
        uint256 before = usdc.balanceOf(address(att));
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertTrue(att.firstOk());
        assertTrue(box.judgeRetired());
        assertEq(usdc.balanceOf(address(att)), before + AMT, "paid exactly once");
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Paid));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    // -------- a non-guardian contract cannot retire from inside a callback
    function test_Reenter_NonGuardianCannotRetireInCallback_Refund() public {
        _useAttackerAsNonGuardian();
        uint256 id = _createAI();
        att.contribute(id, 80e6);
        vm.warp(expiry);
        uint256 before = usdc.balanceOf(address(att));

        att.refund(id);

        assertTrue(att.fired());
        assertFalse(att.firstOk());
        assertFalse(att.secondOk());
        assertEq(att.firstSel(), BountyBoxV2.OnlyGuardian.selector);
        assertEq(att.secondSel(), BountyBoxV2.OnlyGuardian.selector);
        assertFalse(box.judgeRetired());
        assertEq(usdc.balanceOf(address(att)), before + 80e6);
    }

    function test_Reenter_NonGuardianCannotRetireInCallback_JudgeAccept() public {
        _useAttackerAsNonGuardian();
        uint256 id = _createAI();
        att.claim(id);
        _judgeAccept(id, 0);
        assertTrue(att.fired());
        assertFalse(att.firstOk());
        assertEq(att.firstSel(), BountyBoxV2.OnlyGuardian.selector);
        assertFalse(box.judgeRetired());
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Paid));
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    // -------- retiring changes no pot: mid-payout retirement leaves a sibling AI bounty intact
    function test_Reenter_RetireMidPayoutLeavesSiblingBountyRefundable() public {
        _useAttackerAsGuardian();
        uint256 paid = _createAI();
        att.claim(paid);
        uint256 sibling = _createAI();
        _contribute(bob, sibling, 40e6);
        _claim(hunter, sibling);

        _judgeAccept(paid, 0); // retires mid-callback

        assertTrue(box.judgeRetired());
        assertEq(box.getBounty(sibling).pot, AMT + 40e6);
        assertEq(usdc.balanceOf(address(box)), AMT + 40e6);
        // sibling cannot be judged any more but refunds at expiry + grace
        vm.expectRevert(BountyBoxV2Errors.JudgeRetired.selector);
        _judgeAccept(sibling, 0);
        vm.warp(uint256(expiry) + GRACE);
        uint256 bb = usdc.balanceOf(bob);
        _refund(bob, sibling);
        _refund(poster, sibling);
        assertEq(usdc.balanceOf(bob), bb + 40e6);
        assertEq(usdc.balanceOf(address(box)), 0);
    }
}
