// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";
import {MockUSDC, ITokenHook} from "./BountyBox.t.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

/// @dev Malicious hunter / contributor: on receiving USDC it tries to re-enter BountyBoxV2.
contract V2Attacker is ITokenHook {
    BountyBoxV2 public box;
    MockUSDC public usdc;
    uint8 public mode; // 0 refund, 1 acceptClaim, 2 contribute, 3 createBounty, 4 submitClaim, 5 judgeAccept
    uint256 public targetId;
    bool public entered;
    bool public reentrySucceeded;
    bytes public reentryRevert;

    constructor(BountyBoxV2 box_, MockUSDC usdc_) {
        box = box_;
        usdc = usdc_;
        usdc.approve(address(box_), type(uint256).max);
    }

    function setMode(uint8 m, uint256 id) external {
        mode = m;
        targetId = id;
        entered = false;
        reentrySucceeded = false;
        delete reentryRevert;
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
        if (entered) return;
        entered = true;
        bytes memory r;
        bool ok = true;
        if (mode == 0) {
            try box.refund(targetId) {} catch (bytes memory e) { ok = false; r = e; }
        } else if (mode == 1) {
            try box.acceptClaim(targetId, 0) {} catch (bytes memory e) { ok = false; r = e; }
        } else if (mode == 2) {
            try box.contribute(targetId, 10_000) {} catch (bytes memory e) { ok = false; r = e; }
        } else if (mode == 3) {
            try box.createBounty("x", "", "", uint64(block.timestamp + 1 days), 10_000, BountyBoxV2.JudgeMode.Poster, false) {}
            catch (bytes memory e) { ok = false; r = e; }
        } else if (mode == 4) {
            try box.submitClaim(targetId, "ipfs://x", "", "") {} catch (bytes memory e) { ok = false; r = e; }
        } else {
            try box.judgeAccept(targetId, 0, keccak256("x"), "ipfs://x") {} catch (bytes memory e) { ok = false; r = e; }
        }
        reentrySucceeded = ok;
        reentryRevert = r;
    }
}

contract BountyBoxV2ReentrancyTest is BountyBoxV2TestBase {
    V2Attacker internal att;

    function setUp() public override {
        super.setUp();
        att = new V2Attacker(box, usdc);
        usdc.mint(address(att), 1_000e6);
        usdc.setHook(true);
    }

    function _assertBlockedByGuard() internal view {
        assertFalse(att.reentrySucceeded(), "reentry must fail");
        assertEq(bytes4(att.reentryRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    /// Malicious hunter re-enters during judgeAccept's payout.
    function _judgeAcceptReentry(uint8 mode) internal {
        uint256 id = _createAI();
        _contribute(alice, id, 50e6);
        att.claim(id);
        att.setMode(mode, id);
        uint256 before = usdc.balanceOf(address(att));

        _judgeAccept(id, 0);

        assertTrue(att.entered(), "hook fired");
        _assertBlockedByGuard();
        assertEq(usdc.balanceOf(address(att)), before + AMT + 50e6, "paid exactly once");
        assertEq(usdc.balanceOf(address(box)), 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Paid));
    }

    function test_Reentrancy_JudgeAccept_Refund() public { _judgeAcceptReentry(0); }
    function test_Reentrancy_JudgeAccept_AcceptClaim() public { _judgeAcceptReentry(1); }
    function test_Reentrancy_JudgeAccept_Contribute() public { _judgeAcceptReentry(2); }
    function test_Reentrancy_JudgeAccept_CreateBounty() public { _judgeAcceptReentry(3); }
    function test_Reentrancy_JudgeAccept_SubmitClaim() public { _judgeAcceptReentry(4); }
    function test_Reentrancy_JudgeAccept_JudgeAccept() public { _judgeAcceptReentry(5); }

    /// Malicious hunter re-enters during poster acceptClaim's payout.
    function test_Reentrancy_AcceptClaim_ReenterAccept() public {
        uint256 id = _createP();
        att.claim(id);
        att.setMode(1, id);
        uint256 before = usdc.balanceOf(address(att));
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertTrue(att.entered());
        _assertBlockedByGuard();
        assertEq(usdc.balanceOf(address(att)), before + AMT);
    }

    /// Malicious contributor re-enters during refund payout.
    function _refundReentry(uint8 mode) internal {
        uint256 id = _createAI();
        att.contribute(id, 80e6);
        vm.warp(expiry);
        att.setMode(mode, id);
        uint256 before = usdc.balanceOf(address(att));

        att.refund(id);

        assertTrue(att.entered(), "hook fired");
        _assertBlockedByGuard();
        assertEq(usdc.balanceOf(address(att)), before + 80e6, "refunded exactly once");
        assertEq(box.contributionOf(id, address(att)), 0);
        assertEq(box.getBounty(id).pot, AMT);
        assertEq(usdc.balanceOf(address(box)), AMT, "poster share untouched");
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open));
    }

    function test_Reentrancy_Refund_Refund() public { _refundReentry(0); }
    function test_Reentrancy_Refund_Contribute() public { _refundReentry(2); }
    function test_Reentrancy_Refund_CreateBounty() public { _refundReentry(3); }
    function test_Reentrancy_Refund_SubmitClaim() public { _refundReentry(4); }
    function test_Reentrancy_Refund_JudgeAccept() public { _refundReentry(5); }
}
