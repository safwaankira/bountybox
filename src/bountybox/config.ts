/**
 * BountyBox deployment config. One place decides which network the app talks to
 * and which contract address it uses. Values come from `.env` (VITE_ keys are public).
 *
 * To point the app at another network: add it to NETWORKS, set
 * VITE_BOUNTYBOX_NETWORK to its key, and set VITE_BOUNTYBOX_ADDRESS to the
 * contract deployed there. Nothing else in the app hardcodes a chain or address.
 */

import { isAddress, type Address } from 'viem'
import { arc, arcTestnet } from 'viem/chains'
import { getUsdc, requireChain } from '@/onchain-facts'

const NETWORKS = {
  'arc-testnet': { chain: arcTestnet },
  /** Real USDC. Only selectable by setting VITE_BOUNTYBOX_NETWORK; see DEPLOY_MAINNET.md. */
  'arc-mainnet': { chain: arc },
} as const

type NetworkKey = keyof typeof NETWORKS

function isNetworkKey(value: string): value is NetworkKey {
  return value in NETWORKS
}

const rawNetwork: string = import.meta.env.VITE_BOUNTYBOX_NETWORK ?? 'arc-testnet'
if (!isNetworkKey(rawNetwork)) {
  throw new Error(`VITE_BOUNTYBOX_NETWORK "${rawNetwork}" is not configured. Known: ${Object.keys(NETWORKS).join(', ')}`)
}

const rawAddress: string = import.meta.env.VITE_BOUNTYBOX_ADDRESS ?? ''
if (!isAddress(rawAddress)) {
  throw new Error(
    rawNetwork === 'arc-mainnet'
      ? 'Arc Mainnet selected but VITE_BOUNTYBOX_ADDRESS is empty. Deploy first (DEPLOY_MAINNET.md), then set it.'
      : 'VITE_BOUNTYBOX_ADDRESS is missing or not a valid address',
  )
}

export const BOUNTYBOX_NETWORK: NetworkKey = rawNetwork
export const BOUNTYBOX_CHAIN = NETWORKS[rawNetwork].chain
export const CHAIN_ID = BOUNTYBOX_CHAIN.id
export const BOUNTYBOX_ADDRESS: Address = rawAddress

/** First block worth scanning for this contract's events. */
export const BOUNTYBOX_DEPLOY_BLOCK: bigint = BigInt(import.meta.env.VITE_BOUNTYBOX_DEPLOY_BLOCK ?? '0')

export const CHAIN_NAME = requireChain(CHAIN_ID).name
/** True when the app is pointed at a network that moves real funds. */
export const IS_MAINNET = !requireChain(CHAIN_ID).isTestnet

if (IS_MAINNET && BOUNTYBOX_DEPLOY_BLOCK <= 0n) {
  throw new Error('Set VITE_BOUNTYBOX_DEPLOY_BLOCK to the mainnet deployment block so event lookups never start at block 0.')
}

const usdcFact = getUsdc(CHAIN_ID)
if (!usdcFact) {
  throw new Error(`USDC is not registered for chain ${CHAIN_ID}`)
}
export const USDC_ADDRESS: Address = usdcFact.address as Address

/** Keep this much USDC out of "Max" because gas on Arc is paid in USDC too. */
export const GAS_RESERVE_RAW = 100_000n // 0.10 USDC
