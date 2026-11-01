// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BountyBox} from "../BountyBox.sol";

interface ITokenHook {
    function onTokenReceived() external;
}

/// @dev Minimal 6-decimal ERC-20. Optionally notifies contract recipients on transfer()
///      so a malicious recipient can attempt re-entrancy.
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    bool public hookEnabled;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setHook(bool on) external {
        hookEnabled = on;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        emit Approval(msg.sender, spender, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        if (hookEnabled && to.code.length > 0) {
            try ITokenHook(to).onTokenReceived() {} catch {}
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function _move(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        emit Transfer(from, to, amt);
    }
}

/// @dev Malicious hunter / contributor: when it receives USDC it tries to re-enter BountyBox.
contract Attacker is ITokenHook {
    BountyBox public box;
    MockUSDC public usdc;
    uint8 public mode; // 0 refund, 1 acceptClaim, 2 contribute, 3 createBounty, 4 submitClaim
    uint256 public targetId;
    bool public entered;
    bool public reentrySucceeded;
    bytes public reentryRevert;

    constructor(BountyBox box_, MockUSDC usdc_) {
        box = box_;
        usdc = usdc_;
        usdc.approve(address(box_), type(uint256).max);
    }

    function setMode(uint8 m, uint256 id) external {
        mode = m;
        targetId = id;
    }

    function contribute(uint256 id, uint256 amt) external {
        box.contribute(id, amt);
    }

    function claim(uint256 id) external {
        box.submitClaim(id, "ipfs://proof", "");
    }

    function refund(uint256 id) external {
        box.refund(id);
    }

    function onTokenReceived() external {
        if (entered) return;
        entered = true;
        if (mode == 0) {
            try box.refund(targetId) { reentrySucceeded = true; } catch (bytes memory r) { reentryRevert = r; }
        } else if (mode == 1) {
            try box.acceptClaim(targetId, 0) { reentrySucceeded = true; } catch (bytes memory r) { reentryRevert = r; }
        } else if (mode == 2) {
            try box.contribute(targetId, 10_000) { reentrySucceeded = true; } catch (bytes memory r) { reentryRevert = r; }
        } else if (mode == 3) {
            try box.createBounty("x", "", uint64(block.timestamp + 1 days), 10_000) {
                reentrySucceeded = true;
            } catch (bytes memory r) {
                reentryRevert = r;
            }
        } else {
            try box.submitClaim(targetId, "ipfs://x", "") { reentrySucceeded = true; } catch (bytes memory r) { reentryRevert = r; }
        }
    }
}

contract BountyBoxTest is Test {
    BountyBox internal box;
    MockUSDC internal usdc;

    address internal poster = makeAddr("poster");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal hunter = makeAddr("hunter");
    address internal hunter2 = makeAddr("hunter2");

    uint256 internal constant AMT = 100e6;
    uint256 internal constant MIN = 10_000;
    uint64 internal expiry;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBox(address(usdc));
        expiry = uint64(block.timestamp + 7 days);

        address[6] memory who = [poster, alice, bob, carol, hunter, hunter2];
        for (uint256 i = 0; i < who.length; i++) {
            usdc.mint(who[i], 10_000e6);
            vm.prank(who[i]);
            usdc.approve(address(box), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- helpers
    function _create() internal returns (uint256 id) {
        vm.prank(poster);
        id = box.createBounty("Title", "Desc", expiry, AMT);
    }

    function _contribute(address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        box.contribute(id, amt);
    }

    function _claim(address who, uint256 id) internal returns (uint256 cid) {
        vm.prank(who);
        cid = box.submitClaim(id, "ipfs://proof", "note");
    }

    function _str(uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) b[i] = "a";
        return string(b);
    }

    // ---------------------------------------------------------------- constructor
    function test_Constructor_StoresUsdc() public view {
        assertEq(address(box.usdc()), address(usdc));
        assertEq(box.bountyCount(), 0);
        assertEq(box.MIN_AMOUNT(), MIN);
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(BountyBox.ZeroAddress.selector);
        new BountyBox(address(0));
    }

    // ---------------------------------------------------------------- createBounty
    function test_Create_SetsState() public {
        uint256 id = _create();
        assertEq(id, 1);
        assertEq(box.bountyCount(), 1);
        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(b.id, 1);
        assertEq(b.poster, poster);
        assertEq(b.title, "Title");
        assertEq(b.description, "Desc");
        assertEq(b.expiry, expiry);
        assertEq(b.pot, AMT);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Open));
        assertFalse(b.hasAccepted);
        assertEq(b.winner, address(0));
        assertEq(b.winningClaimId, 0);
        assertEq(b.paidAmount, 0);
        assertEq(b.claimCount, 0);
        assertEq(b.contributorCount, 1);
        assertEq(b.createdAt, block.timestamp);
        assertEq(box.contributionOf(id, poster), AMT);
        (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
        assertEq(cs.length, 1);
        assertEq(cs[0], poster);
        assertEq(sh[0], AMT);
    }

    function test_Create_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.BountyCreated(1, poster, "Title", expiry, AMT);
        vm.prank(poster);
        box.createBounty("Title", "Desc", expiry, AMT);
    }

    function test_Create_EscrowsFunds() public {
        uint256 before = usdc.balanceOf(poster);
        _create();
        assertEq(usdc.balanceOf(address(box)), AMT);
        assertEq(usdc.balanceOf(poster), before - AMT);
    }

    function test_Create_IncrementsIds() public {
        _create();
        vm.prank(alice);
        uint256 id2 = box.createBounty("Other", "", expiry, MIN);
        assertEq(id2, 2);
        assertEq(box.getBounty(2).poster, alice);
        assertEq(usdc.balanceOf(address(box)), AMT + MIN);
    }

    function test_Create_AcceptsBoundaryValues() public {
        vm.startPrank(poster);
        box.createBounty(_str(100), _str(2000), uint64(block.timestamp + 1), MIN);
        box.createBounty("a", "", expiry, MIN);
        vm.stopPrank();
        assertEq(box.bountyCount(), 2);
    }

    function test_Create_RevertsOnPastExpiry() public {
        vm.prank(poster);
        vm.expectRevert(BountyBox.InvalidExpiry.selector);
        box.createBounty("T", "", uint64(block.timestamp - 1), AMT);
    }

    function test_Create_RevertsOnExpiryEqualNow() public {
        vm.prank(poster);
        vm.expectRevert(BountyBox.InvalidExpiry.selector);
        box.createBounty("T", "", uint64(block.timestamp), AMT);
    }

    function test_Create_RevertsBelowMinAmount() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AmountTooSmall.selector, MIN - 1));
        box.createBounty("T", "", expiry, MIN - 1);
    }

    function test_Create_RevertsOnEmptyTitle() public {
        vm.prank(poster);
        vm.expectRevert(BountyBox.InvalidTitleLength.selector);
        box.createBounty("", "", expiry, AMT);
    }

    function test_Create_RevertsOnLongTitle() public {
        string memory t = _str(101);
        vm.prank(poster);
        vm.expectRevert(BountyBox.InvalidTitleLength.selector);
        box.createBounty(t, "", expiry, AMT);
    }

    function test_Create_RevertsOnLongDescription() public {
        string memory d = _str(2001);
        vm.prank(poster);
        vm.expectRevert(BountyBox.DescriptionTooLong.selector);
        box.createBounty("T", d, expiry, AMT);
    }

    function test_Create_RevertsWithoutAllowance() public {
        address nobody = makeAddr("nobody");
        usdc.mint(nobody, AMT);
        vm.prank(nobody);
        vm.expectRevert();
        box.createBounty("T", "", expiry, AMT);
    }

    // ---------------------------------------------------------------- contribute
    function test_Contribute_TracksShares() public {
        uint256 id = _create();
        _contribute(alice, id, 50e6);
        _contribute(bob, id, 25e6);
        assertEq(box.contributionOf(id, poster), AMT);
        assertEq(box.contributionOf(id, alice), 50e6);
        assertEq(box.contributionOf(id, bob), 25e6);
        assertEq(box.getBounty(id).pot, AMT + 75e6);
        assertEq(box.getBounty(id).contributorCount, 3);
        assertEq(usdc.balanceOf(address(box)), AMT + 75e6);
    }

    function test_Contribute_EmitsEvent() public {
        uint256 id = _create();
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.Contributed(id, alice, 50e6, AMT + 50e6);
        _contribute(alice, id, 50e6);
    }

    function test_Contribute_RepeatContributorAccumulatesWithoutDuplicate() public {
        uint256 id = _create();
        _contribute(alice, id, 50e6);
        _contribute(alice, id, 30e6);
        assertEq(box.contributionOf(id, alice), 80e6);
        assertEq(box.getBounty(id).contributorCount, 2);
        (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
        assertEq(cs.length, 2);
        assertEq(cs[1], alice);
        assertEq(sh[1], 80e6);
    }

    function test_Contribute_PosterTopUpDoesNotDuplicate() public {
        uint256 id = _create();
        _contribute(poster, id, 5e6);
        assertEq(box.contributionOf(id, poster), AMT + 5e6);
        (address[] memory cs,) = box.getContributors(id);
        assertEq(cs.length, 1);
    }

    function test_Contribute_ContributorsListOrder() public {
        uint256 id = _create();
        _contribute(carol, id, MIN);
        _contribute(alice, id, MIN);
        _contribute(bob, id, MIN);
        (address[] memory cs,) = box.getContributors(id);
        assertEq(cs.length, 4);
        assertEq(cs[0], poster);
        assertEq(cs[1], carol);
        assertEq(cs[2], alice);
        assertEq(cs[3], bob);
    }

    function test_Contribute_RevertsBelowMin() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AmountTooSmall.selector, MIN - 1));
        box.contribute(id, MIN - 1);
    }

    function test_Contribute_RevertsAtExpiry() public {
        uint256 id = _create();
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
        box.contribute(id, AMT);
    }

    function test_Contribute_OkOneSecondBeforeExpiry() public {
        uint256 id = _create();
        vm.warp(expiry - 1);
        _contribute(alice, id, AMT);
        assertEq(box.getBounty(id).pot, 2 * AMT);
    }

    function test_Contribute_RevertsAfterPaid() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.contribute(id, AMT);
    }

    function test_Contribute_RevertsUnknownBounty() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 99));
        box.contribute(99, AMT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 0));
        box.contribute(0, AMT);
    }

    // ---------------------------------------------------------------- submitClaim
    function test_SubmitClaim_HappyPath() public {
        uint256 id = _create();
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.ClaimSubmitted(id, 0, hunter, "ipfs://proof");
        uint256 c0 = _claim(hunter, id);
        uint256 c1 = _claim(hunter2, id);
        assertEq(c0, 0);
        assertEq(c1, 1);
        assertEq(box.getBounty(id).claimCount, 2);
        BountyBox.Claim memory c = box.getClaim(id, 0);
        assertEq(c.hunter, hunter);
        assertEq(c.proofURL, "ipfs://proof");
        assertEq(c.note, "note");
        assertEq(c.timestamp, block.timestamp);
        assertEq(box.getClaim(id, 1).hunter, hunter2);
        assertEq(box.getClaims(id).length, 2);
    }

    function test_SubmitClaim_MultipleFromSameHunterAllowed() public {
        uint256 id = _create();
        _claim(hunter, id);
        assertEq(_claim(hunter, id), 1);
    }

    function test_SubmitClaim_PosterBlocked() public {
        uint256 id = _create();
        vm.prank(poster);
        vm.expectRevert(BountyBox.PosterCannotSubmitClaim.selector);
        box.submitClaim(id, "ipfs://p", "");
    }

    function test_SubmitClaim_RevertsEmptyProof() public {
        uint256 id = _create();
        vm.prank(hunter);
        vm.expectRevert(BountyBox.InvalidProofURLLength.selector);
        box.submitClaim(id, "", "");
    }

    function test_SubmitClaim_RevertsLongProof() public {
        uint256 id = _create();
        string memory p = _str(501);
        vm.prank(hunter);
        vm.expectRevert(BountyBox.InvalidProofURLLength.selector);
        box.submitClaim(id, p, "");
    }

    function test_SubmitClaim_AcceptsMaxLengths() public {
        uint256 id = _create();
        vm.prank(hunter);
        box.submitClaim(id, _str(500), _str(500));
        assertEq(box.getBounty(id).claimCount, 1);
    }

    function test_SubmitClaim_RevertsLongNote() public {
        uint256 id = _create();
        string memory n = _str(501);
        vm.prank(hunter);
        vm.expectRevert(BountyBox.NoteTooLong.selector);
        box.submitClaim(id, "ipfs://p", n);
    }

    function test_SubmitClaim_RevertsAfterExpiry() public {
        uint256 id = _create();
        vm.warp(expiry);
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyExpired.selector, id));
        box.submitClaim(id, "ipfs://p", "");
    }

    function test_SubmitClaim_RevertsAfterPaid() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.prank(hunter2);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.submitClaim(id, "ipfs://p", "");
    }

    function test_SubmitClaim_RevertsUnknownBounty() public {
        vm.prank(hunter);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 5));
        box.submitClaim(5, "ipfs://p", "");
    }

    function test_Views_RevertOnUnknown() public {
        uint256 id = _create();
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 7));
        box.getBounty(7);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 7));
        box.getClaims(7);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 7));
        box.getContributors(7);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 7));
        box.contributionOf(7, alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 7));
        box.getClaim(7, 0);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.ClaimNotFound.selector, id, 0));
        box.getClaim(id, 0);
    }

    // ---------------------------------------------------------------- acceptClaim
    function test_Accept_PaysFullPotToHunter() public {
        uint256 id = _create();
        _contribute(alice, id, 50e6);
        _contribute(bob, id, 25e6);
        _claim(hunter, id);
        uint256 pot = AMT + 75e6;
        uint256 before = usdc.balanceOf(hunter);

        vm.prank(poster);
        box.acceptClaim(id, 0);

        assertEq(usdc.balanceOf(hunter), before + pot);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_Accept_ClosesBountyAndRecordsWinner() public {
        uint256 id = _create();
        _contribute(alice, id, 50e6);
        _claim(hunter, id);
        _claim(hunter2, id);

        vm.prank(poster);
        box.acceptClaim(id, 1);

        BountyBox.Bounty memory b = box.getBounty(id);
        assertEq(uint8(b.status), uint8(BountyBox.Status.Paid));
        assertTrue(b.hasAccepted);
        assertEq(b.winner, hunter2);
        assertEq(b.winningClaimId, 1);
        assertEq(b.paidAmount, AMT + 50e6);
        assertEq(b.pot, 0);
        assertEq(usdc.balanceOf(hunter), 10_000e6); // loser untouched
        // historical share remains recorded
        assertEq(box.contributionOf(id, alice), 50e6);
    }

    function test_Accept_EmitsEvent() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.expectEmit(true, true, true, true, address(box));
        emit BountyBox.ClaimAccepted(id, 0, hunter, AMT);
        vm.prank(poster);
        box.acceptClaim(id, 0);
    }

    function test_Accept_OkOneSecondBeforeExpiry() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.warp(expiry - 1);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertEq(box.getBounty(id).winner, hunter);
    }

    function test_Accept_DoubleAcceptReverts() public {
        uint256 id = _create();
        _claim(hunter, id);
        _claim(hunter2, id);
        vm.startPrank(poster);
        box.acceptClaim(id, 0);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.acceptClaim(id, 0);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.acceptClaim(id, 1);
        vm.stopPrank();
    }

    function test_Accept_NonPosterReverts() public {
        uint256 id = _create();
        _contribute(alice, id, AMT);
        _claim(hunter, id);
        address[3] memory bad = [alice, hunter, bob];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(BountyBox.OnlyPoster.selector);
            box.acceptClaim(id, 0);
        }
    }

    /// @dev Old behaviour (accept strictly before expiry) is gone: at expiry a claimed bounty is in grace.
    function test_Accept_OkAtExpiryWhenClaimed() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.warp(expiry);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertEq(box.getBounty(id).winner, hunter);
    }

    function test_Accept_RevertsWhenNoClaimsAtExpiry() public {
        uint256 id = _create();
        vm.warp(expiry);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
    }

    function test_Accept_RevertsUnknownClaim() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.ClaimNotFound.selector, id, 1));
        box.acceptClaim(id, 1);
    }

    function test_Accept_RevertsWhenNoClaims() public {
        uint256 id = _create();
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.ClaimNotFound.selector, id, 0));
        box.acceptClaim(id, 0);
    }

    function test_Accept_RevertsUnknownBounty() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 3));
        box.acceptClaim(3, 0);
    }

    function test_Accept_DoesNotAffectOtherBounty() public {
        uint256 id1 = _create();
        vm.prank(alice);
        uint256 id2 = box.createBounty("Other", "", expiry, 40e6);
        _claim(hunter, id1);
        vm.prank(poster);
        box.acceptClaim(id1, 0);
        assertEq(usdc.balanceOf(address(box)), 40e6);
        assertEq(box.getBounty(id2).pot, 40e6);
    }

    // ---------------------------------------------------------------- refund
    function test_Refund_EachContributorWithdrawsOwnShare() public {
        uint256 id = _create();
        _contribute(alice, id, 50e6);
        _contribute(bob, id, 25e6);
        vm.warp(expiry);

        uint256 aBefore = usdc.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(box));
        emit BountyBox.Refunded(id, alice, 50e6);
        vm.prank(alice);
        box.refund(id);
        assertEq(usdc.balanceOf(alice), aBefore + 50e6);
        assertEq(box.getBounty(id).pot, AMT + 25e6);
        assertEq(box.contributionOf(id, alice), 0);
        assertEq(usdc.balanceOf(address(box)), AMT + 25e6);
        // not the last withdrawal: bounty stays Open
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Open));

        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        box.refund(id);
        assertEq(usdc.balanceOf(bob), bBefore + 25e6);
        assertEq(box.getBounty(id).pot, AMT);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Open));

        uint256 pBefore = usdc.balanceOf(poster);
        vm.prank(poster);
        box.refund(id);
        assertEq(usdc.balanceOf(poster), pBefore + AMT);
        assertEq(box.getBounty(id).pot, 0);
        // last withdrawal flips to Refunded
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Refunded));
        assertEq(usdc.balanceOf(address(box)), 0);
        // contributor count and list retain refunded entries; shares are zero
        assertEq(box.getBounty(id).contributorCount, 3);
        (address[] memory cs, uint256[] memory sh) = box.getContributors(id);
        assertEq(cs.length, 3);
        assertEq(sh[0] + sh[1] + sh[2], 0);
    }

    function test_Refund_OneContributorDoesNotAffectOthers() public {
        uint256 id = _create();
        _contribute(alice, id, 50e6);
        vm.warp(expiry + 1 days);
        vm.prank(alice);
        box.refund(id);
        assertEq(box.contributionOf(id, poster), AMT);
        assertEq(box.getBounty(id).pot, AMT);
        assertEq(uint8(box.getBounty(id).status), uint8(BountyBox.Status.Open));
    }

    function test_Refund_DoubleRefundReverts() public {
        uint256 id = _create();
        vm.warp(expiry);
        vm.startPrank(poster);
        box.refund(id);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
        vm.stopPrank();
    }

    function test_Refund_NonContributorReverts() public {
        uint256 id = _create();
        vm.warp(expiry);
        vm.prank(carol);
        vm.expectRevert(BountyBox.NoContribution.selector);
        box.refund(id);
    }

    function test_Refund_BeforeExpiryReverts() public {
        uint256 id = _create();
        vm.warp(expiry - 1);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.RefundNotOpen.selector, id, uint256(expiry)));
        box.refund(id);
    }

    function test_Refund_AfterAcceptReverts() public {
        uint256 id = _create();
        _contribute(alice, id, AMT);
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        vm.warp(expiry + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.refund(id);
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.refund(id);
    }

    function test_Refund_RevertsUnknownBounty() public {
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotFound.selector, 4));
        box.refund(4);
    }

    function test_AfterAccept_ContributeAndClaimRevert() public {
        uint256 id = _create();
        _claim(hunter, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.contribute(id, AMT);
        vm.prank(hunter2);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.BountyNotOpen.selector, id));
        box.submitClaim(id, "ipfs://p", "");
    }

    function test_PastSettlementCannotBeAcceptedEvenWithClaims_ThenRefundable() public {
        uint256 id = _create();
        _contribute(alice, id, 20e6);
        _claim(hunter, id);
        vm.warp(uint256(expiry) + box.GRACE_PERIOD());
        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(BountyBox.AcceptWindowClosed.selector, id));
        box.acceptClaim(id, 0);
        vm.prank(alice);
        box.refund(id);
        assertEq(box.getBounty(id).pot, AMT);
    }

    // ---------------------------------------------------------------- reentrancy
    function _assertReentryBlocked(Attacker a) internal view {
        assertTrue(a.entered(), "hook not triggered");
        assertFalse(a.reentrySucceeded(), "reentry succeeded");
        assertEq(bytes4(a.reentryRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_Reentrancy_MaliciousHunterOnAccept_Refund() public {
        usdc.setHook(true);
        Attacker a = new Attacker(box, usdc);
        uint256 id = _create();
        a.claim(id);
        a.setMode(0, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        _assertReentryBlocked(a);
        assertEq(usdc.balanceOf(address(a)), AMT);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_Reentrancy_MaliciousHunterOnAccept_Accept() public {
        usdc.setHook(true);
        Attacker a = new Attacker(box, usdc);
        uint256 id = _create();
        a.claim(id);
        a.setMode(1, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        _assertReentryBlocked(a);
        assertEq(usdc.balanceOf(address(a)), AMT);
    }

    function test_Reentrancy_MaliciousHunterOnAccept_Contribute() public {
        usdc.setHook(true);
        Attacker a = new Attacker(box, usdc);
        usdc.mint(address(a), 1e6);
        uint256 id = _create();
        a.claim(id);
        a.setMode(2, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        _assertReentryBlocked(a);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function test_Reentrancy_MaliciousHunterOnAccept_CreateAndClaim() public {
        usdc.setHook(true);
        Attacker a = new Attacker(box, usdc);
        usdc.mint(address(a), 1e6);
        uint256 id = _create();
        a.claim(id);
        a.setMode(3, id);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        _assertReentryBlocked(a);
        assertEq(box.bountyCount(), 1);
    }

    function test_Reentrancy_MaliciousRefunderCannotDoubleRefund() public {
        usdc.setHook(true);
        Attacker a = new Attacker(box, usdc);
        usdc.mint(address(a), 50e6);
        uint256 id = _create();
        a.contribute(id, 50e6);
        vm.warp(expiry);
        a.setMode(0, id);
        a.refund(id);
        _assertReentryBlocked(a);
        assertEq(usdc.balanceOf(address(a)), 50e6);
        // poster's funds still fully backed
        assertEq(usdc.balanceOf(address(box)), AMT);
        assertEq(box.getBounty(id).pot, AMT);
    }

    // ---------------------------------------------------------------- fuzz
    /// @dev Three contributors across two bounties; sum(shares) == pot and balance == sum(open pots).
    function testFuzz_ContributionAccounting(uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint8 pick) public {
        uint256 id1 = _create();
        vm.prank(alice);
        uint256 id2 = box.createBounty("Second", "", expiry, MIN);

        address[3] memory who = [alice, bob, carol];
        uint256[4] memory amts = [a1, a2, a3, a4];
        for (uint256 i = 0; i < 4; i++) {
            uint256 amt = bound(amts[i], MIN, 500e6);
            uint256 id = ((uint256(pick) >> i) & 1) == 0 ? id1 : id2;
            _contribute(who[(i + pick) % 3], id, amt);
        }

        uint256 sum1 = _sumShares(id1);
        uint256 sum2 = _sumShares(id2);
        assertEq(sum1, box.getBounty(id1).pot, "pot1");
        assertEq(sum2, box.getBounty(id2).pot, "pot2");
        assertEq(usdc.balanceOf(address(box)), sum1 + sum2, "balance");
    }

    /// @dev After expiry every contributor can recover exactly their share and the box empties.
    function testFuzz_RefundsReturnExactShares(uint256 a1, uint256 a2, uint256 a3) public {
        uint256 id = _create();
        uint256 x = bound(a1, MIN, 500e6);
        uint256 y = bound(a2, MIN, 500e6);
        uint256 z = bound(a3, MIN, 500e6);
        _contribute(alice, id, x);
        _contribute(bob, id, y);
        _contribute(alice, id, z);
        vm.warp(expiry);

        uint256 aBefore = usdc.balanceOf(alice);
        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        box.refund(id);
        vm.prank(bob);
        box.refund(id);
        vm.prank(poster);
        box.refund(id);
        assertEq(usdc.balanceOf(alice), aBefore + x + z);
        assertEq(usdc.balanceOf(bob), bBefore + y);
        assertEq(box.getBounty(id).pot, 0);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    /// @dev The hunter receives exactly the sum of all shares.
    function testFuzz_AcceptPaysExactPot(uint256 a1, uint256 a2) public {
        uint256 id = _create();
        uint256 x = bound(a1, MIN, 500e6);
        uint256 y = bound(a2, MIN, 500e6);
        _contribute(alice, id, x);
        _contribute(bob, id, y);
        _claim(hunter, id);
        uint256 before = usdc.balanceOf(hunter);
        vm.prank(poster);
        box.acceptClaim(id, 0);
        assertEq(usdc.balanceOf(hunter), before + AMT + x + y);
        assertEq(box.getBounty(id).paidAmount, AMT + x + y);
        assertEq(usdc.balanceOf(address(box)), 0);
    }

    function _sumShares(uint256 id) internal view returns (uint256 s) {
        (, uint256[] memory sh) = box.getContributors(id);
        for (uint256 i = 0; i < sh.length; i++) s += sh[i];
    }
}

/// @dev Bounded action surface for the invariant fuzzer.
contract BountyBoxHandler is Test {
    BountyBox public box;
    MockUSDC public usdc;
    address[] internal actors;
    uint256 public calls;

    constructor(BountyBox box_, MockUSDC usdc_) {
        box = box_;
        usdc = usdc_;
        for (uint256 i = 0; i < 5; i++) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            vm.prank(a);
            usdc.approve(address(box_), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _id(uint256 seed) internal view returns (uint256) {
        uint256 n = box.bountyCount();
        return n == 0 ? 0 : (seed % n) + 1;
    }

    function create(uint256 actorSeed, uint256 amount, uint256 dur) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 10_000, 1_000e6);
        dur = bound(dur, 1, 10 days);
        usdc.mint(a, amount);
        vm.prank(a);
        box.createBounty("T", "", uint64(block.timestamp + dur), amount);
        calls++;
    }

    function contribute(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 10_000, 1_000e6);
        usdc.mint(a, amount);
        uint256 id = _id(idSeed); // external read must happen BEFORE vm.prank
        vm.prank(a);
        try box.contribute(id, amount) {} catch {}
        calls++;
    }

    function submitClaim(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _id(idSeed);
        vm.prank(_actor(actorSeed));
        try box.submitClaim(id, "ipfs://p", "") {} catch {}
        calls++;
    }

    function accept(uint256 actorSeed, uint256 idSeed, uint256 claimSeed) external {
        uint256 id = _id(idSeed);
        if (id == 0) return;
        uint256 n = box.getBounty(id).claimCount;
        if (n == 0) return;
        address poster = box.getBounty(id).poster;
        vm.prank(poster);
        try box.acceptClaim(id, claimSeed % n) {} catch {}
        calls++;
        actorSeed;
    }

    function refund(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = _id(idSeed);
        vm.prank(_actor(actorSeed));
        try box.refund(id) {} catch {}
        calls++;
    }

    function warp(uint256 dt) external {
        skip(bound(dt, 1, 3 days));
    }
}

contract BountyBoxInvariantTest is Test {
    BountyBox internal box;
    MockUSDC internal usdc;
    BountyBoxHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        box = new BountyBox(address(usdc));
        handler = new BountyBoxHandler(box, usdc);
        targetContract(address(handler));
    }

    /// @dev Refunded <=> (unpaid and pot == 0): an unpaid bounty stays Open until its last share is withdrawn.
    function invariant_RefundedIffPotZero() public view {
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            if (b.status == BountyBox.Status.Paid) continue;
            assertEq(b.status == BountyBox.Status.Refunded, b.pot == 0, "Refunded iff pot==0");
            if (b.status == BountyBox.Status.Refunded) assertEq(_sumShares(id), 0, "Refunded with shares");
        }
    }

    function _sumShares(uint256 id) internal view returns (uint256 s) {
        (, uint256[] memory sh) = box.getContributors(id);
        for (uint256 i = 0; i < sh.length; i++) s += sh[i];
    }

    /// @dev Contract USDC balance == sum of pots of all Open/Refunded (refunding) bounties (Paid hold 0).
    function invariant_BalanceEqualsSumOfOpenPots() public view {
        uint256 total;
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            if (b.status != BountyBox.Status.Paid) total += b.pot;
            else assertEq(b.pot, 0, "paid bounty holds funds");
        }
        assertEq(usdc.balanceOf(address(box)), total);
    }

    /// @dev hasAccepted <=> Paid; Refunded/Open bounties never record a winner.
    function invariant_HasAcceptedIffPaid() public view {
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            assertEq(b.hasAccepted, b.status == BountyBox.Status.Paid, "hasAccepted/status mismatch");
            if (!b.hasAccepted) assertEq(b.winner, address(0), "winner without accept");
        }
    }

    /// @dev For every unpaid bounty (Open or Refunded) the sum of recorded shares equals its pot.
    function invariant_SharesSumEqualsPot() public view {
        uint256 n = box.bountyCount();
        for (uint256 id = 1; id <= n; id++) {
            BountyBox.Bounty memory b = box.getBounty(id);
            if (b.status == BountyBox.Status.Paid) continue;
            (, uint256[] memory sh) = box.getContributors(id);
            uint256 s;
            for (uint256 i = 0; i < sh.length; i++) s += sh[i];
            assertEq(s, b.pot, "shares != pot");
        }
    }
}
