import { ONCHAIN_CHAINS } from '../../src/onchain-facts'

export type Classified =
  | { kind: 'github-pr'; owner: string; repo: string; number: number }
  | { kind: 'x-post'; username: string; id: string }
  | { kind: 'onchain-tx'; chainId: number; hash: `0x${string}`; rpcUrls: string[] }
  | { kind: 'web'; url: string }

const NAME = /^[A-Za-z0-9_.-]{1,100}$/
const X_HOSTS = new Set(['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com'])

export function classifyProof(proofURL: string): Classified {
  let url: URL
  try {
    url = new URL(proofURL)
  } catch {
    return { kind: 'web', url: proofURL }
  }
  const host = url.hostname.toLowerCase()
  const parts = url.pathname.split('/').filter(Boolean)

  if ((host === 'github.com' || host === 'www.github.com') && parts[2] === 'pull' && /^\d+$/.test(parts[3] ?? '')) {
    const owner = parts[0] ?? ''
    const repo = parts[1] ?? ''
    if (NAME.test(owner) && NAME.test(repo)) return { kind: 'github-pr', owner, repo, number: Number(parts[3]) }
  }

  if (X_HOSTS.has(host) && parts[1] === 'status' && /^\d{5,25}$/.test(parts[2] ?? '')) {
    const username = parts[0] ?? ''
    if (/^[A-Za-z0-9_]{1,15}$/.test(username)) return { kind: 'x-post', username, id: parts[2] ?? '' }
  }

  if (parts[0] === 'tx' && /^0x[0-9a-fA-F]{64}$/.test(parts[1] ?? '')) {
    const chain = ONCHAIN_CHAINS.find((c) => new URL(c.explorerBase).hostname === host)
    if (chain) {
      return { kind: 'onchain-tx', chainId: chain.chainId, hash: (parts[1] ?? '').toLowerCase() as `0x${string}`, rpcUrls: chain.rpcUrls }
    }
  }

  return { kind: 'web', url: url.toString() }
}

export interface ParsedHandle {
  /** null when the hunter gave only a bare username. */
  platform: 'github' | 'x' | null
  username: string
}

/** Accepts "github:alice", "x:alice", "twitter:@alice", or a bare "@alice". */
export function parseHandle(raw: string): ParsedHandle | null {
  const value = raw.trim()
  if (!value) return null
  const match = /^(?:(github|x|twitter):)?@?([A-Za-z0-9_-]{1,39})$/i.exec(value)
  if (!match) return null
  const prefix = match[1]?.toLowerCase()
  return { platform: prefix === 'github' ? 'github' : prefix === 'x' || prefix === 'twitter' ? 'x' : null, username: match[2] ?? '' }
}
