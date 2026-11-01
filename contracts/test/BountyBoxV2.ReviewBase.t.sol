// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BountyBoxV2, BountyBoxV2Errors} from "../BountyBoxV2.sol";
import {ConfigurableUSDC} from "../test-helpers/ConfigurableUSDC.sol";

/// @dev Shared fixture for the BountyBoxV2.Review* suites (blocklist-capable token). NO test functions.
abstract contract ReviewBase is Test {
    BountyBoxV2 internal box;
    ConfigurableUSDC internal usdc;

    address internal judge = makeAddr("judge");
    address internal guardian = makeAddr("guardian");
    address internal poster = makeAddr("poster");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal hunter = makeAddr("hunter");
    address internal hunter2 = makeAddr("hunter2");
    address internal donor = makeAddr("donor");

    uint256 internal constant CAP = 1_000_000e6;
    uint256 internal constant AMT = 100e6;
    uint256 internal constant MIN = 10_000;
    uint256 internal constant GRACE = 7 days;
    uint64 internal expiry;

    BountyBoxV2.JudgeMode internal constant POSTER_MODE = BountyBoxV2.JudgeMode.Poster;
    BountyBoxV2.JudgeMode internal constant AI_MODE = BountyBoxV2.JudgeMode.AI;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new ConfigurableUSDC();
        box = new BountyBoxV2(address(usdc), judge, guardian, CAP);
        expiry = uint64(block.timestamp + 7 days);

        address[8] memory who = [poster, alice, bob, carol, hunter, hunter2, guardian, judge];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000e6);
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    // ------------------------------------------------------------ helpers
    function _create(address who, string memory criteria, BountyBoxV2.JudgeMode mode, uint256 amt)
        internal
        returns (uint256 id)
    {
        vm.prank(who);
        id = box.createBounty("Title", "Desc", criteria, expiry, amt, mode, false);
    }

    function _createP() internal returns (uint256) {
        return _create(poster, "", POSTER_MODE, AMT);
    }

    function _createAI() internal returns (uint256) {
        return _create(poster, "Must be good", AI_MODE, AMT);
    }

    function _contribute(address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        box.contribute(id, amt);
    }

    function _claim(address who, uint256 id) internal returns (uint256 cid) {
        vm.prank(who);
        cid = box.submitClaim(id, "ipfs://proof", "note", "");
    }

    function _refund(address who, uint256 id) internal {
        vm.prank(who);
        box.refund(id);
    }

    function _accept(uint256 id, uint256 cid) internal {
        vm.prank(box.getBounty(id).poster);
        box.acceptClaim(id, cid);
    }

    function _judgeAccept(uint256 id, uint256 cid) internal {
        vm.prank(judge);
        box.judgeAccept(id, cid, keccak256("verdict"), "ipfs://verdict");
    }

    function _toSettlement(uint256 id) internal {
        vm.warp(box.refundOpensAt(id));
    }

    /// @dev Fresh address funded with exactly `amt` and approved, so token-slot gas costs are identical.
    function _fresh(uint256 salt, uint256 amt) internal returns (address a) {
        a = address(uint160(0xF00000 + salt));
        if (amt > 0) usdc.mint(a, amt);
        vm.prank(a);
        usdc.approve(address(box), type(uint256).max);
    }

    function _pots(uint256 id) internal view returns (uint256) {
        return box.getBounty(id).pot;
    }

    function _status(uint256 id) internal view returns (BountyBoxV2.Status) {
        return box.getBounty(id).status;
    }
}
