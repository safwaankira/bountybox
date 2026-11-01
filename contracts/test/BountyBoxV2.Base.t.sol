// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";
import {MockUSDC} from "./BountyBox.t.sol";

/// @dev Shared fixture + helpers for the BountyBoxV2 suites. Contains NO test functions.
abstract contract BountyBoxV2TestBase is Test {
    BountyBoxV2 internal box;
    MockUSDC internal usdc;

    address internal judge = makeAddr("judge");
    address internal poster = makeAddr("poster");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal hunter = makeAddr("hunter");
    address internal hunter2 = makeAddr("hunter2");
    address internal stranger = makeAddr("stranger");
    address internal guardian = makeAddr("guardian");

    uint256 internal constant CAP = 1_000_000e6;
    uint256 internal constant AMT = 100e6;
    uint256 internal constant MIN = 10_000;
    uint256 internal constant GRACE = 7 days;
    uint64 internal expiry;

    BountyBoxV2.JudgeMode internal constant POSTER_MODE = BountyBoxV2.JudgeMode.Poster;
    BountyBoxV2.JudgeMode internal constant AI_MODE = BountyBoxV2.JudgeMode.AI;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBoxV2(address(usdc), judge, guardian, CAP);
        expiry = uint64(block.timestamp + 7 days);

        address[8] memory who = [poster, alice, bob, carol, hunter, hunter2, stranger, judge];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000e6);
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ helpers
    function _createFull(
        address who,
        string memory criteria,
        BountyBoxV2.JudgeMode mode,
        bool requireHandle
    ) internal returns (uint256 id) {
        vm.prank(who);
        id = box.createBounty("Title", "Desc", criteria, expiry, AMT, mode, requireHandle);
    }

    function _createP() internal returns (uint256) {
        return _createFull(poster, "", POSTER_MODE, false);
    }

    function _createAI() internal returns (uint256) {
        return _createFull(poster, "Must be good", AI_MODE, false);
    }

    function _contribute(address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        box.contribute(id, amt);
    }

    function _claim(address who, uint256 id) internal returns (uint256 cid) {
        vm.prank(who);
        cid = box.submitClaim(id, "ipfs://proof", "note", "");
    }

    function _claimH(address who, uint256 id, string memory handle) internal returns (uint256 cid) {
        vm.prank(who);
        cid = box.submitClaim(id, "ipfs://proof", "note", handle);
    }

    function _refund(address who, uint256 id) internal {
        vm.prank(who);
        box.refund(id);
    }

    function _judgeAccept(uint256 id, uint256 cid) internal {
        vm.prank(judge);
        box.judgeAccept(id, cid, keccak256("verdict"), "ipfs://verdict");
    }

    function _toSettlement(uint256 id) internal {
        vm.warp(box.refundOpensAt(id));
    }

    function _status(uint256 id) internal view returns (BountyBoxV2.Status) {
        return box.getBounty(id).status;
    }

    function _eff(uint256 id) internal view returns (BountyBoxV2.EffectiveStatus) {
        return box.effectiveStatus(id);
    }

    function _str(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) b[i] = "a";
        return string(b);
    }
}
