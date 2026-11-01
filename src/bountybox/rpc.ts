import { fallback, http, type Chain, type Transport } from 'viem'

/** Every public RPC URL the chain definition lists. */
export function rpcUrlsFor(chain: Chain): string[] {
  return [...chain.rpcUrls.default.http]
}

/**
 * One transport that tries each listed RPC in turn when a request fails (rate limit, outage, lagging node)
 * instead of depending on the first URL alone.
 */
export function resilientTransport(chain: Chain): Transport {
  return fallback(
    rpcUrlsFor(chain).map((url) => http(url, { timeout: 10_000 })),
    { rank: false, retryCount: 1 },
  )
}
