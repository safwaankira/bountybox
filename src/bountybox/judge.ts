import { useQueries, useQuery } from '@tanstack/react-query'
import { useReadContracts } from 'wagmi'
import { parseAbi, type Address, type Hex } from 'viem'
import { CHAIN_ID } from './config'

/**
 * Base URL of the judge service that serves /verdicts and /evidence. Empty means same origin
 * (the Netlify site, or the Vite dev proxy to the local judge server).
 */
export const JUDGE_BASE_URL = (import.meta.env.VITE_JUDGE_BASE_URL ?? '').replace(/\/+$/, '')

export type JudgeClaimState = 'pending' | 'error' | 'approved' | 'accepted' | 'rejected' | 'closed'

export interface JudgeClaimStatus {
  state: JudgeClaimState
  attempts: number
  nextAttemptAt: number
  updatedAt: number
  lastError?: string
  verdictURL?: string
  verdictHash?: Hex
  evidenceURL?: string
  reasons?: string[]
  txId?: string
  txHash?: Hex
}

/** Only http(s) links from the judge service are rendered as links. */
export function safeHref(url: string | undefined): string | undefined {
  if (!url) return undefined
  try {
    const parsed = new URL(url)
    return parsed.protocol === 'https:' || parsed.protocol === 'http:' ? parsed.toString() : undefined
  } catch {
    return undefined
  }
}

/** Same-origin path that serves a published verdict, independent of whatever origin was written onchain. */
export function verdictPath(bountyId: bigint, claimId: number): string {
  return `${JUDGE_BASE_URL}/verdicts/${CHAIN_ID}/${bountyId}/${claimId}.json`
}
export function evidencePath(evidenceId: string): string {
  return `${JUDGE_BASE_URL}/evidence/${encodeURIComponent(evidenceId)}/snapshot.json`
}

/** True for links that only work on the machine that wrote them (older judge runs used a local origin). */
export function isLocalUrl(url: string | undefined): boolean {
  if (!url) return true
  try {
    const host = new URL(url).hostname.toLowerCase()
    return host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]' || host.endsWith('.local')
  } catch {
    return true
  }
}

export interface PublishedVerdict {
  outcome: 'approved' | 'rejected'
  reasons: string[]
  decidedAt?: string
  evidenceId?: string
}

/** The published verdict JSON for a claim, or null when it is not published (yet). Display data only. */
export function useVerdictDoc(bountyId: bigint, claimId: number, enabled: boolean) {
  return useQuery({
    queryKey: ['judge-verdict', CHAIN_ID, bountyId.toString(), claimId],
    enabled,
    retry: false,
    staleTime: 60_000,
    queryFn: async (): Promise<PublishedVerdict | null> => {
      const res = await fetch(verdictPath(bountyId, claimId), { headers: { accept: 'application/json' } })
      if (res.status === 404) return null
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const raw = (await res.json()) as Record<string, unknown>
      if (raw.outcome !== 'approved' && raw.outcome !== 'rejected') return null
      const reasons = Array.isArray(raw.reasons) ? raw.reasons.filter((r): r is string => typeof r === 'string').slice(0, 8) : []
      const evidence = typeof raw.evidence === 'object' && raw.evidence !== null ? (raw.evidence as Record<string, unknown>) : {}
      return {
        outcome: raw.outcome,
        reasons,
        decidedAt: typeof raw.decidedAt === 'string' ? raw.decidedAt : undefined,
        evidenceId: typeof evidence.id === 'string' && /^[0-9a-f]{8,64}$/.test(evidence.id) ? evidence.id : undefined,
      }
    },
  })
}

function isFinalState(state: JudgeClaimState | undefined): boolean {
  return state === 'accepted' || state === 'rejected' || state === 'closed'
}

/**
 * Judge status for the claims currently on screen, one small request per claim. (Fetching a single index of every
 * claim would grow without bound on a bounty that attracts spam.) Claims with a final decision are never refetched.
 */
export function useClaimStatuses(bountyId: bigint, enabled: boolean, claimIds: number[]) {
  const queries = useQueries({
    queries: claimIds.map((claimId) => ({
      queryKey: ['judge-status', CHAIN_ID, bountyId.toString(), claimId],
      enabled,
      retry: false,
      staleTime: 5_000,
      refetchInterval: (query: { state: { data: JudgeClaimStatus | null | undefined } }) => (isFinalState(query.state.data?.state) ? false : 15_000),
      queryFn: async (): Promise<JudgeClaimStatus | null> => {
        const res = await fetch(`${JUDGE_BASE_URL}/verdicts/${CHAIN_ID}/${bountyId}/${claimId}/status.json`, { headers: { accept: 'application/json' } })
        // 404 just means the judge has not looked at this claim yet.
        if (res.status === 404) return null
        if (!res.ok) throw new Error(`Judge service returned HTTP ${res.status}`)
        const body: unknown = await res.json()
        return typeof body === 'object' && body !== null ? (body as JudgeClaimStatus) : null
      },
    })),
  })
  const statuses: Record<string, JudgeClaimStatus> = {}
  claimIds.forEach((claimId, i) => {
    const data = queries[i]?.data
    if (data) statuses[String(claimId)] = data
  })
  return { statuses, unreachable: queries.length > 0 && queries.every((q) => q.isError) }
}

/* ------------------------- ERC-8004 judge identity ------------------------- */

/** ERC-8004 IdentityRegistry on Arc Testnet (from the agent-standards reference). */
export const IDENTITY_REGISTRY: Address = '0x8004A818BFB912233c491871b3d84c89A494BD9e'
export const JUDGE_AGENT_ID: bigint | null = /^\d+$/.test(import.meta.env.VITE_JUDGE_AGENT_ID ?? '') ? BigInt(import.meta.env.VITE_JUDGE_AGENT_ID ?? '0') : null
/** The registry deployment above exists on Arc Testnet only. */
const IDENTITY_CHAIN_ID = 5042002

const identityAbi = parseAbi([
  'function ownerOf(uint256 agentId) view returns (address)',
  'function tokenURI(uint256 agentId) view returns (string)',
])

export interface JudgeIdentity {
  agentId: bigint
  owner: Address
  name: string
  description: string
  services: string[]
}

function parseCard(uri: string): { name: string; description: string; services: string[] } {
  const fallback = { name: 'AI judge', description: '', services: [] as string[] }
  const match = /^data:application\/json(?:;charset=[^;,]+)?(;base64)?,(.*)$/s.exec(uri)
  if (!match) return fallback
  try {
    const raw = match[1] ? atob(match[2] ?? '') : decodeURIComponent(match[2] ?? '')
    const card = JSON.parse(raw) as Record<string, unknown>
    const services = Array.isArray(card.services) ? card.services.map((s) => (typeof s === 'object' && s !== null && 'name' in s ? String((s as { name: unknown }).name) : '')).filter(Boolean) : []
    return {
      name: typeof card.name === 'string' ? card.name.slice(0, 80) : fallback.name,
      description: typeof card.description === 'string' ? card.description.slice(0, 300) : '',
      services: services.slice(0, 5),
    }
  } catch {
    return fallback
  }
}

/** Reads the judge's ERC-8004 registration. Treats the registration file strictly as display data. */
export function useJudgeIdentity(): JudgeIdentity | null {
  const enabled = JUDGE_AGENT_ID !== null && CHAIN_ID === IDENTITY_CHAIN_ID
  const res = useReadContracts({
    contracts:
      JUDGE_AGENT_ID === null
        ? []
        : [
            { address: IDENTITY_REGISTRY, abi: identityAbi, functionName: 'ownerOf', args: [JUDGE_AGENT_ID], chainId: CHAIN_ID },
            { address: IDENTITY_REGISTRY, abi: identityAbi, functionName: 'tokenURI', args: [JUDGE_AGENT_ID], chainId: CHAIN_ID },
          ],
    query: { enabled },
  })
  const [owner, uri] = res.data ?? []
  if (!enabled || JUDGE_AGENT_ID === null || owner?.status !== 'success' || uri?.status !== 'success') return null
  return { agentId: JUDGE_AGENT_ID, owner: owner.result, ...parseCard(uri.result) }
}
