/**
 * wagmi configuration
 * Built with Arc Studio — https://studio.arc.io
 */

import { http, createConfig } from 'wagmi'
import { mainnet } from 'wagmi/chains'
import { arc, arcTestnet } from 'viem/chains'
import { injected } from 'wagmi/connectors'
import { registerChain } from './tracing'
import { BOUNTYBOX_CHAIN } from './bountybox/config'
import { resilientTransport } from './bountybox/rpc'

// Pre-register chain RPC URLs so trace events show correct chain names immediately
registerChain(BOUNTYBOX_CHAIN.id, BOUNTYBOX_CHAIN.rpcUrls.default.http[0])

export const config = createConfig({
  chains: [BOUNTYBOX_CHAIN, mainnet], // mainnet needed for ENS resolution
  connectors: [injected()],
  // The active chain is whichever BOUNTYBOX_CHAIN resolves to; both Arc transports are declared so the
  // type stays exact when VITE_BOUNTYBOX_NETWORK switches networks.
  transports: {
    [arcTestnet.id]: resilientTransport(arcTestnet),
    [arc.id]: resilientTransport(arc),
    [mainnet.id]: http(), // ENS resolution uses mainnet
  },
})
