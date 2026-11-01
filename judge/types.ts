import type { Address, Hex } from 'viem'

/** Minimal blob-style storage. Netlify Blobs in production, the filesystem locally. */
export interface Store {
  getText(key: string): Promise<string | null>
  getBytes(key: string): Promise<{ bytes: Uint8Array; contentType: string } | null>
  setText(key: string, value: string, contentType?: string): Promise<void>
  setBytes(key: string, value: Uint8Array, contentType: string): Promise<void>
}

export type EvidenceKind = 'github-pr' | 'x-post' | 'onchain-tx' | 'web'

export interface EvidenceImage {
  url: string
  sha256: string
  bytes: number
  contentType: string
  /** Path under the evidence id, served by the API. */
  storedAs: string
}

export interface Author {
  platform: 'github' | 'x'
  username: string
}

export interface Evidence {
  version: 1
  capturedAt: string
  proofURL: string
  kind: EvidenceKind
  finalURL: string
  title: string
  description: string
  /** Visible text, capped. Untrusted data. */
  text: string
  author: Author | null
  /** ISO timestamp of when the evidenced work was published or merged, when known. */
  publishedAt: string | null
  /** Structured, source-specific facts (PR state, tweet fields, tx receipt summary). */
  metadata: Record<string, unknown>
  images: EvidenceImage[]
  fetchErrors: string[]
}

export interface Check {
  name: string
  ok: boolean
  detail: string
}

export interface ModelVerdict {
  provider: 'openai' | 'groq' | 'gemini'
  model: string
  approved: boolean
  confidence: number
  reasons: string[]
}

export interface BountyView {
  id: bigint
  poster: Address
  title: string
  description: string
  criteria: string
  expiry: number
  createdAt: number
  status: 'open' | 'paid' | 'refunded'
  hasAccepted: boolean
  aiMode: boolean
  requireHandle: boolean
  claimCount: number
  settlementTime: number
}

export interface ClaimView {
  id: number
  hunter: Address
  proofURL: string
  note: string
  handle: string
  timestamp: number
}

export type ClaimState = 'pending' | 'error' | 'approved' | 'accepted' | 'rejected' | 'closed'

/** Public per-claim status, served at /verdicts/<chain>/<bounty>/<claim>/status.json. */
export interface ClaimStatus {
  state: ClaimState
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
