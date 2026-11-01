// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReviewBase} from "./BountyBoxV2.ReviewBase.t.sol";
import {BountyBoxV2} from "../BountyBoxV2.sol";

/// @dev (A) Paged views: getClaimsPage / getContributorsPage / claimCount / contributorCount.
contract ReviewPaginationTest is ReviewBase {
    uint256 internal constant MAXP = 100;

    function _hunterAt(uint256 i) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    function _contribAt(uint256 i) internal returns (address) {
        return _fresh(0x1000 + i, MIN + i * 7);
    }

    /// @dev Poster-mode bounty with `n` claims (<= 3 per hunter), url "proof-<i>".
    function _bountyWithClaims(uint256 n) internal returns (uint256 id) {
        id = _createP();
        for (uint256 i = 0; i < n; i++) {
            vm.prank(_hunterAt(i / 3));
            box.submitClaim(id, string.concat("proof-", vm.toString(i)), "n", "h");
        }
    }

    /// @dev Poster-mode bounty with `n` unique contributors (poster is #0), distinct shares.
    function _bountyWithContributors(uint256 n) internal returns (uint256 id) {
        id = _createP();
        for (uint256 i = 1; i < n; i++) {
            address c = _contribAt(i);
            vm.prank(c);
            box.contribute(id, MIN + i * 7);
        }
    }

    function _eqClaim(BountyBoxV2.Claim memory a, BountyBoxV2.Claim memory b) internal pure {
        assertEq(a.hunter, b.hunter);
        assertEq(a.proofURL, b.proofURL);
        assertEq(a.note, b.note);
        assertEq(a.handle, b.handle);
        assertEq(a.timestamp, b.timestamp);
    }

    function _expectedLen(uint256 total, uint256 offset, uint256 limit) internal pure returns (uint256 n) {
        if (offset >= total || limit == 0) return 0;
        n = limit > MAXP ? MAXP : limit;
        if (n > total - offset) n = total - offset;
    }

    /// @dev Walk with a fixed page size; every page must be the exact slice of getClaims (no skip/dup).
    function _walkClaims(uint256 id, uint256 pageSize) internal view {
        BountyBoxV2.Claim[] memory all = box.getClaims(id);
        uint256 offset;
        uint256 pages;
        while (true) {
            (BountyBoxV2.Claim[] memory page, uint256 total) = box.getClaimsPage(id, offset, pageSize);
            assertEq(total, all.length, "total");
            assertEq(page.length, _expectedLen(total, offset, pageSize), "page len");
            if (page.length == 0) break;
            for (uint256 i = 0; i < page.length; i++) {
                _eqClaim(page[i], all[offset + i]);
            }
            offset += page.length;
            pages++;
            assertLe(pages, all.length, "no infinite paging");
        }
        assertEq(offset, all.length, "covered exactly");
    }

    function _walkContributors(uint256 id, uint256 pageSize) internal view {
        (address[] memory allC, uint256[] memory allS) = box.getContributors(id);
        uint256 offset;
        while (true) {
            (address[] memory cs, uint256[] memory ss, uint256 total) = box.getContributorsPage(id, offset, pageSize);
            assertEq(total, allC.length, "total");
            assertEq(cs.length, ss.length);
            assertEq(cs.length, _expectedLen(total, offset, pageSize), "page len");
            if (cs.length == 0) break;
            for (uint256 i = 0; i < cs.length; i++) {
                assertEq(cs[i], allC[offset + i]);
                assertEq(ss[i], allS[offset + i]);
                assertEq(ss[i], box.contributionOf(id, cs[i]), "share == contributionOf");
            }
            offset += cs.length;
        }
        assertEq(offset, allC.length, "covered exactly");
    }

    // ---------------------------------------------------------------- claims
    function test_ClaimPagesReconstructGetClaims_VariousSizes() public {
        uint256 id = _bountyWithClaims(250);
        uint256[11] memory sizes = [uint256(1), 2, 3, 7, 10, 33, 99, 100, 101, 250, type(uint256).max];
        for (uint256 i = 0; i < sizes.length; i++) {
            _walkClaims(id, sizes[i]);
        }
    }

    function test_ClaimPagesEveryOffsetMatchesSlice() public {
        uint256 n = 37;
        uint256 id = _bountyWithClaims(n);
        BountyBoxV2.Claim[] memory all = box.getClaims(id);
        for (uint256 off = 0; off <= n + 2; off++) {
            (BountyBoxV2.Claim[] memory page, uint256 total) = box.getClaimsPage(id, off, 5);
            assertEq(total, n);
            assertEq(page.length, _expectedLen(n, off, 5));
            for (uint256 i = 0; i < page.length; i++) {
                _eqClaim(page[i], all[off + i]);
            }
        }
    }

    function test_TotalsAgree_ClaimCount() public {
        uint256 id = _bountyWithClaims(41);
        (, uint256 total) = box.getClaimsPage(id, 0, 1);
        assertEq(total, 41);
        assertEq(box.claimCount(id), 41);
        assertEq(box.getBounty(id).claimCount, 41);
        assertEq(box.getClaims(id).length, 41);
    }

    function test_ClaimLimitAboveMaxIsClampedTo100() public {
        uint256 id = _bountyWithClaims(250);
        (BountyBoxV2.Claim[] memory p, uint256 total) = box.getClaimsPage(id, 0, 100);
        assertEq(p.length, 100);
        assertEq(total, 250);
        (p,) = box.getClaimsPage(id, 0, 101);
        assertEq(p.length, 100);
        (p,) = box.getClaimsPage(id, 0, 1000);
        assertEq(p.length, 100);
        (p,) = box.getClaimsPage(id, 0, type(uint256).max);
        assertEq(p.length, 100);
        (p,) = box.getClaimsPage(id, 150, type(uint256).max);
        assertEq(p.length, 100);
        assertEq(p[0].proofURL, "proof-150");
        assertEq(p[99].proofURL, "proof-249");
        (p,) = box.getClaimsPage(id, 200, 1000);
        assertEq(p.length, 50);
        assertEq(box.MAX_PAGE_SIZE(), 100);
    }

    function test_ClaimPageEdgeInputsReturnEmptyWithoutReverting() public {
        uint256 id = _bountyWithClaims(10);
        uint256 M = type(uint256).max;
        uint256[6] memory offs = [uint256(10), 11, 1000, M - 1, M, 0];
        for (uint256 i = 0; i < 5; i++) {
            (BountyBoxV2.Claim[] memory p, uint256 total) = box.getClaimsPage(id, offs[i], 5);
            assertEq(p.length, 0);
            assertEq(total, 10);
            (p, total) = box.getClaimsPage(id, offs[i], M);
            assertEq(p.length, 0);
            assertEq(total, 10);
        }
        // limit == 0 at several offsets
        for (uint256 off = 0; off <= 12; off++) {
            (BountyBoxV2.Claim[] memory p, uint256 total) = box.getClaimsPage(id, off, 0);
            assertEq(p.length, 0);
            assertEq(total, 10);
        }
        // last element with an overflow-prone limit
        (BountyBoxV2.Claim[] memory last, uint256 t) = box.getClaimsPage(id, 9, M);
        assertEq(last.length, 1);
        assertEq(t, 10);
        assertEq(last[0].proofURL, "proof-9");
    }

    function test_ClaimPageOnBountyWithoutClaims() public {
        uint256 id = _createP();
        (BountyBoxV2.Claim[] memory p, uint256 total) = box.getClaimsPage(id, 0, 50);
        assertEq(p.length, 0);
        assertEq(total, 0);
        assertEq(box.claimCount(id), 0);
    }

    // ---------------------------------------------------------- contributors
    function test_ContributorPagesReconstructGetContributors_VariousSizes() public {
        uint256 id = _bountyWithContributors(230);
        uint256[11] memory sizes = [uint256(1), 2, 3, 7, 10, 33, 99, 100, 101, 230, type(uint256).max];
        for (uint256 i = 0; i < sizes.length; i++) {
            _walkContributors(id, sizes[i]);
        }
    }

    function test_ContributorTotalsAgree() public {
        uint256 id = _bountyWithContributors(57);
        (,, uint256 total) = box.getContributorsPage(id, 0, 1);
        assertEq(total, 57);
        assertEq(box.contributorCount(id), 57);
        assertEq(box.getBounty(id).contributorCount, 57);
        (address[] memory cs,) = box.getContributors(id);
        assertEq(cs.length, 57);
        // repeat contribution does not change any count
        _contribute(_contribAt(5), id, MIN);
        assertEq(box.contributorCount(id), 57);
        (,, total) = box.getContributorsPage(id, 0, 1);
        assertEq(total, 57);
    }

    function test_ContributorLimitAboveMaxIsClampedTo100() public {
        uint256 id = _bountyWithContributors(250);
        uint256 M = type(uint256).max;
        (address[] memory c, uint256[] memory s, uint256 total) = box.getContributorsPage(id, 0, 101);
        assertEq(c.length, 100);
        assertEq(s.length, 100);
        assertEq(total, 250);
        (c, s,) = box.getContributorsPage(id, 0, M);
        assertEq(c.length, 100);
        assertEq(s.length, 100);
        (c, s,) = box.getContributorsPage(id, 100, 100);
        assertEq(c.length, 100);
        (c, s,) = box.getContributorsPage(id, 200, 5000);
        assertEq(c.length, 50);
        assertEq(s.length, 50);
    }

    function test_ContributorPageEdgeInputsReturnEmptyWithoutReverting() public {
        uint256 id = _bountyWithContributors(10);
        uint256 M = type(uint256).max;
        uint256[5] memory offs = [uint256(10), 11, 1000, M - 1, M];
        for (uint256 i = 0; i < offs.length; i++) {
            (address[] memory c, uint256[] memory s, uint256 total) = box.getContributorsPage(id, offs[i], 5);
            assertEq(c.length, 0);
            assertEq(s.length, 0);
            assertEq(total, 10);
            (c, s, total) = box.getContributorsPage(id, offs[i], M);
            assertEq(c.length, 0);
            assertEq(s.length, 0);
            assertEq(total, 10);
        }
        for (uint256 off = 0; off <= 12; off++) {
            (address[] memory c, uint256[] memory s, uint256 total) = box.getContributorsPage(id, off, 0);
            assertEq(c.length, 0);
            assertEq(s.length, 0);
            assertEq(total, 10);
        }
        (address[] memory last,, uint256 t) = box.getContributorsPage(id, 9, M);
        assertEq(last.length, 1);
        assertEq(t, 10);
        assertEq(last[0], _contribAt(9));
    }

    function test_ContributorSharesInPagesZeroAfterRefund_CountsUnchanged() public {
        uint256 id = _bountyWithContributors(30);
        _toSettlement(id);
        // refund every third contributor (including the poster, index 0)
        uint256 refunded;
        for (uint256 i = 0; i < 30; i += 3) {
            address who = i == 0 ? poster : _contribAt(i);
            uint256 share = box.contributionOf(id, who);
            uint256 potBefore = _pots(id);
            _refund(who, id);
            assertEq(_pots(id), potBefore - share);
            refunded++;
        }
        assertEq(refunded, 10);
        assertEq(box.contributorCount(id), 30, "refunded contributors still counted");
        (address[] memory cs, uint256[] memory ss, uint256 total) = box.getContributorsPage(id, 0, 100);
        assertEq(total, 30);
        assertEq(cs.length, 30);
        uint256 sum;
        for (uint256 i = 0; i < 30; i++) {
            assertEq(ss[i], box.contributionOf(id, cs[i]));
            if (i % 3 == 0) assertEq(ss[i], 0, "refunded share is zero");
            else assertGt(ss[i], 0);
            sum += ss[i];
        }
        assertEq(sum, _pots(id), "page shares sum to pot");
        _walkContributors(id, 7);
        // a full refund keeps the list and zeroes every page share
        for (uint256 i = 1; i < 30; i++) {
            if (i % 3 != 0) _refund(_contribAt(i), id);
        }
        assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded));
        (cs, ss, total) = box.getContributorsPage(id, 0, 100);
        assertEq(total, 30);
        for (uint256 i = 0; i < ss.length; i++) {
            assertEq(ss[i], 0);
        }
    }

    function test_ContributorSharesInPagesAreHistoricalAfterPayment() public {
        uint256 id = _bountyWithContributors(12);
        uint256 cid = _claim(hunter, id);
        _accept(id, cid);
        (, uint256[] memory ss, uint256 total) = box.getContributorsPage(id, 0, 100);
        assertEq(total, 12);
        for (uint256 i = 0; i < ss.length; i++) {
            assertGt(ss[i], 0, "historical share kept");
        }
        _walkContributors(id, 5);
    }

    // --------------------------------------------------------------- unknown
    function test_UnknownBountyRevertsOnAllPagedViews() public {
        _createP();
        uint256[3] memory ids = [uint256(0), 2, type(uint256).max];
        for (uint256 i = 0; i < ids.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, ids[i]));
            box.getClaimsPage(ids[i], 0, 10);
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, ids[i]));
            box.getContributorsPage(ids[i], 0, 10);
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, ids[i]));
            box.claimCount(ids[i]);
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, ids[i]));
            box.contributorCount(ids[i]);
            // unknown bounty reverts even for degenerate paging args
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, ids[i]));
            box.getClaimsPage(ids[i], type(uint256).max, 0);
            vm.expectRevert(abi.encodeWithSelector(BountyBoxV2.BountyNotFound.selector, ids[i]));
            box.getContributorsPage(ids[i], type(uint256).max, type(uint256).max);
        }
    }

    function testFuzz_PagingNeverRevertsAndMatchesSlice(uint256 offset, uint256 limit) public {
        uint256 id = _bountyWithClaims(14);
        BountyBoxV2.Claim[] memory all = box.getClaims(id);
        (BountyBoxV2.Claim[] memory page, uint256 total) = box.getClaimsPage(id, offset, limit);
        assertEq(total, 14);
        assertEq(page.length, _expectedLen(14, offset, limit));
        for (uint256 i = 0; i < page.length; i++) {
            _eqClaim(page[i], all[offset + i]);
        }
        (address[] memory cs, uint256[] memory ss, uint256 t2) = box.getContributorsPage(id, offset, limit);
        assertEq(t2, 1);
        assertEq(cs.length, _expectedLen(1, offset, limit));
        assertEq(ss.length, cs.length);
    }
}
