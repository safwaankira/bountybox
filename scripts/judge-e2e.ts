/**
 * TESTNET end-to-end test of an AI-judged bounty, using the Circle test wallets from `judge:setup --test`.
 *   1. test poster approves USDC and creates an AI bounty (0.5 USDC, 1 hour)
 *   2. test hunter submits a claim that should FAIL (example.com) and one that should PASS (arc.io ERC-8183 post)
 *   3. one judge pass runs locally (same code as the Netlify function)
 *   4. prints the onchain result: status, verdict hash/URI, hunter balance change
 * Never prints secrets. Refuses to run on mainnet.
 */
import { createPublicClient, http, parseAbi, formatUnits, type Address } from 'viem'
import { arcTestnet } from 'viem/chains'
import { createDeps } from '../judge/deps'
import { missingForProduction } from '../judge/config'
import { runJudgeTick } from '../judge/run'
import { FsStore } from '../judge/store'
import { waitForTerminal, isSuccessfulTransactionState } from '../src/onchain-wait'
import { circleClient, requireEnv } from './judge-lib'

const env = requireEnv('VITE_BOUNTYBOX_ADDRESS', 'E2E_POSTER_WALLET_ID', 'E2E_HUNTER_WALLET_ID')
if ((process.env.VITE_BOUNTYBOX_NETWORK ?? 'arc-testnet') !== 'arc-testnet') {
  console.error('judge-e2e runs on arc-testnet only.'); process.exit(2)
}
const CONTRACT = env.VITE_BOUNTYBOX_ADDRESS as Address
const USDC = '0x3600000000000000000000000000000000000000' as Address
const AMOUNT = 500_000n // 0.5 USDC
const sdk = circleClient()
const pub = createPublicClient({ chain: arcTestnet, transport: http() })
const abi = parseAbi([
  'function bountyCount() view returns (uint256)',
  'function effectiveStatus(uint256) view returns (uint8)',
  'function getVerdict(uint256) view returns (bytes32, string)',
  'function balanceOf(address) view returns (uint256)',
])
const STATUS = ['Open', 'Expired', 'Paid', 'Refunded']

async function addressOf(id: string): Promise<Address> {
  const w = (await sdk.getWallet({ id })).data?.wallet
  if (!w?.address) throw new Error(`wallet ${id} not found`)
  return w.address as Address
}

async function exec(label: string, walletId: string, contractAddress: Address, sig: string, params: string[]) {
  const created = await sdk.createContractExecutionTransaction({
    walletId, contractAddress, abiFunctionSignature: sig, abiParameters: params,
    fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
  })
  const id = created.data?.id
  if (!id) throw new Error(`${label}: Circle returned no tx id`)
  const final = await waitForTerminal(async () => sdk.getTransaction({ id }), (r) => r.data?.transaction?.state, { intervalMs: 2_000, timeoutMs: 180_000 })
  const tx = final.data?.transaction
  if (!isSuccessfulTransactionState(tx?.state)) throw new Error(`${label}: ended in state ${tx?.state} ${tx?.errorReason ?? ''}`)
  console.log(`OK    ${label}  https://testnet.arcscan.app/tx/${tx?.txHash}`)
}

const poster = await addressOf(env.E2E_POSTER_WALLET_ID)
const hunter = await addressOf(env.E2E_HUNTER_WALLET_ID)
console.log(`contract ${CONTRACT}\nposter   ${poster}\nhunter   ${hunter}`)

const expiry = Math.floor(Date.now() / 1000) + 3600
const criteria = 'The proof URL must be a public web page on arc.io that explains the ERC-8183 job-escrow standard, i.e. a client escrows payment for a job and an evaluator approves or rejects the delivered work.'

await exec('poster approve 0.5 USDC', env.E2E_POSTER_WALLET_ID, USDC, 'approve(address,uint256)', [CONTRACT, AMOUNT.toString()])
await exec('poster createBounty (AI judge)', env.E2E_POSTER_WALLET_ID, CONTRACT,
  'createBounty(string,string,string,uint64,uint256,uint8,bool)',
  ['E2E: find Arc\'s ERC-8183 explainer', 'Testnet end-to-end check of the AI judge.', criteria, String(expiry), AMOUNT.toString(), '1', 'false'])
const bountyId = await pub.readContract({ address: CONTRACT, abi, functionName: 'bountyCount' })
console.log(`bounty  #${bountyId}`)

const before = await pub.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [hunter] })
await exec('hunter claim #0 (should be REJECTED)', env.E2E_HUNTER_WALLET_ID, CONTRACT, 'submitClaim(uint256,string,string,string)',
  [bountyId.toString(), 'https://example.com/', 'wrong page on purpose', ''])
await exec('hunter claim #1 (should be APPROVED)', env.E2E_HUNTER_WALLET_ID, CONTRACT, 'submitClaim(uint256,string,string,string)',
  [bountyId.toString(), 'https://www.arc.io/blog/running-an-agentic-economic-flow-on-arc-with-erc-8183', 'Arc blog post on ERC-8183', ''])

console.log('\nrunning one judge pass...')
const { config, deps } = createDeps(new FsStore('.judge-data'))
const missing = missingForProduction(config)
if (missing.length) { console.error(`missing configuration: ${missing.join('; ')}`); process.exit(2) }
if (config.baseIsLocal) {
  console.error('Set JUDGE_PUBLIC_BASE_URL to your public site origin (for example https://your-site.netlify.app). The verdict and evidence links are written onchain and must never point at localhost.')
  process.exit(2)
}
console.log('judge summary', JSON.stringify(await runJudgeTick(deps)))

const status = await pub.readContract({ address: CONTRACT, abi, functionName: 'effectiveStatus', args: [bountyId] })
const [hash, uri] = await pub.readContract({ address: CONTRACT, abi, functionName: 'getVerdict', args: [bountyId] })
const after = await pub.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [hunter] })
console.log(`\nstatus   ${STATUS[Number(status)] ?? status}\nverdict  ${hash}\nURI      ${uri || '(none)'}\nhunter   ${formatUnits(after - before, 6)} USDC change (claims cost a little gas)`)
console.log('Verdict files (including rejections) are in ./.judge-data')
