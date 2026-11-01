import { parseAbi } from 'viem'

// BountyBoxV2 ABI. Field order mirrors contracts/BountyBoxV2.sol exactly.
const BOUNTY =
  '(uint256 id, address poster, string title, string description, string criteria, uint64 expiry, uint256 pot, uint8 status, bool hasAccepted, uint8 judgeMode, bool requireHandle, address winner, uint256 winningClaimId, uint256 paidAmount, uint256 claimCount, uint256 contributorCount, uint256 createdAt)'
const CLAIM = '(address hunter, string proofURL, string note, string handle, uint256 timestamp)'

export const bountyBoxAbi = parseAbi([
  'function MIN_AMOUNT() view returns (uint256)',
  'function aiJudge() view returns (address)',
  'function guardian() view returns (address)',
  'function maxAIPot() view returns (uint256)',
  'function judgeRetired() view returns (bool)',
  'function retireJudge()',
  'function bountyCount() view returns (uint256)',
  'function refundOpensAt(uint256 bountyId) view returns (uint256)',
  'function claimsBy(uint256 bountyId, address hunter) view returns (uint256)',
  'function effectiveStatus(uint256 bountyId) view returns (uint8)',
  'function getVerdict(uint256 bountyId) view returns (bytes32 verdictHash, string verdictURI)',
  'function createBounty(string title, string description, string criteria, uint64 expiry, uint256 amount, uint8 mode, bool requireHandle) returns (uint256 bountyId)',
  'function contribute(uint256 bountyId, uint256 amount)',
  'function submitClaim(uint256 bountyId, string proofURL, string note, string handle) returns (uint256 claimId)',
  'function acceptClaim(uint256 bountyId, uint256 claimId)',
  'function judgeAccept(uint256 bountyId, uint256 claimId, bytes32 verdictHash, string verdictURI)',
  'function refund(uint256 bountyId)',
  `function getBounty(uint256 bountyId) view returns (${BOUNTY})`,
  `function getClaims(uint256 bountyId) view returns (${CLAIM}[])`,
  'function getContributors(uint256 bountyId) view returns (address[] contributors, uint256[] shares)',
  `function getClaimsPage(uint256 bountyId, uint256 offset, uint256 limit) view returns (${CLAIM}[] page, uint256 total)`,
  'function getContributorsPage(uint256 bountyId, uint256 offset, uint256 limit) view returns (address[] contributors, uint256[] shares, uint256 total)',
  'function claimCount(uint256 bountyId) view returns (uint256)',
  'function contributorCount(uint256 bountyId) view returns (uint256)',
  'function MAX_PAGE_SIZE() view returns (uint256)',
  'function contributionOf(uint256 bountyId, address contributor) view returns (uint256)',
  'event BountyCreated(uint256 indexed id, address indexed poster, string title, uint64 expiry, uint256 amount, uint8 mode, bool requireHandle)',
  'event Contributed(uint256 indexed id, address indexed contributor, uint256 amount, uint256 newPot)',
  'event ClaimSubmitted(uint256 indexed id, uint256 indexed claimId, address indexed hunter, string proofURL, string handle)',
  'event ClaimAccepted(uint256 indexed id, uint256 indexed claimId, address indexed hunter, uint256 amount)',
  'event ClaimJudged(uint256 indexed id, uint256 indexed claimId, address indexed hunter, bytes32 verdictHash, string verdictURI, uint256 amount)',
  'event Refunded(uint256 indexed id, address indexed contributor, uint256 amount)',
  'event JudgeRetired(address indexed guardian)',
  'error ZeroAddress()',
  'error JudgeIsToken()',
  'error InvalidGuardian()',
  'error InvalidMaxAIPot()',
  'error OnlyGuardian()',
  'error JudgeRetired()',
  'error JudgeAlreadyRetired()',
  'error AIPotCapExceeded(uint256 attemptedPot, uint256 maxPot)',
  'error BountyNotFound(uint256 bountyId)',
  'error BountyNotOpen(uint256 bountyId)',
  'error BountyExpired(uint256 bountyId)',
  'error AcceptWindowClosed(uint256 bountyId)',
  'error RefundNotOpen(uint256 bountyId, uint256 opensAt)',
  'error ExpiryTooFar()',
  'error TooManyClaims(uint256 bountyId, address hunter)',
  'error InvalidExpiry()',
  'error AmountTooSmall(uint256 amount)',
  'error InvalidTitleLength()',
  'error DescriptionTooLong()',
  'error CriteriaRequired()',
  'error CriteriaTooLong()',
  'error InvalidProofURLLength()',
  'error NoteTooLong()',
  'error HandleRequired()',
  'error HandleTooLong()',
  'error PosterCannotSubmitClaim()',
  'error JudgeCannotSubmitClaim()',
  'error JudgeCannotContribute()',
  'error JudgeCannotRefund()',
  'error OnlyPoster()',
  'error JudgedByAI(uint256 bountyId)',
  'error OnlyJudge()',
  'error NotAIJudged()',
  'error EmptyVerdict()',
  'error InvalidVerdictURILength()',
  'error ClaimNotFound(uint256 bountyId, uint256 claimId)',
  'error NoContribution()',
])

export const MIN_AMOUNT_RAW = 10_000n // mirrors BountyBoxV2.MIN_AMOUNT (0.01 USDC)
/** Mirrors of BountyBoxV2 constants. Keep in sync with the contract. */
export const GRACE_PERIOD_SECONDS = 7 * 86_400
export const MAX_DURATION_SECONDS = 90 * 86_400
export const MAX_CLAIMS_PER_HUNTER = 3
export const LIMITS = {
  title: 100,
  description: 2000,
  criteria: 1000,
  proofURL: 500,
  note: 500,
  handle: 64,
} as const

export const JudgeMode = { Poster: 0, AI: 1 } as const
