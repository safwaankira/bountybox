// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewBase} from "./BountyBoxV2.ReviewBase.t.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";

/// @dev (D) Unsolicited USDC sent straight to the contract is inert: it never changes a pot, a share,
///      the AI cap math or an award, and it can never be withdrawn by any function.
contract ReviewDonationsTest is ReviewBase {
    uint256 internal donated;

    function _donate(uint256 amt) internal {
        usdc.mint(donor, amt);
        vm.prank(donor);
        usdc.transfer(address(box), amt);
        donated += amt;
    }

    function _boxBal() internal view returns (uint256) {
        return usdc.balanceOf(address(box));
    }

    function _bountyHash(uint256 id) internal view returns (bytes32) {
        return keccak256(abi.encode(box.getBounty(id)));
    }

    function test_DonationDoesNotChangeAnyBountyField() public {
        uint256 id = _createP();
        _contribute(alice, id, 30e6);
        bytes32 h = _bountyHash(id);
        (address[] memory c, uint256[] memory s) = box.getContributors(id);
        _donate(77e6);
        _donate(1); // dust
        assertEq(_bountyHash(id), h, "bounty struct identical");
        (address[] memory c2, uint256[] memory s2) = box.getContributors(id);
        assertEq(abi.encode(c, s), abi.encode(c2, s2));
        assertEq(_boxBal(), AMT + 30e6 + donated);
        assertEq(box.contributionOf(id, donor), 0);
    }

    function test_DonationBeforeCreateDoesNotInflatePotOrShare() public {
        _donate(500e6);
        uint256 id = _createP();
        assertEq(_pots(id), AMT);
        assertEq(box.contributionOf(id, poster), AMT);
        assertEq(_boxBal(), AMT + donated);
    }

    function test_DonationDoesNotChangeAICapMath() public {
        usdc.mint(poster, 2 * CAP);
        _donate(3 * CAP); // far above the cap
        // exactly the cap is accepted
        uint256 id = _create(poster, "crit", AI_MODE, CAP);
        assertEq(_pots(id), CAP);
        // cap + 1 base unit is still rejected although the contract holds much more
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAP + MIN, CAP));
        box.contribute(id, MIN);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.AIPotCapExceeded.selector, CAP + 1, CAP));
        box.createBounty("T", "", "crit", expiry, CAP + 1, AI_MODE, false);
        // and a small AI pot with a huge surplus still has its full headroom
        uint256 id2 = _create(poster, "crit", AI_MODE, 10e6);
        _contribute(poster, id2, CAP - 10e6);
        assertEq(_pots(id2), CAP);
        assertEq(_boxBal(), 2 * CAP + donated);
    }

    function test_PosterAwardPaysExactlyRecordedPot_DonationsBeforeBetweenAfter() public {
        _donate(13e6); // before
        uint256 id = _createP();
        _donate(1); // dust, between
        _contribute(alice, id, 40e6);
        _donate(7e6);
        uint256 cid = _claim(hunter, id);
        _donate(2e6);
        uint256 pot = AMT + 40e6;
        assertEq(_pots(id), pot);

        uint256 hb = usdc.balanceOf(hunter);
        _accept(id, cid);
        assertEq(usdc.balanceOf(hunter), hb + pot, "hunter got exactly the pot");
        assertEq(box.getBounty(id).paidAmount, pot);
        assertEq(_pots(id), 0);
        assertEq(_boxBal(), donated, "exactly the donated surplus remains");
        _donate(5e6); // after
        assertEq(_boxBal(), donated);
        assertEq(box.getBounty(id).paidAmount, pot);
        _assertSurplusUnreachable(id);
    }

    function test_AIJudgeAcceptPaysExactlyRecordedPot_DonationsInTheMix() public {
        _donate(9e6);
        uint256 id = _createAI();
        _contribute(bob, id, 25e6);
        _donate(1);
        uint256 cid = _claim(hunter2, id);
        _donate(3e6);
        uint256 pot = AMT + 25e6;
        uint256 hb = usdc.balanceOf(hunter2);
        _judgeAccept(id, cid);
        assertEq(usdc.balanceOf(hunter2), hb + pot);
        assertEq(box.getBounty(id).paidAmount, pot);
        assertEq(_boxBal(), donated);
        _donate(11e6);
        assertEq(_boxBal(), donated);
        _assertSurplusUnreachable(id);
    }

    function test_RefundLifecyclePaysExactSharesAndLeavesOnlyDonations() public {
        uint256 id = _createP();
        _donate(4e6);
        _contribute(alice, id, 30e6);
        _donate(1);
        _contribute(bob, id, 20e6);
        _toSettlement(id);
        _donate(6e6);

        uint256 pa = usdc.balanceOf(poster);
        uint256 aa = usdc.balanceOf(alice);
        uint256 ba = usdc.balanceOf(bob);

        _refund(alice, id);
        assertEq(usdc.balanceOf(alice), aa + 30e6, "exact share, not a donation-boosted amount");
        assertEq(_pots(id), AMT + 20e6);
        _refund(poster, id);
        assertEq(usdc.balanceOf(poster), pa + AMT);
        _refund(bob, id);
        assertEq(usdc.balanceOf(bob), ba + 20e6);

        assertEq(_pots(id), 0);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(_boxBal(), donated, "only the donated surplus is left");
        _assertSurplusUnreachable(id);
    }

    function test_LastRefundingContributorGetsOnlyShare_NotTheSurplus() public {
        uint256 id = _createP();
        _donate(1_000e6);
        _toSettlement(id);
        uint256 pb = usdc.balanceOf(poster);
        _refund(poster, id);
        assertEq(usdc.balanceOf(poster), pb + AMT);
        assertEq(_boxBal(), 1_000e6);
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
    }

    function test_DonationDoesNotLeakAcrossBounties() public {
        uint256 a = _createP();
        uint256 b = _create(alice, "", POSTER_MODE, 50e6);
        _donate(900e6);
        _toSettlement(a);
        _refund(poster, a);
        // bounty b still owns exactly its pot; a refund of b pays only b's share
        assertEq(_pots(b), 50e6);
        uint256 ab = usdc.balanceOf(alice);
        _refund(alice, b);
        assertEq(usdc.balanceOf(alice), ab + 50e6);
        assertEq(_boxBal(), 900e6);
    }

    /// @dev No actor (incl. donor, judge, poster, guardian) can pull the surplus out of a settled bounty.
    function _assertSurplusUnreachable(uint256 id) internal {
        uint256 surplus = _boxBal();
        address[6] memory who = [donor, judge, poster, guardian, alice, hunter];
        for (uint256 i = 0; i < who.length; i++) {
            vm.prank(who[i]);
            try box.refund(id) {
                // only possible for a leftover recorded share, which must be zero after settlement
                revert("refund unexpectedly succeeded");
            } catch {}
            vm.prank(who[i]);
            try box.acceptClaim(id, 0) {
                revert("accept unexpectedly succeeded");
            } catch {}
            vm.prank(who[i]);
            try box.judgeAccept(id, 0, keccak256("x"), "u") {
                revert("judgeAccept unexpectedly succeeded");
            } catch {}
        }
        assertEq(_boxBal(), surplus, "surplus untouched");
        assertEq(usdc.balanceOf(donor), 0);
    }

    function test_DonorCannotRefundOrAccept() public {
        uint256 id = _createP();
        _claim(hunter, id);
        _donate(50e6);
        vm.prank(donor);
        vm.expectRevert(BountyBoxV2.OnlyPoster.selector);
        box.acceptClaim(id, 0);
        _toSettlement(id);
        vm.prank(donor);
        vm.expectRevert(BountyBoxV2.NoContribution.selector);
        box.refund(id);
    }

    function testFuzz_DonationsNeverChangeAwardOrShares(uint64 d1, uint64 d2, uint64 d3, uint64 d4, bool ai) public {
        _donate(d1);
        uint256 id = ai ? _createAI() : _createP();
        _donate(d2);
        _contribute(alice, id, 33e6);
        _donate(d3);
        uint256 cid = _claim(hunter, id);
        _donate(d4);
        uint256 pot = AMT + 33e6;
        assertEq(_pots(id), pot);
        assertEq(box.contributionOf(id, alice), 33e6);
        uint256 hb = usdc.balanceOf(hunter);
        if (ai) _judgeAccept(id, cid);
        else _accept(id, cid);
        assertEq(usdc.balanceOf(hunter), hb + pot);
        assertEq(_boxBal(), donated);
    }

    function testFuzz_DonationsNeverChangeRefunds(uint64 d1, uint64 d2, uint64 d3) public {
        _donate(d1);
        uint256 id = _createP();
        _donate(d2);
        _contribute(alice, id, 21e6);
        _toSettlement(id);
        _donate(d3);
        uint256 aa = usdc.balanceOf(alice);
        _refund(alice, id);
        assertEq(usdc.balanceOf(alice), aa + 21e6);
        _refund(poster, id);
        assertEq(_pots(id), 0);
        assertEq(_boxBal(), donated);
    }
}
