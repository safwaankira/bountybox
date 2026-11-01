/**
 * Registers the judge as an ERC-8004 agent on Arc Testnet, signed by the judge's own Circle wallet.
 * The registration file is embedded as a data: URI so no hosting is needed. The agent id is appended to
 * .env as VITE_JUDGE_AGENT_ID and the UI shows the identity.
 *   bun run judge:register
 */
import { decodeEventLog, parseAbi, type Hex } from 'viem'
import { waitForTerminal, isSuccessfulTransactionState } from '../src/onchain-wait'
import { appendEnv, circleClient, requireEnv } from './judge-lib'

const IDENTITY_REGISTRY = '0x8004A818BFB912233c491871b3d84c89A494BD9e'
const TESTNET_RPC = 'https://rpc.testnet.arc.io'
const abi = parseAbi([
  'function register(string agentURI) returns (uint256 agentId)',
  'event Registered(uint256 indexed agentId, string agentURI, address indexed owner)',
])

const { JUDGE_WALLET_ID: walletId, VITE_BOUNTYBOX_ADDRESS: bountyBox } = requireEnv('JUDGE_WALLET_ID', 'VITE_BOUNTYBOX_ADDRESS')
if (process.env.VITE_BOUNTYBOX_NETWORK === 'arc-mainnet') {
  console.error('Registration is testnet-only: the ERC-8004 registry address used here exists on Arc Testnet.')
  process.exit(2)
}
const baseURL = process.env.JUDGE_PUBLIC_BASE_URL ?? process.env.URL ?? ''

const card = {
  type: 'https://eips.ethereum.org/EIPS/eip-8004#registration-v1',
  name: 'BountyBox AI Judge',
  description:
    'Single evaluator for AI-judged BountyBox bounties. Checks claims with deterministic verifiers (GitHub, X, onchain) and two independent language models, publishes every verdict and evidence snapshot, and can only pay a claim to the hunter who submitted it.',
  services: baseURL ? [{ name: 'verdicts', endpoint: `${baseURL.replace(/\/+$/, '')}/verdicts`, version: '1' }] : [],
  x402Support: false,
  active: true,
  supportedTrust: ['reputation'],
  bountyBox,
}
const agentURI = `data:application/json;base64,${Buffer.from(JSON.stringify(card)).toString('base64')}`

const sdk = circleClient()
const created = await sdk.createContractExecutionTransaction({
  walletId,
  contractAddress: IDENTITY_REGISTRY,
  abiFunctionSignature: 'register(string)',
  abiParameters: [agentURI],
  fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
})
const txId = created.data?.id
if (!txId) throw new Error('Circle did not return a transaction id')
const final = await waitForTerminal(
  () => sdk.getTransaction({ id: txId }),
  (r) => r.data?.transaction?.state,
  { intervalMs: 2_000, timeoutMs: 120_000 },
)
const tx = final.data?.transaction
if (!isSuccessfulTransactionState(tx?.state) || !tx?.txHash) throw new Error(`Registration ended in state ${tx?.state ?? 'unknown'}`)

const receiptRes = await fetch(TESTNET_RPC, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getTransactionReceipt', params: [tx.txHash] }),
})
const receipt = ((await receiptRes.json()) as { result?: { logs?: Array<{ address: string; topics: Hex[]; data: Hex }> } }).result
let agentId: bigint | null = null
for (const log of receipt?.logs ?? []) {
  if (log.address.toLowerCase() !== IDENTITY_REGISTRY.toLowerCase()) continue
  try {
    const [first, ...rest] = log.topics
    if (!first) continue
    const decoded = decodeEventLog({ abi, data: log.data, topics: [first, ...rest] })
    if (decoded.eventName === 'Registered') agentId = decoded.args.agentId
  } catch {
    // not the Registered event
  }
}
if (agentId === null) throw new Error(`Registered, but the agent id was not found in transaction ${tx.txHash}`)
appendEnv('VITE_JUDGE_AGENT_ID', agentId.toString())
console.log(`Registered ERC-8004 agent #${agentId} (tx ${tx.txHash}). Restart the dev server to show it in the UI.`)
