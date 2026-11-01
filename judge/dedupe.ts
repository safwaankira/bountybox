import { createHash } from 'node:crypto'
import { classifyProof } from './evidence/classify'
import type { ClaimView } from './types'

/**
 * Duplicate-proof detection. Two claims on the same bounty that point at the same underlying proof are the same
 * proof, however the link is spelled. The earliest claim wins; later copies are rejected.
 */

const X_HOSTS = new Set(['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com', 'm.twitter.com'])

/** Query parameters that only track where a click came from and never change what a page shows. */
const TRACKING_PARAMS = new Set([
  'fbclid', 'gclid', 'dclid', 'msclkid', 'twclid', 'yclid', 'igshid', 'mc_cid', 'mc_eid', '_hsenc', '_hsmi', 'mkt_tok',
  'ref_src', 'ref_url', 'cmpid', 'si', 'spm',
])

function isTracking(name: string): boolean {
  const lower = name.toLowerCase()
  return lower.startsWith('utm_') || TRACKING_PARAMS.has(lower)
}

/** A stable key for "the same proof". Never throws. */
export function normalizeProofURL(raw: string): string {
  const trimmed = raw.trim()
  let url: URL
  try {
    url = new URL(trimmed)
  } catch {
    return trimmed.toLowerCase()
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, '')

  // x.com and twitter.com (and their mobile/www variants) are one site; a post is identified by its id alone.
  if (X_HOSTS.has(host)) {
    const post = /\/status(?:es)?\/(\d{5,25})(?:\/|$)/.exec(url.pathname)
    if (post?.[1]) return `x.com/status/${post[1]}`
  }

  const classified = classifyProof(trimmed)
  if (classified.kind === 'github-pr') return `github.com/${classified.owner}/${classified.repo}/pull/${classified.number}`.toLowerCase()
  if (classified.kind === 'onchain-tx') return `tx:${classified.chainId}:${classified.hash.toLowerCase()}`

  const isX = X_HOSTS.has(host)
  const params = [...url.searchParams.entries()].filter(([name]) => !isTracking(name) && !isX).sort(([a], [b]) => a.localeCompare(b))
  const query = params.length > 0 ? `?${params.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&')}` : ''
  const path = url.pathname.replace(/\/{2,}/g, '/').replace(/\/+$/, '')
  const port = url.port && url.port !== '80' && url.port !== '443' ? `:${url.port}` : ''
  // The fragment never reaches the server, so it is dropped. http and https are treated as the same page.
  return `${host.replace(/^www\./, '')}${port}${path}${query}`
}

/** The id of the earliest claim before this one that used the same proof, or null. */
export function findDuplicateOf(claim: ClaimView, claims: readonly ClaimView[]): number | null {
  const key = normalizeProofURL(claim.proofURL)
  let earliest: number | null = null
  for (const other of claims) {
    if (other.id >= claim.id) continue
    if (normalizeProofURL(other.proofURL) !== key) continue
    if (earliest === null || other.id < earliest) earliest = other.id
  }
  return earliest
}

/** Compact, stable identity of a proof link for the persisted duplicate index (96 bits of SHA-256). */
export function proofKeyHash(proofURL: string): string {
  return createHash('sha256').update(normalizeProofURL(proofURL)).digest('hex').slice(0, 24)
}
