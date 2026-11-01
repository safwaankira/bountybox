import { useEffect, useMemo, useState } from 'react'
import { useAccount, usePublicClient, useReadContract, useReadContracts } from 'wagmi'
import { erc20Abi, type Address, type ContractFunctionReturnType, type Hex } from 'viem'
import { GRACE_PERIOD_SECONDS, JudgeMode, bountyBoxAbi } from './abi'
import { BOUNTYBOX_ADDRESS, BOUNTYBOX_DEPLOY_BLOCK, CHAIN_ID, USDC_ADDRESS } from './config'

type RawBounty = ContractFunctionReturnType<typeof bountyBoxAbi, 'view', 'getBounty'>

export interface Bounty {
  id: bigint
  poster: Address
  title: string
  description: string
  /** Acceptance criteria the AI judge scores against. Empty for poster-judged bounties without any. */
  criteria: string
  /** True when only the AI judge can pay a claim (the poster cannot accept). */
  aiMode: boolean
  requireHandle: boolean
  expiry: number
  pot: bigint
  status: 'open' | 'paid' | 'refunded'
  /** True only once a claim was accepted; winningClaimId means nothing otherwise. */
  hasAccepted: boolean
  /** null unless a claim was accepted (hasAccepted). Never infer a winner from the raw fields. */
  winner: Address | null
  winningClaimId: bigint | null
  paidAmount: bigint
  claimCount: number
  contributorCount: number
  createdAt: number
}

export interface Claim {
  id: number
  hunter: Address
  proofURL: string
  note: string
  handle: string
  timestamp: number
}

export interface Contributor {
  address: Address
  share: bigint
}

/** open: taking claims and money. grace: expired with claims, poster can still accept. expired: refunds open. */
export type BountyState = 'open' | 'grace' | 'expired' | 'refunded' | 'paid'

const POLL_MS = 12_000

function mapBounty(r: RawBounty): Bounty {
  return {
    id: r.id,
    poster: r.poster,
    title: r.title,
    description: r.description,
    criteria: r.criteria,
    aiMode: r.judgeMode === JudgeMode.AI,
    requireHandle: r.requireHandle,
    expiry: Number(r.expiry),
    pot: r.pot,
    status: r.status === 1 ? 'paid' : r.status === 2 ? 'refunded' : 'open',
    hasAccepted: r.hasAccepted,
    winner: r.hasAccepted ? r.winner : null,
    winningClaimId: r.hasAccepted ? r.winningClaimId : null,
    paidAmount: r.paidAmount,
    claimCount: Number(r.claimCount),
    contributorCount: Number(r.contributorCount),
    createdAt: Number(r.createdAt),
  }
}

/** The immutable AI judge address of this deployment. */
export function useAiJudge(): Address | undefined {
  const res = useReadContract({ address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'aiJudge', chainId: CHAIN_ID })
  return res.data
}

export interface JudgeLimits {
  /** Cap on every AI-judged bounty's pot, in USDC base units. Undefined on contracts that predate the cap. */
  maxAIPot?: bigint
  /** True once the guardian has permanently retired the AI judge. */
  retired: boolean
  guardian?: Address
}

/** The immutable safety settings of the contract: the AI pot cap, the guardian, and whether the judge was retired. */
export function useJudgeLimits(): JudgeLimits {
  const res = useReadContracts({
    contracts: [
      { address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'maxAIPot', chainId: CHAIN_ID },
      { address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'judgeRetired', chainId: CHAIN_ID },
      { address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'guardian', chainId: CHAIN_ID },
    ],
    query: { refetchInterval: 30_000 },
  })
  const [cap, retired, guardian] = res.data ?? []
  return {
    maxAIPot: cap?.status === 'success' ? cap.result : undefined,
    retired: retired?.status === 'success' ? retired.result : false,
    guardian: guardian?.status === 'success' ? guardian.result : undefined,
  }
}

/** Mirrors BountyBox settlement time: expiry plus the grace period when claims exist. */
export function refundOpensAt(b: Bounty): number {
  return b.claimCount > 0 ? b.expiry + GRACE_PERIOD_SECONDS : b.expiry
}

export function bountyState(b: Bounty, now: number): BountyState {
  if (b.hasAccepted) return 'paid'
  if (b.status === 'refunded') return 'refunded'
  if (now < b.expiry) return 'open'
  return now < refundOpensAt(b) ? 'grace' : 'expired'
}

/** Ticks once per `intervalMs` so countdowns stay live. Returns unix seconds. */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs)
    return () => clearInterval(id)
  }, [intervalMs])
  return now
}

export function useBounties() {
  const count = useReadContract({
    address: BOUNTYBOX_ADDRESS,
    abi: bountyBoxAbi,
    functionName: 'bountyCount',
    chainId: CHAIN_ID,
    query: { refetchInterval: POLL_MS },
  })
  const n = Number(count.data ?? 0n)

  const contracts = useMemo(
    () =>
      Array.from({ length: n }, (_, i) => ({
        address: BOUNTYBOX_ADDRESS,
        abi: bountyBoxAbi,
        functionName: 'getBounty' as const,
        args: [BigInt(i + 1)] as const,
        chainId: CHAIN_ID,
      })),
    [n],
  )

  const list = useReadContracts({
    contracts,
    query: { enabled: n > 0, refetchInterval: POLL_MS },
  })

  const bounties = useMemo(() => {
    const out: Bounty[] = []
    for (const item of list.data ?? []) {
      if (item.status === 'success') out.push(mapBounty(item.result))
    }
    return out.sort((a, b) => Number(b.id - a.id))
  }, [list.data])

  return {
    bounties,
    isLoading: count.isLoading || (n > 0 && list.isLoading),
    isError: count.isError || list.isError,
    refetch: () => {
      void count.refetch()
      void list.refetch()
    },
  }
}

/** One bounty. Claims and backers are loaded separately, a page at a time (see paging.ts). */
export function useBountyDetail(id: bigint) {
  const result = useReadContract({
    address: BOUNTYBOX_ADDRESS,
    abi: bountyBoxAbi,
    functionName: 'getBounty',
    args: [id],
    chainId: CHAIN_ID,
    query: { refetchInterval: POLL_MS },
  })
  return {
    bounty: result.data ? mapBounty(result.data) : undefined,
    isLoading: result.isLoading,
    notFound: result.isError,
  }
}

/** Connected wallet's USDC balance (ERC-20 view, 6 decimals) and allowance for BountyBox. */
export function useUsdcAccount() {
  const { address } = useAccount()
  const res = useReadContracts({
    contracts: address
      ? [
          { address: USDC_ADDRESS, abi: erc20Abi, functionName: 'balanceOf', args: [address], chainId: CHAIN_ID },
          {
            address: USDC_ADDRESS,
            abi: erc20Abi,
            functionName: 'allowance',
            args: [address, BOUNTYBOX_ADDRESS],
            chainId: CHAIN_ID,
          },
        ]
      : [],
    query: { enabled: Boolean(address), refetchInterval: POLL_MS },
  })
  const [bal, allowance] = res.data ?? []
  return {
    balance: bal?.status === 'success' ? bal.result : undefined,
    allowance: allowance?.status === 'success' ? allowance.result : undefined,
  }
}

export function useMyClaimCount(bountyId: bigint) {
  const { address } = useAccount()
  const res = useReadContract({
    address: BOUNTYBOX_ADDRESS,
    abi: bountyBoxAbi,
    functionName: 'claimsBy',
    args: address ? [bountyId, address] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address), refetchInterval: POLL_MS },
  })
  return Number(res.data ?? 0n)
}

export function useMyContribution(bountyId: bigint) {
  const { address } = useAccount()
  const res = useReadContract({
    address: BOUNTYBOX_ADDRESS,
    abi: bountyBoxAbi,
    functionName: 'contributionOf',
    args: address ? [bountyId, address] : undefined,
    chainId: CHAIN_ID,
    query: { enabled: Boolean(address), refetchInterval: POLL_MS },
  })
  return res.data ?? 0n
}

/** Finds the payout transaction for a paid bounty, if the RPC serves the log query. */
export interface JudgedInfo {
  claimId: number
  verdictHash: Hex
  verdictURI: string
  /** Transaction of the judgeAccept call, when the ClaimJudged event could be found. */
  txHash?: Hex
}

/**
 * Onchain proof that the AI judge approved a claim: the stored verdict (view call, always available) plus the
 * ClaimJudged event for the transaction hash. The event lookup scans backwards in bounded windows from the chain
 * head and never starts before the contract's deployment block, so it works even when the RPC limits log ranges.
 */
export function useJudgedInfo(bounty: Bounty | undefined): JudgedInfo | undefined {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const enabled = Boolean(bounty?.aiMode && bounty.hasAccepted)
  const id = bounty?.id
  const verdict = useReadContract({
    address: BOUNTYBOX_ADDRESS,
    abi: bountyBoxAbi,
    functionName: 'getVerdict',
    args: [id ?? 0n],
    chainId: CHAIN_ID,
    query: { enabled },
  })
  const [event, setEvent] = useState<{ txHash: Hex; verdictHash: Hex; verdictURI: string } | undefined>()
  useEffect(() => {
    if (!enabled || !client || id === undefined) return
    let cancelled = false
    void (async () => {
      let to = await client.getBlockNumber()
      let span = 200_000n
      for (let requests = 0; requests < 60 && to >= BOUNTYBOX_DEPLOY_BLOCK && !cancelled; requests++) {
        const from = to - span + 1n > BOUNTYBOX_DEPLOY_BLOCK ? to - span + 1n : BOUNTYBOX_DEPLOY_BLOCK
        try {
          const logs = await client.getContractEvents({
            address: BOUNTYBOX_ADDRESS,
            abi: bountyBoxAbi,
            eventName: 'ClaimJudged',
            args: { id },
            fromBlock: from,
            toBlock: to,
          })
          const log = logs[logs.length - 1]
          if (log) {
            if (!cancelled) setEvent({ txHash: log.transactionHash, verdictHash: log.args.verdictHash ?? '0x', verdictURI: log.args.verdictURI ?? '' })
            return
          }
          if (from <= BOUNTYBOX_DEPLOY_BLOCK) return
          to = from - 1n
        } catch {
          // The RPC refused this window size: retry with a smaller one.
          if (span <= 2_000n) return
          span = span / 4n
        }
      }
    })().catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [client, id, enabled])

  if (!enabled || !bounty) return undefined
  const [viewHash, viewURI] = verdict.data ?? []
  const verdictHash = event?.verdictHash ?? viewHash
  if (!verdictHash) return undefined
  return { claimId: Number(bounty.winningClaimId ?? 0n), verdictHash, verdictURI: event?.verdictURI ?? viewURI ?? '', txHash: event?.txHash }
}

export function usePayoutTx(bountyId: bigint, enabled: boolean) {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const [hash, setHash] = useState<string | undefined>()
  useEffect(() => {
    if (!enabled || !client) return
    let cancelled = false
    client
      .getContractEvents({
        address: BOUNTYBOX_ADDRESS,
        abi: bountyBoxAbi,
        eventName: 'ClaimAccepted',
        args: { id: bountyId },
        fromBlock: BOUNTYBOX_DEPLOY_BLOCK,
        toBlock: 'latest',
      })
      .then((logs) => {
        if (!cancelled) setHash(logs[0]?.transactionHash)
      })
      .catch(() => {
        // The RPC may refuse wide log ranges; the payout link is optional.
      })
    return () => {
      cancelled = true
    }
  }, [client, bountyId, enabled])
  return hash
}
