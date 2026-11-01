// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BountyBoxV2} from "../BountyBoxV2.sol";
import {BountyBoxV2TestBase} from "./BountyBoxV2.Base.t.sol";

contract BountyBoxV2FuzzTest is BountyBoxV2TestBase {
    function _acct(uint256 i) internal view returns (address) {
        return address(uint160(0x10000 + i));
    }

    function _fund(address a) internal {
        usdc.mint(a, 1_000_000e6);
        vm.prank(a);
        usdc.approve(address(box), type(uint256).max);
    }

    function _tryAccept(uint256 id, bool ai) internal returns (bool ok) {
        vm.prank(ai ? judge : poster);
        if (ai) {
            try box.judgeAccept(id, 0, keccak256("v"), "ipfs://v") { ok = true; } catch {}
        } else {
            try box.acceptClaim(id, 0) { ok = true; } catch {}
        }
    }

    function _tryRefund(uint256 id) internal returns (bool ok) {
        vm.prank(poster);
        try box.refund(id) { ok = true; } catch {}
    }

    function _tryContribute(uint256 id) internal returns (bool ok) {
        vm.prank(alice);
        try box.contribute(id, AMT) { ok = true; } catch {}
    }

    function _tryClaim(uint256 id) internal returns (bool ok) {
        vm.prank(hunter2);
        try box.submitClaim(id, "u", "", "") { ok = true; } catch {}
    }

    // ---------------------------------------------------------------- grace window boundaries
    function testFuzz_GraceWindow_AcceptXorRefund(uint256 t, bool withClaim, bool ai) public {
        uint256 id = ai ? _createAI() : _createP();
        if (withClaim) _claim(hunter, id);
        uint256 settle = withClaim ? uint256(expiry) + GRACE : uint256(expiry);
        assertEq(box.refundOpensAt(id), settle);
        t = bound(t, block.timestamp, settle + 3 days);
        // bias toward boundaries
        if (t % 4 == 0) t = settle - 1 + (t / 4) % 3;
        if (t % 5 == 0) t = uint256(expiry) - 1 + (t / 5) % 3;
        if (t < block.timestamp) t = block.timestamp;

        uint256 snap = vm.snapshotState();
        vm.warp(t);
        bool canAccept = _tryAccept(id, ai);
        vm.revertToState(snap);
        vm.warp(t);
        bool canRefund = _tryRefund(id);
        vm.revertToState(snap);
        vm.warp(t);
        bool canContribute = _tryContribute(id);
        vm.revertToState(snap);
        vm.warp(t);
        bool canClaim = _tryClaim(id);

        assertEq(canAccept, withClaim && t < settle, "accept window");
        assertEq(canRefund, t >= settle, "refund window");
        assertFalse(canAccept && canRefund, "no overlap");
        assertEq(canContribute, t < expiry, "contribute window");
        assertEq(canClaim, t < expiry, "claim window");
    }

    // ---------------------------------------------------------------- random-order refunds
    function testFuzz_RefundsRandomOrder(uint8 nRaw, uint256 seed, uint256[6] memory amts, bool withClaim, bool ai)
        public
    {
        uint256 n = bound(nRaw, 2, 6);
        address[] memory cs = new address[](n);
        uint256[] memory shares = new uint256[](n);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            cs[i] = _acct(i);
            _fund(cs[i]);
            shares[i] = bound(amts[i], MIN, 500e6);
        }
        vm.prank(cs[0]);
        uint256 id = box.createBounty("T", "", ai ? "c" : "", expiry, shares[0], ai ? AI_MODE : POSTER_MODE, false);
        total = shares[0];
        for (uint256 i = 1; i < n; i++) {
            _contribute(cs[i], id, shares[i]);
            total += shares[i];
        }
        if (withClaim) _claim(hunter, id);
        assertEq(box.getBounty(id).pot, total);
        _toSettlement(id);

        // Fisher-Yates shuffle
        uint256[] memory order = new uint256[](n);
        for (uint256 i = 0; i < n; i++) order[i] = i;
        for (uint256 i = n - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }

        uint256 remaining = total;
        for (uint256 k = 0; k < n; k++) {
            uint256 who = order[k];
            uint256 bal = usdc.balanceOf(cs[who]);
            vm.expectEmit(true, true, false, true, address(box));
            emit BountyBoxV2.Refunded(id, cs[who], shares[who]);
            _refund(cs[who], id);
            remaining -= shares[who];
            assertEq(usdc.balanceOf(cs[who]), bal + shares[who], "exact share");
            assertEq(box.getBounty(id).pot, remaining);
            if (k < n - 1) {
                assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Open), "open until last");
                assertEq(uint8(_eff(id)), uint8(BountyBoxV2.EffectiveStatus.Expired));
            } else {
                assertEq(uint8(_status(id)), uint8(BountyBoxV2.Status.Refunded), "refunded after last");
            }
            vm.prank(cs[who]);
            vm.expectRevert(BountyBoxV2.NoContribution.selector);
            box.refund(id);
        }
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    // ---------------------------------------------------------------- payout = sum of shares
    function testFuzz_JudgeAcceptPaysWholePot(uint8 nRaw, uint256[6] memory amts, uint8 pick) public {
        uint256 n = bound(nRaw, 1, 6);
        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            address c = _acct(i);
            _fund(c);
            uint256 a = bound(amts[i], MIN, 500e6);
            total += a;
            if (i == 0) {
                vm.prank(c);
                box.createBounty("T", "", "c", expiry, a, AI_MODE, false);
            } else {
                _contribute(c, 1, a);
            }
        }
        _claim(hunter, 1);
        _claim(hunter2, 1);
        uint256 cid = bound(pick, 0, 1);
        address winner = cid == 0 ? hunter : hunter2;
        uint256 bal = usdc.balanceOf(winner);
        _judgeAccept(1, cid);
        assertEq(usdc.balanceOf(winner), bal + total);
        assertEq(usdc.balanceOf(address(box)), 0);
        assertEq(box.getBounty(1).paidAmount, total);
    }

    // ---------------------------------------------------------------- claim cap + handle length
    function testFuzz_ClaimCap(uint8 attempts) public {
        uint256 id = _createP();
        uint256 n = bound(attempts, 0, 8);
        uint256 ok;
        for (uint256 i = 0; i < n; i++) {
            vm.prank(hunter);
            try box.submitClaim(id, "u", "", "") { ok++; } catch {}
        }
        assertEq(ok, n > 3 ? 3 : n);
        assertEq(box.claimsBy(id, hunter), ok);
        assertEq(box.getBounty(id).claimCount, ok);
    }

    function testFuzz_HandleRules(uint256 len, bool required) public {
        len = bound(len, 0, 100);
        uint256 id = _createFull(poster, "", POSTER_MODE, required);
        vm.prank(hunter);
        if (len > 64) {
            vm.expectRevert(BountyBoxV2.HandleTooLong.selector);
        } else if (required && len == 0) {
            vm.expectRevert(BountyBoxV2.HandleRequired.selector);
        }
        box.submitClaim(id, "u", "", _str(len));
    }

    function testFuzz_ExpiryBounds(uint256 delta) public {
        delta = bound(delta, 0, 200 days);
        vm.prank(poster);
        if (delta == 0) {
            vm.expectRevert(BountyBoxV2.InvalidExpiry.selector);
        } else if (delta > 90 days) {
            vm.expectRevert(BountyBoxV2.ExpiryTooFar.selector);
        }
        box.createBounty("T", "", "", uint64(block.timestamp + delta), AMT, POSTER_MODE, false);
    }
}
