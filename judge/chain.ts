import { createPublicClient, type Address, type Hex, type PublicClient } from 'viem'
import { bountyBoxAbi, GRACE_PERIOD_SECONDS, JudgeMode } from '../src/bountybox/abi'
import { resilientTransport } from '../src/bountybox/rpc'
import type { JudgeConfig } from './config'
import type { BountyView, ClaimView } from './types'

export interface ChainReader {
  contract: Address
  chainId: number
  bountyCount(): Promise<number>
  aiJudge(): Promise<Address>
  /** True once the contract's guardian has permanently retired the judge (judgeAccept then always reverts). */
  judgeRetired(): Promise<boolean>
  getBounty(id: bigint): Promise<BountyView>
  /** One bounded page of claims (ids are offset + index). `total` is the bounty's claim count. */
  getClaimsPage(id: bigint, offset: number, limit: number): Promise<{ claims: ClaimView[]; total: number }>
  /** True once the bounty is closed onchain (paid). */
  isClosed(id: bigint): Promise<boolean>
  getVerdictHash(id: bigint): Promise<Hex>
}

export function createChainReader(config: JudgeConfig): ChainReader {
  const client: PublicClient = createPublicClient({ chain: config.chain, transport: resilientTransport(config.chain) })
  const address = config.contract

  return {
    contract: address,
    chainId: config.chain.id,
    async bountyCount() {
      return Number(await client.readContract({ address, abi: bountyBoxAbi, functionName: 'bountyCount' }))
    },
    async judgeRetired() {
      try {
        return await client.readContract({ address, abi: bountyBoxAbi, functionName: 'judgeRetired' })
      } catch {
        // Contracts deployed before the guardian was added have no such function: they cannot be retired.
        return false
      }
    },
    async aiJudge() {
      return client.readContract({ address, abi: bountyBoxAbi, functionName: 'aiJudge' })
    },
    async getBounty(id) {
      const b = await client.readContract({ address, abi: bountyBoxAbi, functionName: 'getBounty', args: [id] })
      const claimCount = Number(b.claimCount)
      const expiry = Number(b.expiry)
      return {
        id: b.id,
        poster: b.poster,
        title: b.title,
        description: b.description,
        criteria: b.criteria,
        expiry,
        createdAt: Number(b.createdAt),
        status: b.status === 1 ? 'paid' : b.status === 2 ? 'refunded' : 'open',
        hasAccepted: b.hasAccepted,
        aiMode: b.judgeMode === JudgeMode.AI,
        requireHandle: b.requireHandle,
        claimCount,
        settlementTime: claimCount > 0 ? expiry + GRACE_PERIOD_SECONDS : expiry,
      }
    },
    async getClaimsPage(id, offset, limit) {
      const toView = (c: { hunter: Address; proofURL: string; note: string; handle: string; timestamp: bigint }, index: number): ClaimView => ({
        id: index,
        hunter: c.hunter,
        proofURL: c.proofURL,
        note: c.note,
        handle: c.handle,
        timestamp: Number(c.timestamp),
      })
      try {
        const [page, total] = await client.readContract({
          address,
          abi: bountyBoxAbi,
          functionName: 'getClaimsPage',
          args: [id, BigInt(offset), BigInt(limit)],
        })
        return { claims: page.map((c, i) => toView(c, offset + i)), total: Number(total) }
      } catch (error) {
        // Contracts deployed before the paged view existed only have getClaims. Slice it so old deployments keep working.
        if (!/returned no data|could not be decoded|not a function|ContractFunctionZeroDataError|reverted/i.test(String((error as Error).message))) throw error
        const all = await client.readContract({ address, abi: bountyBoxAbi, functionName: 'getClaims', args: [id] })
        return { claims: all.slice(offset, offset + limit).map((c, i) => toView(c, offset + i)), total: all.length }
      }
    },
    async isClosed(id) {
      const b = await client.readContract({ address, abi: bountyBoxAbi, functionName: 'getBounty', args: [id] })
      return b.status !== 0 || b.hasAccepted
    },
    async getVerdictHash(id) {
      const [hash] = await client.readContract({ address, abi: bountyBoxAbi, functionName: 'getVerdict', args: [id] })
      return hash
    },
  }
}
