/**
 * Creates the judge's Circle developer-controlled wallet (EOA on Arc Testnet) and prints its address.
 * That address is what you pass to the contract constructor as the immutable aiJudge.
 *   bun run judge:setup            judge wallet only
 *   bun run judge:setup --test     also create poster and hunter wallets for the end-to-end test
 * Wallet ids are appended to .env; the script never prints API keys or the entity secret.
 */
import { appendEnv, circleClient } from './judge-lib'

const withTestWallets = process.argv.includes('--test')
const sdk = circleClient()

async function walletAddress(id: string): Promise<string> {
  const wallet = (await sdk.getWallet({ id })).data?.wallet
  if (!wallet?.address) throw new Error(`Wallet ${id} not found`)
  return wallet.address
}

let judgeId = process.env.JUDGE_WALLET_ID?.trim()
if (judgeId) {
  console.log(`Judge wallet already configured: ${await walletAddress(judgeId)} (id ${judgeId})`)
} else {
  const set = await sdk.createWalletSet({ name: 'BountyBox judge' })
  const walletSetId = set.data?.walletSet?.id
  if (!walletSetId) throw new Error('Could not create a wallet set')
  const created = await sdk.createWallets({ accountType: 'EOA', blockchains: ['ARC-TESTNET'], count: withTestWallets ? 3 : 1, walletSetId })
  const wallets = created.data?.wallets ?? []
  const [judge, poster, hunter] = wallets
  if (!judge?.id || !judge.address) throw new Error('Wallet creation returned no wallet')
  judgeId = judge.id
  appendEnv('JUDGE_WALLET_ID', judge.id)
  console.log(`Judge wallet created: ${judge.address} (id ${judge.id})`)
  if (withTestWallets && poster?.id && hunter?.id) {
    appendEnv('E2E_POSTER_WALLET_ID', poster.id)
    appendEnv('E2E_HUNTER_WALLET_ID', hunter.id)
    console.log(`Test poster wallet:  ${poster.address}`)
    console.log(`Test hunter wallet:  ${hunter.address}`)
  }
}
console.log('Fund the judge wallet with a little testnet USDC for gas, then deploy the contract with this address as AI_JUDGE.')
