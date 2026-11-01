import { initiateDeveloperControlledWalletsClient } from '@circle-fin/developer-controlled-wallets'
import { keccak256, toBytes, type Address, type Hex } from 'viem'
import { waitForTerminal, isSuccessfulTransactionState } from '../src/onchain-wait'
import type { JudgeConfig } from './config'

export interface JudgeAcceptRequest {
  bountyId: bigint
  claimId: number
  verdictHash: Hex
  verdictURI: string
}

export interface JudgeAcceptResult {
  txId: string
  txHash: Hex | null
}

/** Signs and sends judgeAccept. The only on-chain power the judge key has. */
export interface JudgeSigner {
  address(): Promise<Address>
  judgeAccept(request: JudgeAcceptRequest): Promise<JudgeAcceptResult>
}

/**
 * Deterministic UUID (v4 shaped) from the request, so a retry of the same decision reuses
 * the same Circle idempotency key instead of sending a second transaction.
 */
export function idempotencyKeyFor(request: JudgeAcceptRequest): string {
  const hex = keccak256(toBytes(`judgeAccept:${request.bountyId}:${request.claimId}:${request.verdictHash}`)).slice(2, 34)
  const variant = ((Number.parseInt(hex.charAt(16), 16) & 0x3) | 0x8).toString(16)
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-${variant}${hex.slice(17, 20)}-${hex.slice(20, 32)}`
}

export function createCircleSigner(circle: NonNullable<JudgeConfig['circle']>, contract: Address): JudgeSigner {
  const sdk = initiateDeveloperControlledWalletsClient({ apiKey: circle.apiKey, entitySecret: circle.entitySecret })

  return {
    async address() {
      const response = await sdk.getWallet({ id: circle.walletId })
      const wallet = response.data?.wallet
      if (!wallet?.address) throw new Error('Judge wallet not found for JUDGE_WALLET_ID')
      return wallet.address as Address
    },

    async judgeAccept(request) {
      const created = await sdk.createContractExecutionTransaction({
        walletId: circle.walletId,
        contractAddress: contract,
        abiFunctionSignature: 'judgeAccept(uint256,uint256,bytes32,string)',
        abiParameters: [request.bountyId.toString(), request.claimId.toString(), request.verdictHash, request.verdictURI],
        fee: { type: 'level', config: { feeLevel: 'MEDIUM' } },
        idempotencyKey: idempotencyKeyFor(request),
      })
      const txId = created.data?.id
      if (!txId) throw new Error('Circle did not return a transaction id')

      const final = await waitForTerminal(
        async () => sdk.getTransaction({ id: txId }),
        (response) => response.data?.transaction?.state,
        { intervalMs: 2_000, timeoutMs: 120_000 },
      )
      const tx = final.data?.transaction
      if (!isSuccessfulTransactionState(tx?.state)) {
        throw new Error(`judgeAccept transaction ended in state ${tx?.state ?? 'unknown'}`)
      }
      return { txId, txHash: (tx?.txHash as Hex | undefined) ?? null }
    },
  }
}
