// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewBase} from "./BountyBoxV2.ReviewBase.t.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";
import {ConfigurableUSDC} from "../test-helpers/ConfigurableUSDC.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev (C) A failed transferFrom must roll back createBounty / contribute completely.
contract ReviewTransferFromTest is ReviewBase {
    address internal broke = makeAddr("broke"); // approved but zero balance
    address internal noAllowance = makeAddr("noAllowance"); // funded but never approved
    address internal newcomer = makeAddr("newcomer");

    function setUp() public override {
        super.setUp();
        vm.prank(broke);
        usdc.approve(address(box), type(uint256).max);
        usdc.mint(noAllowance, 1_000e6);
        usdc.mint(newcomer, 1_000e6);
        vm.prank(newcomer);
        usdc.approve(address(box), type(uint256).max);
    }

    // ------------------------------------------------------------- helpers
    /// @dev Same call, with the right criteria for the mode.
    function _create2(address who, BountyBoxV2.JudgeMode mode, uint256 amt) internal returns (uint256) {
        return _create(who, mode == AI_MODE ? "crit" : "", mode, amt);
    }

    function _assertNoBounty(uint256 id) internal {
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, id));
        box.getBounty(id);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, id));
        box.getContributors(id);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, id));
        box.contributionOf(id, poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, id));
        box.getContributorsPage(id, 0, 10);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, id));
        box.contributorCount(id);
    }

    function _failedCreateLeavesNoTrace(address who, BountyBoxV2.JudgeMode mode, bytes memory err) internal {
        uint256 before_ = box.bountyCount();
        uint256 balBox = usdc.balanceOf(address(box));
        uint256 balWho = usdc.balanceOf(who);
        uint256 next = before_ + 1;

        vm.prank(who);
        if (err.length > 0) vm.expectRevert(err);
        else vm.expectRevert();
        box.createBounty("T", "", mode == AI_MODE ? "crit" : "", expiry, AMT, mode, false);

        assertEq(box.bountyCount(), before_, "bountyCount unchanged");
        assertEq(usdc.balanceOf(address(box)), balBox);
        assertEq(usdc.balanceOf(who), balWho);
        _assertNoBounty(next);
        // the next successful create reuses the same id
        uint256 id = _create2(poster, mode, AMT);
        assertEq(id, next, "id reused");
        assertEq(box.bountyCount(), next);
        assertEq(box.contributorCount(id), 1);
        assertEq(box.contributionOf(id, who), 0, "failed creator holds no share");
        assertEq(_pots(id), AMT);
    }

    // ------------------------------------------------- createBounty failures
    function test_FailedCreate_NoAllowance_BothModes() public {
        bytes memory err = bytes("allowance");
        _failedCreateLeavesNoTrace(noAllowance, POSTER_MODE, err);
        _failedCreateLeavesNoTrace(noAllowance, AI_MODE, err);
    }

    function test_FailedCreate_InsufficientBalance_BothModes() public {
        bytes memory err = bytes("balance");
        _failedCreateLeavesNoTrace(broke, POSTER_MODE, err);
        _failedCreateLeavesNoTrace(broke, AI_MODE, err);
    }

    function test_FailedCreate_TransferFromRevertsMode() public {
        usdc.setFromMode(ConfigurableUSDC.FromMode.Revert);
        uint256 before_ = box.bountyCount();
        vm.prank(alice);
        vm.expectRevert(ConfigurableUSDC.TransferFromDisabled.selector);
        box.createBounty("T", "", "", expiry, AMT, POSTER_MODE, false);
        assertEq(box.bountyCount(), before_);
        _assertNoBounty(1);
        usdc.setFromMode(ConfigurableUSDC.FromMode.Normal);
        assertEq(_create2(alice, POSTER_MODE, AMT), 1);
    }

    function test_FailedCreate_TransferFromReturnsFalse_SafeERC20Reverts() public {
        usdc.setFromMode(ConfigurableUSDC.FromMode.ReturnFalse);
        bytes memory err = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc));
        uint256 balAlice = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(err);
        box.createBounty("T", "", "", expiry, AMT, POSTER_MODE, false);
        assertEq(box.bountyCount(), 0);
        _assertNoBounty(1);
        assertEq(usdc.balanceOf(alice), balAlice);
        assertEq(usdc.balanceOf(address(box)), 0);

        vm.prank(alice);
        vm.expectRevert(err);
        box.createBounty("T", "", "crit", expiry, AMT, AI_MODE, false);
        assertEq(box.bountyCount(), 0);

        usdc.setFromMode(ConfigurableUSDC.FromMode.Normal);
        assertEq(_create2(alice, AI_MODE, AMT), 1, "next create gets the same id");
    }

    function test_FailedCreate_AfterExistingBounties_IdsStayDense() public {
        uint256 a = _createP();
        uint256 b = _createAI();
        assertEq(a, 1);
        assertEq(b, 2);
        (address[] memory c1, uint256[] memory s1) = box.getContributors(1);
        (address[] memory c2, uint256[] memory s2) = box.getContributors(2);
        uint256 pot1 = _pots(1);
        uint256 pot2 = _pots(2);

        usdc.setFromMode(ConfigurableUSDC.FromMode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        box.createBounty("T", "", "", expiry, AMT, POSTER_MODE, false);
        usdc.setFromMode(ConfigurableUSDC.FromMode.Normal);

        assertEq(box.bountyCount(), 2);
        _assertNoBounty(3);
        (address[] memory c1b, uint256[] memory s1b) = box.getContributors(1);
        (address[] memory c2b, uint256[] memory s2b) = box.getContributors(2);
        assertEq(abi.encode(c1, s1), abi.encode(c1b, s1b));
        assertEq(abi.encode(c2, s2), abi.encode(c2b, s2b));
        assertEq(_pots(1), pot1);
        assertEq(_pots(2), pot2);
        assertEq(_create2(alice, POSTER_MODE, AMT), 3);
    }

    function testFuzz_FailedCreateLeavesNoTrace(uint8 mode, uint256 amt, bool ai) public {
        mode = uint8(bound(mode, 0, 2)); // 0 no allowance, 1 revert mode, 2 false mode
        amt = bound(amt, MIN, 5_000e6);
        BountyBoxV2.JudgeMode jm = ai ? AI_MODE : POSTER_MODE;
        address who = alice;
        if (mode == 0) who = noAllowance;
        else usdc.setFromMode(mode == 1 ? ConfigurableUSDC.FromMode.Revert : ConfigurableUSDC.FromMode.ReturnFalse);
        uint256 balBox = usdc.balanceOf(address(box));
        vm.prank(who);
        vm.expectRevert();
        box.createBounty("T", "", ai ? "crit" : "", expiry, amt, jm, false);
        assertEq(box.bountyCount(), 0);
        assertEq(usdc.balanceOf(address(box)), balBox);
        _assertNoBounty(1);
        usdc.setFromMode(ConfigurableUSDC.FromMode.Normal);
        assertEq(_create2(alice, jm, amt), 1);
    }

    // --------------------------------------------------- contribute failures
    struct CSnap {
        uint256 pot;
        uint256 cc;
        bytes list; // abi-encoded (contributors, shares)
        uint256 boxBal;
    }

    function _csnap(uint256 id) internal view returns (CSnap memory s) {
        (address[] memory c, uint256[] memory sh) = box.getContributors(id);
        s = CSnap(_pots(id), box.contributorCount(id), abi.encode(c, sh), usdc.balanceOf(address(box)));
    }

    function _assertSame(CSnap memory a, CSnap memory b) internal pure {
        assertEq(a.pot, b.pot, "pot");
        assertEq(a.cc, b.cc, "contributorCount");
        assertEq(a.list, b.list, "contributors+shares");
        assertEq(a.boxBal, b.boxBal, "box balance");
    }

    function _contributeFailsFor(uint256 id, address who, bytes memory err) internal {
        CSnap memory s0 = _csnap(id);
        uint256 shareBefore = box.contributionOf(id, who);
        vm.prank(who);
        if (err.length > 0) vm.expectRevert(err);
        else vm.expectRevert();
        box.contribute(id, 50e6);
        _assertSame(s0, _csnap(id));
        assertEq(box.contributionOf(id, who), shareBefore);
    }

    function test_FailedContribute_NoAllowance_FirstTimeContributorNotAdded() public {
        uint256 id = _createP();
        _contribute(alice, id, 20e6);
        _contributeFailsFor(id, noAllowance, bytes("allowance"));
        (address[] memory c,) = box.getContributors(id);
        assertEq(c.length, 2);
        assertEq(box.contributionOf(id, noAllowance), 0);
        // a later successful contribution by the same account IS added exactly once
        vm.prank(noAllowance);
        usdc.approve(address(box), type(uint256).max);
        _contribute(noAllowance, id, 50e6);
        assertEq(box.contributorCount(id), 3);
        (c,) = box.getContributors(id);
        assertEq(c[2], noAllowance);
    }

    function test_FailedContribute_InsufficientBalance_ExistingAndNewContributor() public {
        uint256 id = _createAI();
        _contribute(alice, id, 20e6);
        _contributeFailsFor(id, broke, bytes("balance"));
        // existing contributor with drained wallet: share unchanged
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(alice);
        usdc.transfer(donor, bal);
        _contributeFailsFor(id, alice, bytes("balance"));
        assertEq(box.contributionOf(id, alice), 20e6);
    }

    function test_FailedContribute_ReturnFalseAndRevertModes() public {
        uint256 id = _createP();
        _contribute(alice, id, 20e6);
        usdc.setFromMode(ConfigurableUSDC.FromMode.ReturnFalse);
        bytes memory err = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc));
        _contributeFailsFor(id, newcomer, err);
        _contributeFailsFor(id, alice, err);
        usdc.setFromMode(ConfigurableUSDC.FromMode.Revert);
        _contributeFailsFor(id, newcomer, abi.encodeWithSelector(ConfigurableUSDC.TransferFromDisabled.selector));
        _contributeFailsFor(id, bob, abi.encodeWithSelector(ConfigurableUSDC.TransferFromDisabled.selector));
        assertEq(box.contributorCount(id), 2);
        usdc.setFromMode(ConfigurableUSDC.FromMode.Normal);
        _contribute(newcomer, id, 50e6);
        assertEq(box.contributorCount(id), 3);
        assertEq(_pots(id), AMT + 20e6 + 50e6);
    }

    function test_FailedContribute_AIBounty_CapMathUnaffectedByFailure() public {
        usdc.mint(poster, CAP);
        uint256 id = _create(poster, "crit", AI_MODE, CAP - 10e6);
        usdc.setFromMode(ConfigurableUSDC.FromMode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        box.contribute(id, 10e6);
        usdc.setFromMode(ConfigurableUSDC.FromMode.Normal);
        // the failed attempt did not consume cap headroom
        _contribute(alice, id, 10e6);
        assertEq(_pots(id), CAP);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAP + MIN, CAP));
        box.contribute(id, MIN);
    }
}
