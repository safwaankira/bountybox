import { TransientError, assertNotTransient, guard } from './errors'

export interface TxFacts {
  found: boolean
  success: boolean
  from: string
  to: string
  blockNumber: number
  timestamp: number | null
  /** First 4 bytes of calldata, which names the function that was called. */
  selector: string
  valueWei: string
  logCount: number
  logAddresses: string[]
}

async function rpc(urls: string[], method: string, params: unknown[]): Promise<unknown> {
  let lastError = 'no RPC reachable'
  for (const url of urls) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(8_000),
      })
      assertNotTransient(res.status, 'RPC')
      if (!res.ok) throw new Error(`RPC returned HTTP ${res.status}`)
      const body = (await res.json()) as { result?: unknown; error?: { message?: string } }
      if (body.error) throw new Error(body.error.message ?? 'RPC error')
      return body.result ?? null
    } catch (error) {
      lastError = error instanceof Error ? error.message : 'RPC failed'
    }
  }
  throw new TransientError(`RPC lookup failed: ${lastError}`)
}

function obj(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
}
function hexNum(value: unknown): number {
  return typeof value === 'string' && value.startsWith('0x') ? Number.parseInt(value, 16) : 0
}

export async function fetchTxFacts(rpcUrls: string[], hash: string): Promise<TxFacts> {
  return guard('Transaction lookup', async () => {
    const [txRaw, receiptRaw] = await Promise.all([rpc(rpcUrls, 'eth_getTransactionByHash', [hash]), rpc(rpcUrls, 'eth_getTransactionReceipt', [hash])])
    const tx = obj(txRaw)
    const receipt = obj(receiptRaw)
    if (!receiptRaw || !txRaw) {
      return { found: false, success: false, from: '', to: '', blockNumber: 0, timestamp: null, selector: '', valueWei: '0', logCount: 0, logAddresses: [] }
    }
    const blockNumber = hexNum(receipt.blockNumber)
    const block = obj(await rpc(rpcUrls, 'eth_getBlockByNumber', [`0x${blockNumber.toString(16)}`, false]))
    const input = typeof tx.input === 'string' ? tx.input : '0x'
    const logs = Array.isArray(receipt.logs) ? receipt.logs : []
    return {
      found: true,
      success: receipt.status === '0x1',
      from: typeof tx.from === 'string' ? tx.from.toLowerCase() : '',
      to: typeof tx.to === 'string' ? tx.to.toLowerCase() : '',
      blockNumber,
      timestamp: block.timestamp ? hexNum(block.timestamp) : null,
      selector: input.slice(0, 10),
      valueWei: typeof tx.value === 'string' ? BigInt(tx.value).toString() : '0',
      logCount: logs.length,
      logAddresses: [...new Set(logs.map((l) => (typeof obj(l).address === 'string' ? String(obj(l).address).toLowerCase() : '')))].filter(Boolean).slice(0, 10),
    }
  })
}
