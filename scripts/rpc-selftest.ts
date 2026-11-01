/**
 * Read-only check of the app's receipt waiting and RPC failover against a live network. Sends no transactions.
 *
 *   bun run test:rpc <txHash> [rpcUrl]
 *
 * <txHash> is any already-mined transaction on the network selected by VITE_BOUNTYBOX_NETWORK.
 */

import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { createPublicClient, erc20Abi, type Hex } from 'viem'
import { arc, arcTestnet } from 'viem/chains'
import { parseReceipt, waitForReceipt } from '../src/bountybox/receipt'
import { resilientTransport, rpcUrlsFor } from '../src/bountybox/rpc'

const hash = process.argv[2] as Hex | undefined
if (!hash || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
  console.error('usage: bun run test:rpc <txHash> [rpcUrl]')
  process.exit(2)
}

const chain = process.env.VITE_BOUNTYBOX_NETWORK === 'arc-mainnet' ? arc : arcTestnet
const urls = rpcUrlsFor(chain)
const DEAD = 'http://127.0.0.1:9' // nothing listens here: connection refused
let failures = 0

function check(name: string, ok: boolean, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? ` (${detail})` : ''}`)
  if (!ok) failures++
}

async function rpc(url: string, method: string, params: unknown[]): Promise<unknown> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  })
  return ((await res.json()) as { result: unknown }).result
}

console.log(`network: ${chain.name} (${chain.id})  rpcs: ${urls.length}`)

// 1. viem fallback transport survives a dead first endpoint.
const client = createPublicClient({ chain, transport: resilientTransport({ ...chain, rpcUrls: { default: { http: [DEAD, ...urls] } } }) })
const head = await client.getBlockNumber().catch(() => null)
check('fallback transport skips a dead RPC and still reads the chain', head !== null, `head ${head}`)

// 2. waitForReceipt finds a real receipt even when the first source is dead.
let started = Date.now()
const found = await waitForReceipt(hash, { rpcUrls: [DEAD, ...urls], timeoutMs: 30_000 })
check('finds the receipt with a dead RPC first in the list', found !== null && found.status === 'success', found ? `block ${found.blockNumber}, ${Date.now() - started}ms` : 'not found')

// 3. Every public RPC agrees about the receipt.
for (const url of urls) {
  const raw = parseReceipt(await rpc(url, 'eth_getTransactionReceipt', [hash]).catch(() => null))
  check(`receipt visible on ${url}`, raw !== null && raw.blockNumber === found?.blockNumber)
}

// 4. A hash that does not exist returns null after the timeout instead of hanging or throwing.
started = Date.now()
const missing = await waitForReceipt(`0x${'11'.repeat(32)}`, { rpcUrls: urls, timeoutMs: 3_000 })
const took = Date.now() - started
check('unknown hash returns null at the timeout', missing === null && took >= 2_900 && took < 8_000, `${took}ms`)

// 5. A flaky RPC that answers 429 and "not found" before the real receipt does not break the wait.
let calls = 0
const flaky = createServer((req, res) => {
  calls++
  const chunks: Buffer[] = []
  req.on('data', (chunk: Buffer) => chunks.push(chunk))
  req.on('end', () => {
    if (calls <= 3) {
      res.writeHead(429).end('rate limited')
    } else if (calls <= 5) {
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ jsonrpc: '2.0', id: 1, result: null }))
    } else {
      fetch(urls[0] ?? '', { method: 'POST', headers: { 'content-type': 'application/json' }, body: Buffer.concat(chunks).toString() })
        .then((upstream) => upstream.text())
        .then((text) => res.writeHead(200, { 'content-type': 'application/json' }).end(text))
        .catch(() => res.writeHead(502).end())
    }
  })
})
await new Promise<void>((resolve) => flaky.listen(0, '127.0.0.1', resolve))
const flakyPort = (flaky.address() as AddressInfo).port
started = Date.now()
const survived = await waitForReceipt(hash, { rpcUrls: [`http://127.0.0.1:${flakyPort}`], timeoutMs: 30_000 })
flaky.close()
check('survives 429s and null answers, then finds the receipt', survived !== null && survived.status === 'success', `${calls} calls, ${Date.now() - started}ms`)

// 6. The state fallback the app uses: read the sender's allowance for BountyBox straight from the chain.
const tx = (await rpc(urls[0] ?? '', 'eth_getTransactionByHash', [hash])) as { from?: Hex } | null
const box = process.env.VITE_BOUNTYBOX_ADDRESS as Hex | undefined
const usdc = chain.id === arc.id || chain.id === arcTestnet.id ? '0x3600000000000000000000000000000000000000' : undefined
if (tx?.from && box && usdc) {
  const allowance = await client.readContract({ address: usdc, abi: erc20Abi, functionName: 'allowance', args: [tx.from, box] }).catch(() => null)
  check('can read the sender allowance from chain state', allowance !== null, `allowance(raw) ${allowance}`)
}

console.log(failures === 0 ? '\nall checks passed' : `\n${failures} check(s) failed`)
process.exit(failures === 0 ? 0 : 1)
