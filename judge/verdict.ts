import { createHash } from 'node:crypto'
import { keccak256, toBytes, type Address, type Hex } from 'viem'
import type { EvidenceBlob } from './evidence'
import type { BountyView, Check, ClaimStatus, ClaimView, Evidence, ModelVerdict, Store } from './types'

/** Public URL layout. Netlify redirects /verdicts/* and /evidence/* to the API function. */
export function verdictKey(chainId: number, bountyId: bigint, claimId: number): string {
  return `verdicts/${chainId}/${bountyId}/${claimId}.json`
}
export function statusKey(chainId: number, bountyId: bigint, claimId: number): string {
  return `status/${chainId}/${bountyId}/${claimId}.json`
}
export function indexKey(chainId: number, bountyId: bigint): string {
  return `status/${chainId}/${bountyId}/index.json`
}
export function verdictURL(base: string, chainId: number, bountyId: bigint, claimId: number): string {
  return `${base}/verdicts/${chainId}/${bountyId}/${claimId}.json`
}
export function evidenceURL(base: string, id: string): string {
  return `${base}/evidence/${id}/snapshot.json`
}

export interface Verdict {
  version: 1
  chainId: number
  contract: Address
  bountyId: string
  claimId: number
  hunter: Address
  proofURL: string
  handle: string
  criteria: string
  criteriaHash: Hex
  decidedAt: string
  outcome: 'approved' | 'rejected'
  reasons: string[]
  checks: Check[]
  models: ModelVerdict[]
  minConfidence: number
  /** Null when the claim was rejected before any evidence was fetched (for example a duplicate proof link). */
  evidence: { id: string; url: string; sha256: string } | null
  judge: Address
}

export interface PublishedEvidence {
  id: string
  url: string
  sha256: string
}

/** Stores the snapshot JSON and any image blobs under a content-derived id. */
export async function publishEvidence(store: Store, base: string, evidence: Evidence, blobs: EvidenceBlob[]): Promise<PublishedEvidence> {
  const snapshot = JSON.stringify(evidence, null, 2)
  const sha256 = createHash('sha256').update(snapshot).digest('hex')
  const id = sha256.slice(0, 24)
  await store.setText(`evidence/${id}/snapshot.json`, snapshot, 'application/json')
  for (const blob of blobs) await store.setBytes(`evidence/${id}/${blob.path}`, blob.bytes, blob.contentType)
  return { id, url: evidenceURL(base, id), sha256 }
}

export interface BuildVerdictInput {
  chainId: number
  contract: Address
  judge: Address
  bounty: BountyView
  claim: ClaimView
  checks: Check[]
  models: ModelVerdict[]
  approved: boolean
  reasons: string[]
  evidence: PublishedEvidence | null
  minConfidence: number
  now: Date
}

export function buildVerdict(input: BuildVerdictInput): { json: string; hash: Hex } {
  const verdict: Verdict = {
    version: 1,
    chainId: input.chainId,
    contract: input.contract,
    bountyId: input.bounty.id.toString(),
    claimId: input.claim.id,
    hunter: input.claim.hunter,
    proofURL: input.claim.proofURL,
    handle: input.claim.handle,
    criteria: input.bounty.criteria,
    criteriaHash: keccak256(toBytes(input.bounty.criteria)),
    decidedAt: input.now.toISOString(),
    outcome: input.approved ? 'approved' : 'rejected',
    reasons: input.reasons,
    checks: input.checks,
    models: input.models,
    minConfidence: input.minConfidence,
    evidence: input.evidence,
    judge: input.judge,
  }
  // The exact stored text is what gets hashed and what the API serves, byte for byte.
  const json = JSON.stringify(verdict, null, 2)
  return { json, hash: keccak256(toBytes(json)) }
}

/** Reasons a hunter sees: failed checks first, otherwise the models' own reasons. */
export function summarizeReasons(checks: Check[], models: ModelVerdict[], approved: boolean): string[] {
  const failed = checks.filter((c) => !c.ok).map((c) => c.detail)
  if (failed.length > 0) return failed.slice(0, 5)
  const fromModels = models.flatMap((m) => m.reasons.map((r) => `${m.provider}: ${r}`))
  if (approved) return fromModels.slice(0, 4)
  const dissent = models.filter((m) => !m.approved || m.confidence < 0.8).flatMap((m) => m.reasons.map((r) => `${m.provider} (${m.approved ? 'approved' : 'rejected'}, confidence ${m.confidence.toFixed(2)}): ${r}`))
  return (dissent.length > 0 ? dissent : fromModels).slice(0, 5)
}

export async function readIndex(store: Store, chainId: number, bountyId: bigint): Promise<Record<string, ClaimStatus>> {
  const text = await store.getText(indexKey(chainId, bountyId))
  if (!text) return {}
  try {
    return JSON.parse(text) as Record<string, ClaimStatus>
  } catch {
    return {}
  }
}

export async function readStatus(store: Store, chainId: number, bountyId: bigint, claimId: number): Promise<ClaimStatus | null> {
  const text = await store.getText(statusKey(chainId, bountyId, claimId))
  if (!text) return null
  try {
    return JSON.parse(text) as ClaimStatus
  } catch {
    return null
  }
}

export async function writeStatus(store: Store, chainId: number, bountyId: bigint, claimId: number, status: ClaimStatus): Promise<void> {
  await store.setText(statusKey(chainId, bountyId, claimId), JSON.stringify(status), 'application/json')
  const index = await readIndex(store, chainId, bountyId)
  index[String(claimId)] = status
  await store.setText(indexKey(chainId, bountyId), JSON.stringify(index), 'application/json')
}
