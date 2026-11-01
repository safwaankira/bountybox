// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BountyBox
 * @notice Permissionless, poster-selected bounties escrowed in six-decimal USDC.
 * @dev On Arc, pass 0x3600000000000000000000000000000000000000 as usdc_.
 * The token must transfer exact amounts without fees or rebasing. No native currency is used.
 * Contributions and claims close strictly at expiry. If claims exist, acceptance remains open
 * until expiry + GRACE_PERIOD; otherwise settlement time is expiry. Refunds open at settlement time.
 * A junk claim can delay refunds by at most GRACE_PERIOD; acceptance and refunds never overlap.
 * There is no administrator, upgrade mechanism, pause, or discretionary withdrawal.
 */
contract BountyBox is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum deposit in base units: 0.01 USDC at six decimals.
    uint256 public constant MIN_AMOUNT = 10_000;

    /// @notice Additional acceptance window after expiry when at least one claim exists.
    uint256 public constant GRACE_PERIOD = 7 days;

    /// @notice Maximum time between bounty creation and expiry.
    uint256 public constant MAX_DURATION = 90 days;

    /// @notice Maximum number of claims one hunter may submit to a single bounty.
    uint256 public constant MAX_CLAIMS_PER_HUNTER = 3;

    /// @notice ERC-20 used for every deposit, award, and refund.
    IERC20 public immutable usdc;

    /// @notice Number of bounties created; valid IDs are 1 through bountyCount.
    uint256 public bountyCount;

    /// @notice Refunded is set only when the last contributor withdraws and the pot reaches zero.
    enum Status { Open, Paid, Refunded }

    /// @notice Bounty details, including live escrow and historical award information.
    /// @dev winningClaimId is meaningful only when hasAccepted is true; zero is a valid claim ID.
    struct Bounty {
        uint256 id;
        address poster;
        string title;
        string description;
        uint64 expiry;
        uint256 pot;
        Status status;
        bool hasAccepted;
        address winner;
        uint256 winningClaimId;
        uint256 paidAmount;
        uint256 claimCount;
        uint256 contributorCount;
        uint256 createdAt;
    }

    /// @notice A hunter's immutable submission; timestamp is in Unix seconds.
    struct Claim {
        address hunter;
        string proofURL;
        string note;
        uint256 timestamp;
    }

    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => Claim[]) private _claims;
    mapping(uint256 => address[]) private _contributors;
    mapping(uint256 => mapping(address => uint256)) private contributions;
    mapping(uint256 => mapping(address => uint256)) private _claimsBy;

    error ZeroAddress();
    error BountyNotFound(uint256 bountyId);
    error BountyNotOpen(uint256 bountyId);
    error BountyExpired(uint256 bountyId);
    error AcceptWindowClosed(uint256 bountyId);
    error RefundNotOpen(uint256 bountyId, uint256 opensAt);
    error InvalidExpiry();
    error ExpiryTooFar();
    error AmountTooSmall(uint256 amount);
    error InvalidTitleLength();
    error DescriptionTooLong();
    error InvalidProofURLLength();
    error NoteTooLong();
    error PosterCannotSubmitClaim();
    error TooManyClaims(uint256 bountyId, address hunter);
    error OnlyPoster();
    error ClaimNotFound(uint256 bountyId, uint256 claimId);
    error NoContribution();

    event BountyCreated(uint256 indexed id, address indexed poster, string title, uint64 expiry, uint256 amount);
    event Contributed(uint256 indexed id, address indexed contributor, uint256 amount, uint256 newPot);
    event ClaimSubmitted(uint256 indexed id, uint256 indexed claimId, address indexed hunter, string proofURL);
    event ClaimAccepted(uint256 indexed id, uint256 indexed claimId, address indexed hunter, uint256 amount);
    event Refunded(uint256 indexed id, address indexed contributor, uint256 amount);

    /// @param usdc_ Six-decimal USDC ERC-20 address; must not be zero.
    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    /**
     * @notice Create a bounty and escrow the caller's initial contribution.
     * @dev Caller must first approve this contract for amount. All string limits are byte lengths.
     * @param title Nonempty title, at most 100 bytes.
     * @param description Description, at most 2000 bytes.
     * @param expiry Future Unix timestamp within MAX_DURATION, exclusive for contributions and claims.
     * Acceptance extends by GRACE_PERIOD when claims exist; refunds open at that settlement time.
     * @param amount Initial contribution in USDC base units, at least MIN_AMOUNT.
     * @return bountyId The newly assigned ID, starting at 1.
     */
    function createBounty(
        string calldata title,
        string calldata description,
        uint64 expiry,
        uint256 amount
    ) external nonReentrant returns (uint256 bountyId) {
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (expiry > block.timestamp + MAX_DURATION) revert ExpiryTooFar();
        if (amount < MIN_AMOUNT) revert AmountTooSmall(amount);
        if (bytes(title).length == 0 || bytes(title).length > 100) revert InvalidTitleLength();
        if (bytes(description).length > 2000) revert DescriptionTooLong();

        bountyId = ++bountyCount;
        Bounty storage bounty = _bounties[bountyId];
        bounty.id = bountyId;
        bounty.poster = msg.sender;
        bounty.title = title;
        bounty.description = description;
        bounty.expiry = expiry;
        bounty.pot = amount;
        bounty.status = Status.Open;
        bounty.contributorCount = 1;
        bounty.createdAt = block.timestamp;
        contributions[bountyId][msg.sender] = amount;
        _contributors[bountyId].push(msg.sender);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit BountyCreated(bountyId, msg.sender, title, expiry, amount);
    }

    /// @notice Add at least MIN_AMOUNT base units to an Open, unexpired bounty.
    /// @dev Requires prior token approval. Each contributor appears only once in the address list.
    function contribute(uint256 bountyId, uint256 amount) external nonReentrant {
        Bounty storage bounty = _getBounty(bountyId);
        _requireActive(bounty);
        if (amount < MIN_AMOUNT) revert AmountTooSmall(amount);

        if (contributions[bountyId][msg.sender] == 0) {
            _contributors[bountyId].push(msg.sender);
            ++bounty.contributorCount;
        }
        contributions[bountyId][msg.sender] += amount;
        bounty.pot += amount;
        uint256 newPot = bounty.pot;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Contributed(bountyId, msg.sender, amount, newPot);
    }

    /**
     * @notice Submit proof for an Open, unexpired bounty; the poster cannot submit.
     * @dev Each hunter may submit at most MAX_CLAIMS_PER_HUNTER claims per bounty.
     * @param bountyId Existing bounty ID.
     * @param proofURL Nonempty proof URL, at most 500 bytes; content is not validated on-chain.
     * @param note Optional note, at most 500 bytes.
     * @return claimId Zero-based index within this bounty's claims.
     */
    function submitClaim(
        uint256 bountyId,
        string calldata proofURL,
        string calldata note
    ) external nonReentrant returns (uint256 claimId) {
        Bounty storage bounty = _getBounty(bountyId);
        _requireActive(bounty);
        if (msg.sender == bounty.poster) revert PosterCannotSubmitClaim();
        if (_claimsBy[bountyId][msg.sender] >= MAX_CLAIMS_PER_HUNTER) revert TooManyClaims(bountyId, msg.sender);
        if (bytes(proofURL).length == 0 || bytes(proofURL).length > 500) revert InvalidProofURLLength();
        if (bytes(note).length > 500) revert NoteTooLong();

        claimId = _claims[bountyId].length;
        _claims[bountyId].push(Claim({
            hunter: msg.sender,
            proofURL: proofURL,
            note: note,
            timestamp: block.timestamp
        }));
        ++bounty.claimCount;
        ++_claimsBy[bountyId][msg.sender];
        emit ClaimSubmitted(bountyId, claimId, msg.sender, proofURL);
    }

    /**
     * @notice Poster awards the entire pot to one submitted hunter, strictly before settlement time.
     * @dev Settlement time is expiry + GRACE_PERIOD when claims exist, or expiry otherwise.
     * All award state is finalized before transfer. At or after settlement time only refunds are possible,
     * removing the accept-versus-refund race. Historical contributions remain recorded after payment.
     * Payment is pushed atomically: if the token rejects the hunter (for example a USDC blocklist),
     * the whole call reverts, nothing is locked, and the poster can accept a different claim.
     */
    function acceptClaim(uint256 bountyId, uint256 claimId) external nonReentrant {
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.status != Status.Open) revert BountyNotOpen(bountyId);
        if (block.timestamp >= _settlementTime(bounty)) revert AcceptWindowClosed(bountyId);
        if (msg.sender != bounty.poster) revert OnlyPoster();
        if (claimId >= _claims[bountyId].length) revert ClaimNotFound(bountyId, claimId);

        address hunter = _claims[bountyId][claimId].hunter;
        uint256 amount = bounty.pot;
        bounty.status = Status.Paid;
        bounty.hasAccepted = true;
        bounty.winner = hunter;
        bounty.winningClaimId = claimId;
        bounty.paidAmount = amount;
        bounty.pot = 0;

        usdc.safeTransfer(hunter, amount);
        emit ClaimAccepted(bountyId, claimId, hunter, amount);
    }

    /// @notice Withdraw only the caller's contribution from an unpaid bounty at or after settlement time.
    /// @dev Opens at expiry + GRACE_PERIOD when claims exist, or expiry otherwise. The poster may refund too.
    /// The bounty stays Open (and expired) until the last share is withdrawn; only when the pot reaches
    /// zero does it become Refunded. Until then every remaining contributor can refund their own share.
    function refund(uint256 bountyId) external nonReentrant {
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.status == Status.Paid) revert BountyNotOpen(bountyId);
        uint256 opensAt = _settlementTime(bounty);
        if (block.timestamp < opensAt) revert RefundNotOpen(bountyId, opensAt);
        uint256 amount = contributions[bountyId][msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[bountyId][msg.sender] = 0;
        bounty.pot -= amount;
        if (bounty.pot == 0) bounty.status = Status.Refunded;

        usdc.safeTransfer(msg.sender, amount);
        emit Refunded(bountyId, msg.sender, amount);
    }

    /// @notice Return all bounty metadata; reverts with BountyNotFound for an unknown ID.
    function getBounty(uint256 bountyId) external view returns (Bounty memory) {
        return _getBounty(bountyId);
    }

    /// @notice Return one zero-indexed claim; reverts if the bounty or claim does not exist.
    function getClaim(uint256 bountyId, uint256 claimId) external view returns (Claim memory) {
        _getBounty(bountyId);
        if (claimId >= _claims[bountyId].length) revert ClaimNotFound(bountyId, claimId);
        return _claims[bountyId][claimId];
    }

    /// @notice Return all claims for an existing bounty; large arrays may require substantial RPC gas.
    function getClaims(uint256 bountyId) external view returns (Claim[] memory) {
        _getBounty(bountyId);
        return _claims[bountyId];
    }

    /**
     * @notice Return unique contributors in first-contribution order and their recorded shares.
     * @dev Refunded shares are zero; Paid bounty shares are historical, not withdrawable.
     * The contributor count includes refunded contributors. Large arrays may require substantial RPC gas.
     */
    function getContributors(uint256 bountyId)
        external
        view
        returns (address[] memory contributors, uint256[] memory shares)
    {
        _getBounty(bountyId);
        contributors = _contributors[bountyId];
        shares = new uint256[](contributors.length);
        for (uint256 i = 0; i < contributors.length; ++i) {
            shares[i] = contributions[bountyId][contributors[i]];
        }
    }

    /// @notice Return a recorded share; after payment it is historical, and after refund it is zero.
    /// @dev Reverts with BountyNotFound for unknown bounty IDs.
    function contributionOf(uint256 bountyId, address contributor) external view returns (uint256) {
        _getBounty(bountyId);
        return contributions[bountyId][contributor];
    }

    /// @notice Return settlement time: expiry + GRACE_PERIOD when claims exist, or expiry otherwise.
    /// @dev Reverts for unknown IDs. Paid bounties cannot refund even after this timestamp.
    function refundOpensAt(uint256 bountyId) external view returns (uint256) {
        return _settlementTime(_getBounty(bountyId));
    }

    /// @notice Return the number of claims submitted by a hunter to an existing bounty.
    /// @dev Reverts with BountyNotFound for unknown bounty IDs.
    function claimsBy(uint256 bountyId, address hunter) external view returns (uint256) {
        _getBounty(bountyId);
        return _claimsBy[bountyId][hunter];
    }

    /// @dev Claim count cannot change after expiry, so settlement time is stable once expiry is reached.
    function _settlementTime(Bounty storage bounty) private view returns (uint256) {
        return bounty.claimCount > 0 ? uint256(bounty.expiry) + GRACE_PERIOD : uint256(bounty.expiry);
    }

    /// @dev Central existence check used by all bounty-specific external functions.
    function _getBounty(uint256 bountyId) private view returns (Bounty storage bounty) {
        bounty = _bounties[bountyId];
        if (bounty.id == 0) revert BountyNotFound(bountyId);
    }

    /// @dev Contributions and submissions share the same exclusive expiry boundary.
    function _requireActive(Bounty storage bounty) private view {
        if (bounty.status != Status.Open) revert BountyNotOpen(bounty.id);
        if (block.timestamp >= bounty.expiry) revert BountyExpired(bounty.id);
    }
}
