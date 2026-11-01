// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewBase} from "./BountyBoxV2.ReviewBase.t.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";

/// @dev (A, SPAM) 300 max-size claims from 100 addresses and 300 distinct contributors:
///      every page stays readable and settlement gas does not scale with claim/contributor counts.
contract ReviewSpamTest is ReviewBase {
    uint256 internal constant SPAM_CLAIMS = 300;
    uint256 internal constant SPAM_CONTRIBS = 300;

    string internal url500;

    function setUp() public override {
        super.setUp();
        bytes memory b = new bytes(500);
        for (uint256 i = 0; i < 500; i++) {
            b[i] = "u";
        }
        url500 = string(b);
    }

    function _hunterAt(uint256 tag, uint256 i) internal pure returns (address) {
        return address(uint160(0x100000 * (tag + 1) + i));
    }

    /// @dev Bounty with `claims` max-length-URL claims (3 per hunter) and `contribs` unique contributors
    ///      (poster is #0). Winner-side addresses (hunters) hold no USDC; contributors hold exactly their share.
    function _spamBounty(BountyBoxV2.JudgeMode mode, uint256 claims, uint256 contribs, uint256 tag)
        internal
        returns (uint256 id)
    {
        id = mode == AI_MODE ? _createAI() : _createP();
        for (uint256 i = 1; i < contribs; i++) {
            address c = _fresh(tag * 100_000 + i, MIN + i);
            vm.prank(c);
            box.contribute(id, MIN + i);
        }
        for (uint256 i = 0; i < claims; i++) {
            vm.prank(_hunterAt(tag, i / 3));
            box.submitClaim(id, url500, "note", "handle");
        }
    }

    function _contributorAt(uint256 tag, uint256 i) internal pure returns (address) {
        return address(uint160(0xF00000 + tag * 100_000 + i));
    }

    function _within10(uint256 big, uint256 small) internal pure {
        assertLe(big * 100, small * 110, "big bounty costs >10% more gas");
        assertGe(big * 100, small * 90, "big bounty costs >10% less gas (suspicious)");
    }

    // ------------------------------------------------------------ readability
    function test_Spam_EveryPageReadable_ClaimsAndContributors() public {
        uint256 id = _spamBounty(POSTER_MODE, SPAM_CLAIMS, SPAM_CONTRIBS, 1);
        assertEq(box.claimCount(id), SPAM_CLAIMS);
        assertEq(box.contributorCount(id), SPAM_CONTRIBS);

        BountyBoxV2.Claim[] memory all = box.getClaims(id);
        assertEq(all.length, SPAM_CLAIMS);
        for (uint256 off = 0; off < SPAM_CLAIMS; off += 100) {
            (BountyBoxV2.Claim[] memory page, uint256 total) = box.getClaimsPage(id, off, 100);
            assertEq(total, SPAM_CLAIMS);
            assertEq(page.length, 100);
            for (uint256 i = 0; i < page.length; i++) {
                assertEq(page[i].hunter, all[off + i].hunter);
                assertEq(bytes(page[i].proofURL).length, 500);
                assertEq(page[i].proofURL, all[off + i].proofURL);
            }
        }
        (BountyBoxV2.Claim[] memory none, uint256 t) = box.getClaimsPage(id, SPAM_CLAIMS, 100);
        assertEq(none.length, 0);
        assertEq(t, SPAM_CLAIMS);

        (address[] memory allC, uint256[] memory allS) = box.getContributors(id);
        assertEq(allC.length, SPAM_CONTRIBS);
        for (uint256 off = 0; off < SPAM_CONTRIBS; off += 100) {
            (address[] memory cs, uint256[] memory ss, uint256 total) = box.getContributorsPage(id, off, 1000);
            assertEq(total, SPAM_CONTRIBS);
            assertEq(cs.length, 100, "limit clamped");
            // 1000 clamps to 100 so the walk below must use the returned length
            for (uint256 i = 0; i < cs.length; i++) {
                assertEq(cs[i], allC[off + i]);
                assertEq(ss[i], allS[off + i]);
            }
        }

        // each of the 100 hunters holds exactly 3 claims and cannot add a 4th
        for (uint256 h = 0; h < 100; h++) {
            assertEq(box.claimsBy(id, _hunterAt(1, h)), 3);
        }
        vm.prank(_hunterAt(1, 0));
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.TooManyClaims.selector, id, _hunterAt(1, 0)));
        box.submitClaim(id, url500, "", "");
    }

    function test_Spam_IndividualGetClaimStillWorks() public {
        uint256 id = _spamBounty(POSTER_MODE, SPAM_CLAIMS, 3, 2);
        uint256[5] memory ixs = [uint256(0), 1, 150, 298, 299];
        for (uint256 k = 0; k < ixs.length; k++) {
            BountyBoxV2.Claim memory c = box.getClaim(id, ixs[k]);
            assertEq(c.hunter, _hunterAt(2, ixs[k] / 3));
            assertEq(bytes(c.proofURL).length, 500);
            assertEq(c.timestamp, block.timestamp);
        }
        vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.ClaimNotFound.selector, id, SPAM_CLAIMS));
        box.getClaim(id, SPAM_CLAIMS);
    }

    // ----------------------------------------------------------- gas parity
    function test_Spam_AcceptClaimGasIndependentOfCounts() public {
        uint256 big = _spamBounty(POSTER_MODE, SPAM_CLAIMS, SPAM_CONTRIBS, 3);
        uint256 small = _spamBounty(POSTER_MODE, 3, 3, 4);

        vm.prank(poster);
        uint256 g0 = gasleft();
        box.acceptClaim(big, SPAM_CLAIMS - 1);
        uint256 gasBig = g0 - gasleft();

        vm.prank(poster);
        g0 = gasleft();
        box.acceptClaim(small, 2);
        uint256 gasSmall = g0 - gasleft();

        emit log_named_uint("acceptClaim gas (300 claims/300 contributors)", gasBig);
        emit log_named_uint("acceptClaim gas (3 claims/3 contributors)", gasSmall);
        _within10(gasBig, gasSmall);
        assertEq(usdc.balanceOf(_hunterAt(3, 99)), _potOfBig(), "winner got the full recorded pot");
    }

    function _potOfBig() internal view returns (uint256 pot) {
        pot = AMT;
        for (uint256 i = 1; i < SPAM_CONTRIBS; i++) {
            pot += MIN + i;
        }
    }

    function test_Spam_JudgeAcceptGasIndependentOfCounts() public {
        uint256 big = _spamBounty(AI_MODE, SPAM_CLAIMS, SPAM_CONTRIBS, 5);
        uint256 small = _spamBounty(AI_MODE, 3, 3, 6);

        vm.prank(judge);
        uint256 g0 = gasleft();
        box.judgeAccept(big, SPAM_CLAIMS - 1, keccak256("v"), "ipfs://verdict");
        uint256 gasBig = g0 - gasleft();

        vm.prank(judge);
        g0 = gasleft();
        box.judgeAccept(small, 2, keccak256("v"), "ipfs://verdict");
        uint256 gasSmall = g0 - gasleft();

        emit log_named_uint("judgeAccept gas (300/300)", gasBig);
        emit log_named_uint("judgeAccept gas (3/3)", gasSmall);
        _within10(gasBig, gasSmall);
        assertEq(usdc.balanceOf(_hunterAt(5, 99)), _potOfBig());
    }

    function test_Spam_RefundGasIndependentOfCounts() public {
        uint256 big = _spamBounty(POSTER_MODE, SPAM_CLAIMS, SPAM_CONTRIBS, 7);
        uint256 small = _spamBounty(POSTER_MODE, 3, 3, 8);
        _toSettlement(big);
        _toSettlement(small);

        address cBig = _contributorAt(7, 150);
        address cSmall = _contributorAt(8, 2);
        uint256 shareBig = box.contributionOf(big, cBig);
        uint256 potBefore = _pots(big);

        vm.prank(cBig);
        uint256 g0 = gasleft();
        box.refund(big);
        uint256 gasBig = g0 - gasleft();

        vm.prank(cSmall);
        g0 = gasleft();
        box.refund(small);
        uint256 gasSmall = g0 - gasleft();

        emit log_named_uint("refund gas (300/300)", gasBig);
        emit log_named_uint("refund gas (3/3)", gasSmall);
        _within10(gasBig, gasSmall);
        assertEq(_pots(big), potBefore - shareBig);
        assertEq(usdc.balanceOf(cBig), shareBig);
    }

    function test_Spam_LastContributorRefundOnHugeBountyAlsoCheap() public {
        // the refund that flips the status to Refunded must also stay flat
        uint256 big = _spamBounty(POSTER_MODE, SPAM_CLAIMS, SPAM_CONTRIBS, 9);
        _toSettlement(big);
        uint256 maxGas;
        for (uint256 i = 1; i < SPAM_CONTRIBS; i++) {
            address c = _contributorAt(9, i);
            vm.prank(c);
            uint256 g0 = gasleft();
            box.refund(big);
            uint256 used = g0 - gasleft();
            if (used > maxGas) maxGas = used;
        }
        vm.prank(poster);
        uint256 g1 = gasleft();
        box.refund(big);
        uint256 lastGas = g1 - gasleft();
        emit log_named_uint("max non-final refund gas", maxGas);
        emit log_named_uint("final refund gas", lastGas);
        assertLt(maxGas, 120_000);
        assertLt(lastGas, 120_000);
        assertEq(uint8(_status(big)), uint8(BountyBoxV2.Status.Refunded));
        assertEq(_pots(big), 0);
        assertEq(box.contributorCount(big), SPAM_CONTRIBS);
    }
}
