// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Namespaces the retirement error to avoid a name collision with the JudgeRetired event.
library BountyBoxV2Errors {
    error JudgeRetired();
}

/**
 * @title BountyBoxV2
 * @notice Permissionless, poster- or AI-selected bounties escrowed in six-decimal USDC.
 * @dev On Arc, pass 0x3600000000000000000000000000000000000000 as usdc_.
 * The token must transfer exact amounts without fees or rebasing. No native currency is used.
 * Contributions and claims close strictly at expiry. If claims exist, acceptance remains open
 * until expiry + GRACE_PERIOD; otherwise settlement time is expiry. Refunds open at settlement time.
 * A single claim, however junk, extends the refund date by GRACE_PERIOD (7 days) for every
 * contributor of that bounty; acceptance and refunds never overlap.
 * aiJudge is trusted for AI bounties: it can pick any submitted claim, without on-chain merit checks.
 * aiJudge is immutable: a compromised judge key cannot be rotated. If it never accepts, contributors
 * can recover their own shares at settlement time. Only aiJudge can release an AI bounty's award.
 * The judge cannot contribute or create bounties, so it has no refundable shares or poster powers;
 * it cannot refund or submit claims; its only token-outflow entry point is judgeAccept,
 * paying the submitted claim's own hunter.
 * The immutable, independent guardian can permanently retire the judge but cannot move funds
 * or change any bounty, claim, pot, or status through that power. It has no other privileged power.
 * Retirement blocks AI creation, contributions, claims, and awards, stranding existing unpaid AI
 * bounties into the existing per-contributor refund path at expiry + GRACE_PERIOD when claims exist,
 * or expiry otherwise. Retirement does not accelerate settlement or affect Poster-mode flows.
 * maxAIPot is a limit PER AI BOUNTY in USDC base units, not an aggregate cap across bounties.
 * A compromised judge could take up to maxAIPot from each AI bounty; Poster-mode pots are uncapped.
 * Retirement cannot reverse awards already executed or win a race against a pending judgeAccept.
 * USDC sent directly by plain transfer instead of createBounty/contribute is not credited to any pot
 * and cannot be recovered by anyone. Users must deposit only through createBounty/contribute.
 * There is no administrator, upgrade mechanism, general pause, or discretionary withdrawal.
 */
contract BountyBoxV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum deposit in base units: 0.01 USDC at six decimals.
    uint256 public constant MIN_AMOUNT = 10_000;

    /// @notice Additional acceptance window after expiry when at least one claim exists.
    uint256 public constant GRACE_PERIOD = 7 days;

    /// @notice Maximum time between bounty creation and expiry.
    uint256 public constant MAX_DURATION = 90 days;

    /// @notice Maximum number of claims one hunter may submit to a single bounty.
    uint256 public constant MAX_CLAIMS_PER_HUNTER = 3;

    /// @notice Maximum number of entries returned by a paged view.
    uint256 public constant MAX_PAGE_SIZE = 100;

    /// @notice ERC-20 used for every deposit, award, and refund.
    IERC20 public immutable usdc;

    /// @notice Sole trusted evaluator for AI bounties; cannot be replaced.
    address public immutable aiJudge;

    /// @notice Independent, immutable judge kill switch; cannot move funds through this power.
    address public immutable guardian;

    /// @notice Maximum pot per AI bounty in six-decimal USDC base units; bounds loss per bounty.
    uint256 public immutable maxAIPot;

    /// @notice Permanent retirement flag; once true, AI awards, deposits, and claims are disabled.
    bool public judgeRetired;

    /// @notice Number of bounties created; valid IDs are 1 through bountyCount.
    uint256 public bountyCount;

    /// @notice Refunded is set only when the last contributor withdraws and the pot reaches zero.
    enum Status { Open, Paid, Refunded }

    /// @notice Immutable selection of who may accept a bounty's claim.
    enum JudgeMode { Poster, AI }

    /// @notice Deadline-aware status; Expired includes the grace window and partial refunds.
    enum EffectiveStatus { Open, Expired, Paid, Refunded }

    /// @notice Bounty details, including live escrow and historical award information.
    /// @dev winningClaimId is meaningful only when hasAccepted is true; zero is a valid claim ID.
    struct Bounty {
        uint256 id;
        address poster;
        string title;
        string description;
        string criteria;
        uint64 expiry;
        uint256 pot;
        Status status;
        bool hasAccepted;
        JudgeMode judgeMode;
        bool requireHandle;
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
        string handle;
        uint256 timestamp;
    }

    mapping(uint256 => Bounty) private _bounties;
    mapping(uint256 => Claim[]) private _claims;
    mapping(uint256 => address[]) private _contributors;
    mapping(uint256 => mapping(address => uint256)) private contributions;
    mapping(uint256 => mapping(address => uint256)) private _claimsBy;
    mapping(uint256 => bytes32) private _verdictHashes;
    mapping(uint256 => string) private _verdictURIs;

    error ZeroAddress();
    error JudgeIsToken();
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
    error CriteriaRequired();
    error CriteriaTooLong();
    error InvalidProofURLLength();
    error NoteTooLong();
    error HandleRequired();
    error HandleTooLong();
    error PosterCannotSubmitClaim();
    error JudgeCannotSubmitClaim();
    error JudgeCannotContribute();
    error JudgeCannotRefund();
    error TooManyClaims(uint256 bountyId, address hunter);
    error OnlyPoster();
    error JudgedByAI(uint256 bountyId);
    error OnlyJudge();
    error NotAIJudged();
    error EmptyVerdict();
    error InvalidVerdictURILength();
    error ClaimNotFound(uint256 bountyId, uint256 claimId);
    error NoContribution();
    error InvalidGuardian();
    error OnlyGuardian();
    error JudgeAlreadyRetired();
    error InvalidMaxAIPot();
    error AIPotCapExceeded(uint256 attemptedPot, uint256 maxPot);

    event BountyCreated(uint256 indexed id, address indexed poster, string title, uint64 expiry, uint256 amount, JudgeMode mode, bool requireHandle);
    event Contributed(uint256 indexed id, address indexed contributor, uint256 amount, uint256 newPot);
    event ClaimSubmitted(uint256 indexed id, uint256 indexed claimId, address indexed hunter, string proofURL, string handle);
    event ClaimAccepted(uint256 indexed id, uint256 indexed claimId, address indexed hunter, uint256 amount);
    event ClaimJudged(uint256 indexed id, uint256 indexed claimId, address indexed hunter, bytes32 verdictHash, string verdictURI, uint256 amount);
    event Refunded(uint256 indexed id, address indexed contributor, uint256 amount);
    event JudgeRetired(address indexed guardian);

    /// @param usdc_ Six-decimal USDC ERC-20 address; must not be zero.
    /// @param aiJudge_ Immutable trusted evaluator; nonzero and distinct from the token address.
    /// @param guardian_ Independent kill switch; nonzero and distinct from both token and judge.
    /// @param maxAIPot_ Per-AI-bounty pot cap in USDC base units; must be at least MIN_AMOUNT.
    constructor(address usdc_, address aiJudge_, address guardian_, uint256 maxAIPot_) {
        if (usdc_ == address(0) || aiJudge_ == address(0) || guardian_ == address(0)) revert ZeroAddress();
        if (aiJudge_ == usdc_) revert JudgeIsToken();
        if (guardian_ == aiJudge_ || guardian_ == usdc_) revert InvalidGuardian();
        if (maxAIPot_ < MIN_AMOUNT) revert InvalidMaxAIPot();
        usdc = IERC20(usdc_);
        aiJudge = aiJudge_;
        guardian = guardian_;
        maxAIPot = maxAIPot_;
    }

    /// @notice Permanently disable the AI judge; only the independent guardian may call once.
    /// @dev Changes only judgeRetired and emits JudgeRetired; never moves funds or changes bounties.
    /// Existing unpaid AI bounties must wait until expiry plus grace when claims exist, or expiry
    /// otherwise, for per-contributor refunds. No settlement deadline or Poster-mode flow is changed.
    function retireJudge() external {
        if (msg.sender != guardian) revert OnlyGuardian();
        if (judgeRetired) revert JudgeAlreadyRetired();
        judgeRetired = true;
        emit JudgeRetired(msg.sender);
    }

    /**
     * @notice Create a bounty and escrow the caller's initial contribution.
     * @dev Caller must first approve this contract for amount. All string limits are byte lengths.
     * The judge cannot deposit, preventing refundable shares that would give it another outflow path.
     * AI creation is disabled after retirement and its initial pot cannot exceed maxAIPot.
     * @param title Nonempty title, at most 100 bytes.
     * @param description Description, at most 2000 bytes.
     * @param criteria Evaluation criteria, at most 1000 bytes and required for AI bounties.
     * @param expiry Future Unix timestamp within MAX_DURATION, exclusive for contributions and claims.
     * Acceptance extends by GRACE_PERIOD when claims exist; refunds open at that settlement time.
     * @param amount Initial contribution in USDC base units, at least MIN_AMOUNT.
     * @param mode Immutable choice of poster or AI evaluation.
     * @param requireHandle Whether every claim must include a nonempty handle; immutable per bounty.
     * @return bountyId The newly assigned ID, starting at 1.
     */
    function createBounty(
        string calldata title,
        string calldata description,
        string calldata criteria,
        uint64 expiry,
        uint256 amount,
        JudgeMode mode,
        bool requireHandle
    ) external nonReentrant returns (uint256 bountyId) {
        if (mode == JudgeMode.AI && judgeRetired) revert BountyBoxV2Errors.JudgeRetired();
        if (msg.sender == aiJudge) revert JudgeCannotContribute();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (expiry > block.timestamp + MAX_DURATION) revert ExpiryTooFar();
        if (amount < MIN_AMOUNT) revert AmountTooSmall(amount);
        if (mode == JudgeMode.AI && amount > maxAIPot) revert AIPotCapExceeded(amount, maxAIPot);
        if (bytes(title).length == 0 || bytes(title).length > 100) revert InvalidTitleLength();
        if (bytes(description).length > 2000) revert DescriptionTooLong();
        if (mode == JudgeMode.AI && bytes(criteria).length == 0) revert CriteriaRequired();
        if (bytes(criteria).length > 1000) revert CriteriaTooLong();

        bountyId = ++bountyCount;
        Bounty storage bounty = _bounties[bountyId];
        bounty.id = bountyId;
        bounty.poster = msg.sender;
        bounty.title = title;
        bounty.description = description;
        bounty.criteria = criteria;
        bounty.expiry = expiry;
        bounty.pot = amount;
        bounty.status = Status.Open;
        bounty.judgeMode = mode;
        bounty.requireHandle = requireHandle;
        bounty.contributorCount = 1;
        bounty.createdAt = block.timestamp;
        contributions[bountyId][msg.sender] = amount;
        _contributors[bountyId].push(msg.sender);

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit BountyCreated(bountyId, msg.sender, title, expiry, amount, mode, requireHandle);
    }

    /// @notice Add at least MIN_AMOUNT base units to an Open, unexpired bounty; the judge cannot deposit.
    /// @dev Requires prior token approval. Each contributor appears only once in the address list.
    /// AI contributions are disabled after retirement; the resulting pot must not exceed maxAIPot.
    function contribute(uint256 bountyId, uint256 amount) external nonReentrant {
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.judgeMode == JudgeMode.AI && judgeRetired) revert BountyBoxV2Errors.JudgeRetired();
        _requireActive(bounty);
        if (msg.sender == aiJudge) revert JudgeCannotContribute();
        if (amount < MIN_AMOUNT) revert AmountTooSmall(amount);
        uint256 newPot = bounty.pot + amount;
        if (bounty.judgeMode == JudgeMode.AI && newPot > maxAIPot) revert AIPotCapExceeded(newPot, maxAIPot);

        if (contributions[bountyId][msg.sender] == 0) {
            _contributors[bountyId].push(msg.sender);
            ++bounty.contributorCount;
        }
        contributions[bountyId][msg.sender] += amount;
        bounty.pot = newPot;

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit Contributed(bountyId, msg.sender, amount, newPot);
    }

    /**
     * @notice Submit proof for an Open, unexpired bounty; neither the poster nor judge may submit.
     * @dev Each hunter may submit at most MAX_CLAIMS_PER_HUNTER claims per bounty.
     * A handle is self-reported: social ownership and proof content are not validated on-chain.
     * AI claims are disabled after retirement so new claims cannot delay refunds by adding grace.
     * @param bountyId Existing bounty ID.
     * @param proofURL Nonempty proof URL, at most 500 bytes; content is not validated on-chain.
     * @param note Optional note, at most 500 bytes.
     * @param handle Linked social/GitHub handle, at most 64 bytes; required if requireHandle is true.
     * @return claimId Zero-based index within this bounty's claims.
     */
    function submitClaim(
        uint256 bountyId,
        string calldata proofURL,
        string calldata note,
        string calldata handle
    ) external nonReentrant returns (uint256 claimId) {
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.judgeMode == JudgeMode.AI && judgeRetired) revert BountyBoxV2Errors.JudgeRetired();
        _requireActive(bounty);
        if (msg.sender == bounty.poster) revert PosterCannotSubmitClaim();
        if (msg.sender == aiJudge) revert JudgeCannotSubmitClaim();
        if (_claimsBy[bountyId][msg.sender] >= MAX_CLAIMS_PER_HUNTER) revert TooManyClaims(bountyId, msg.sender);
        if (bytes(proofURL).length == 0 || bytes(proofURL).length > 500) revert InvalidProofURLLength();
        if (bytes(note).length > 500) revert NoteTooLong();
        if (bounty.requireHandle && bytes(handle).length == 0) revert HandleRequired();
        if (bytes(handle).length > 64) revert HandleTooLong();

        claimId = _claims[bountyId].length;
        _claims[bountyId].push(Claim({
            hunter: msg.sender,
            proofURL: proofURL,
            note: note,
            handle: handle,
            timestamp: block.timestamp
        }));
        ++bounty.claimCount;
        ++_claimsBy[bountyId][msg.sender];
        emit ClaimSubmitted(bountyId, claimId, msg.sender, proofURL, handle);
    }

    /**
     * @notice Poster awards a Poster-mode bounty's entire pot, strictly before settlement time.
     * @dev AI bounties always reject this entry point with JudgedByAI, including calls by the poster.
     * Settlement time is expiry + GRACE_PERIOD when claims exist, or expiry otherwise.
     * All award state is finalized before transfer. At or after settlement time only refunds are possible,
     * removing the accept-versus-refund race. Historical contributions remain recorded after payment.
     * A USDC-blocklisted hunter makes acceptance revert atomically: the poster can pick a different
     * claim, or backers can refund at settlement. A USDC-blocklisted contributor's own refund reverts
     * atomically and cannot be redirected, so that share stays in the contract. Other contributors
     * are unaffected; the blocked share becomes withdrawable if the address is unblocked.
     */
    function acceptClaim(uint256 bountyId, uint256 claimId) external nonReentrant {
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.judgeMode == JudgeMode.AI) revert JudgedByAI(bountyId);
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

    /**
     * @notice The immutable judge awards an AI bounty's full pot to a submitted claim's hunter.
     * @dev Only this entry point releases AI escrow. Rejections remain off-chain. Award and verdict
     * state are finalized before transfer; a failed transfer rolls back the entire acceptance.
     * A USDC-blocklisted hunter makes acceptance revert atomically: the judge can pick a different
     * claim, or backers can refund at settlement. A USDC-blocklisted contributor's own refund reverts
     * atomically and cannot be redirected, so that share stays in the contract. Other contributors
     * are unaffected; the blocked share becomes withdrawable if the address is unblocked.
     * The judge cannot supply a different recipient or accept at or after settlement time.
     * Retirement rejects every caller and bounty before authorization or bounty lookup;
     * unpaid AI bounties retain their original expiry/grace settlement and refund path.
     * @param bountyId Existing AI bounty ID.
     * @param claimId Existing zero-based claim index.
     * @param verdictHash Nonzero commitment to the evaluator's verdict; content is not verified on-chain.
     * @param verdictURI Nonempty verdict reference, at most 300 bytes.
     */
    function judgeAccept(
        uint256 bountyId,
        uint256 claimId,
        bytes32 verdictHash,
        string calldata verdictURI
    ) external nonReentrant {
        if (judgeRetired) revert BountyBoxV2Errors.JudgeRetired();
        if (msg.sender != aiJudge) revert OnlyJudge();
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.judgeMode != JudgeMode.AI) revert NotAIJudged();
        if (bounty.status != Status.Open) revert BountyNotOpen(bountyId);
        if (block.timestamp >= _settlementTime(bounty)) revert AcceptWindowClosed(bountyId);
        if (claimId >= _claims[bountyId].length) revert ClaimNotFound(bountyId, claimId);
        if (verdictHash == bytes32(0)) revert EmptyVerdict();
        if (bytes(verdictURI).length == 0 || bytes(verdictURI).length > 300) revert InvalidVerdictURILength();

        address hunter = _claims[bountyId][claimId].hunter;
        uint256 amount = bounty.pot;
        bounty.status = Status.Paid;
        bounty.hasAccepted = true;
        bounty.winner = hunter;
        bounty.winningClaimId = claimId;
        bounty.paidAmount = amount;
        bounty.pot = 0;
        _verdictHashes[bountyId] = verdictHash;
        _verdictURIs[bountyId] = verdictURI;

        usdc.safeTransfer(hunter, amount);
        emit ClaimAccepted(bountyId, claimId, hunter, amount);
        emit ClaimJudged(bountyId, claimId, hunter, verdictHash, verdictURI, amount);
    }

    /// @notice Withdraw only the caller's contribution from an unpaid bounty at or after settlement time.
    /// @dev Opens at expiry + GRACE_PERIOD when claims exist, or expiry otherwise. The poster may refund too.
    /// The bounty stays Open (and expired) until the last share is withdrawn; only when the pot reaches
    /// zero does it become Refunded. Until then every remaining contributor can refund their own share.
    /// The judge cannot refund and is prevented from depositing through either contribution entry point.
    function refund(uint256 bountyId) external nonReentrant {
        Bounty storage bounty = _getBounty(bountyId);
        if (msg.sender == aiJudge) revert JudgeCannotRefund();
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

    /// @notice Return all claims for an existing bounty; this is an unbounded read.
    /// @dev Integrations with many entries should use getClaimsPage to bound RPC gas and response size.
    function getClaims(uint256 bountyId) external view returns (Claim[] memory) {
        _getBounty(bountyId);
        return _claims[bountyId];
    }

    /// @notice Return at most MAX_PAGE_SIZE claims starting at a zero-based offset, and the total count.
    /// @dev Reverts with BountyNotFound for unknown IDs. Zero limit or offset >= total returns an empty page.
    function getClaimsPage(uint256 bountyId, uint256 offset, uint256 limit)
        external
        view
        returns (Claim[] memory page, uint256 total)
    {
        _getBounty(bountyId);
        total = _claims[bountyId].length;
        if (offset >= total || limit == 0) return (new Claim[](0), total);

        uint256 n = limit > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : limit;
        uint256 remaining = total - offset;
        if (n > remaining) n = remaining;
        page = new Claim[](n);
        // offset < total and n <= total - offset, so every offset + i is below total.
        for (uint256 i = 0; i < n; ++i) {
            page[i] = _claims[bountyId][offset + i];
        }
    }

    /// @notice Return the bounty's recorded claim count; reverts with BountyNotFound for unknown IDs.
    function claimCount(uint256 bountyId) external view returns (uint256) {
        return _getBounty(bountyId).claimCount;
    }

    /**
     * @notice Return unique contributors in first-contribution order and their recorded shares.
     * @dev Refunded shares are zero; Paid bounty shares are historical, not withdrawable.
     * The contributor count includes refunded contributors. This is an unbounded read; integrations
     * with many entries should use getContributorsPage to bound RPC gas and response size.
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

    /// @notice Return at most MAX_PAGE_SIZE contributors in first-contribution order, shares, and total count.
    /// @dev Reverts with BountyNotFound for unknown IDs. Zero limit or offset >= total returns empty arrays.
    /// Shares are current recorded shares: refunded shares are zero; Paid shares are historical.
    function getContributorsPage(uint256 bountyId, uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory contributors, uint256[] memory shares, uint256 total)
    {
        _getBounty(bountyId);
        total = _contributors[bountyId].length;
        if (offset >= total || limit == 0) return (new address[](0), new uint256[](0), total);

        uint256 n = limit > MAX_PAGE_SIZE ? MAX_PAGE_SIZE : limit;
        uint256 remaining = total - offset;
        if (n > remaining) n = remaining;
        contributors = new address[](n);
        shares = new uint256[](n);
        // offset < total and n <= total - offset, so every offset + i is below total.
        for (uint256 i = 0; i < n; ++i) {
            address contributor = _contributors[bountyId][offset + i];
            contributors[i] = contributor;
            shares[i] = contributions[bountyId][contributor];
        }
    }

    /// @notice Return the bounty's recorded contributor count, including refunded contributors.
    /// @dev Reverts with BountyNotFound for unknown IDs.
    function contributorCount(uint256 bountyId) external view returns (uint256) {
        return _getBounty(bountyId).contributorCount;
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

    /// @notice Return a deadline-aware status without changing the stored settlement status.
    /// @dev Paid and Refunded take precedence; all other bounties read Expired from expiry onward.
    function effectiveStatus(uint256 bountyId) external view returns (EffectiveStatus) {
        Bounty storage bounty = _getBounty(bountyId);
        if (bounty.status == Status.Paid) return EffectiveStatus.Paid;
        if (bounty.status == Status.Refunded) return EffectiveStatus.Refunded;
        if (block.timestamp >= bounty.expiry) return EffectiveStatus.Expired;
        return EffectiveStatus.Open;
    }

    /// @notice Return the accepted AI verdict; returns zero hash and empty URI if none was recorded.
    /// @dev Reverts with BountyNotFound for unknown bounty IDs.
    function getVerdict(uint256 bountyId) external view returns (bytes32 verdictHash, string memory verdictURI) {
        _getBounty(bountyId);
        return (_verdictHashes[bountyId], _verdictURIs[bountyId]);
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
