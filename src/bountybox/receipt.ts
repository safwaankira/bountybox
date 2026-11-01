/**
 * Receipt polling that does not depend on viem's block watcher.
 *
 * viem's waitForTransactionReceipt swallows errors from its block-number polling, so a rate limit
 * (HTTP 429), a dropped request or a lagging node shows up as a bare 3 minute timeout. This loop asks
 * eth_getTransactionReceipt directly, rotates across every RPC (and the user's wallet), backs off on
 * 429, and never throws on a transient failure.
 *
 * Pure TypeScript with no app imports so it can be exercised from a script.
 */

import type { Address, Hex } from 'viem'

export interface RawLog {
  address: Address
  topics: Hex[]
  data: Hex
}

export interface RawReceipt {
  transactionHash: Hex
  status: 'success' | 'reverted'
  blockNumber: bigint
  logs: RawLog[]
}

export interface WalletProviderLike {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>
}

export interface WaitOptions {
  rpcUrls: readonly string[]
  /** The wallet that sent the transaction always knows about it, so it is one of the sources. */
  wallet?: WalletProviderLike | null
  timeoutMs?: number
  requestTimeoutMs?: number
  signal?: AbortSignal
  onWarn?: (message: string) => void
}

class HttpStatusError extends Error {
  readonly status: number
  constructor(status: number) {
    super(`HTTP ${status}`)
    this.status = status
  }
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

function withTimeout<T>(work: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('request timed out')), ms)
    work.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (error: unknown) => {
        clearTimeout(timer)
        reject(error instanceof Error ? error : new Error(String(error)))
      },
    )
  })
}

async function fetchReceipt(url: string, hash: Hex, timeoutMs: number): Promise<unknown> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMs)
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getTransactionReceipt', params: [hash] }),
      signal: controller.signal,
    })
    if (!res.ok) throw new HttpStatusError(res.status)
    const body = (await res.json()) as { result?: unknown; error?: { message?: string } }
    if (body.error) throw new Error(body.error.message ?? 'RPC error')
    return body.result ?? null
  } finally {
    clearTimeout(timer)
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

/** Returns null for "not mined yet" or anything that is not a well-formed receipt. */
export function parseReceipt(raw: unknown): RawReceipt | null {
  if (!isRecord(raw)) return null
  const { transactionHash, status, blockNumber, logs } = raw
  if (typeof transactionHash !== 'string' || typeof blockNumber !== 'string') return null
  if (status !== '0x1' && status !== '0x0') return null
  const parsedLogs: RawLog[] = []
  for (const log of Array.isArray(logs) ? logs : []) {
    if (!isRecord(log) || typeof log.address !== 'string' || typeof log.data !== 'string' || !Array.isArray(log.topics)) continue
    parsedLogs.push({
      address: log.address as Address,
      data: log.data as Hex,
      topics: log.topics.filter((t): t is Hex => typeof t === 'string'),
    })
  }
  return {
    transactionHash: transactionHash as Hex,
    status: status === '0x1' ? 'success' : 'reverted',
    blockNumber: BigInt(blockNumber),
    logs: parsedLogs,
  }
}

function pause(tick: number): number {
  if (tick < 20) return 500
  if (tick < 80) return 1_000
  return 2_000
}

/** Polls until the receipt exists, or returns null once `timeoutMs` (default 4 minutes) has passed. */
export async function waitForReceipt(hash: Hex, options: WaitOptions): Promise<RawReceipt | null> {
  const requestTimeout = options.requestTimeoutMs ?? 8_000
  const sources: Array<{ name: string; read: () => Promise<unknown> }> = options.rpcUrls.map((url) => ({
    name: url,
    read: () => fetchReceipt(url, hash, requestTimeout),
  }))
  const wallet = options.wallet
  if (wallet) {
    sources.push({
      name: 'wallet',
      read: () => withTimeout(wallet.request({ method: 'eth_getTransactionReceipt', params: [hash] }), requestTimeout),
    })
  }
  if (sources.length === 0) return null

  const deadline = Date.now() + (options.timeoutMs ?? 240_000)
  let tick = 0
  while (Date.now() < deadline) {
    if (options.signal?.aborted) return null
    let backoff = 0
    for (let attempt = 0; attempt < sources.length; attempt++) {
      const source = sources[(tick + attempt) % sources.length]
      if (!source) continue
      try {
        const receipt = parseReceipt(await source.read())
        if (receipt) return receipt
        break // reachable but not mined there yet: wait, then ask the next source
      } catch (error) {
        if (error instanceof HttpStatusError && error.status === 429) backoff = 1_500
        options.onWarn?.(`${source.name}: ${error instanceof Error ? error.message : String(error)}`)
      }
    }
    tick++
    await sleep(pause(tick) + backoff)
  }
  return null
}
