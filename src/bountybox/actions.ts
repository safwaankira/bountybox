import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { decodeEventLog, erc20Abi, isAddressEqual } from 'viem'
import { JudgeMode, bountyBoxAbi } from './abi'
import { BOUNTYBOX_ADDRESS, CHAIN_ID, USDC_ADDRESS } from './config'
import { useUsdcAccount } from './data'
import type { RawLog } from './receipt'
import { useTxFlow, type Step } from './tx'

/** Reads the new bounty id out of the BountyCreated event in a raw receipt. */
function createdIdFromLogs(logs: RawLog[] | null): bigint | null {
  for (const log of logs ?? []) {
    if (!isAddressEqual(log.address, BOUNTYBOX_ADDRESS)) continue
    const [first, ...rest] = log.topics
    if (!first) continue
    try {
      const decoded = decodeEventLog({ abi: bountyBoxAbi, data: log.data, topics: [first, ...rest] })
      if (decoded.eventName === 'BountyCreated') return decoded.args.id
    } catch {
      // some other event
    }
  }
  return null
}

export function useBountyActions() {
  const { address } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const { writeContractAsync } = useWriteContract()
  const flow = useTxFlow()
  const { allowance } = useUsdcAccount()

  // Fresh onchain reads (never the cached UI values) for every decision that gates a transaction.
  const readAllowance = async (): Promise<bigint> => {
    if (!client || !address) return 0n
    return client.readContract({
      address: USDC_ADDRESS,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [address, BOUNTYBOX_ADDRESS],
    })
  }
  const readCount = async (): Promise<bigint> => {
    if (!client) return 0n
    return client.readContract({ address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'bountyCount' })
  }
  const readShare = async (bountyId: bigint): Promise<bigint> => {
    if (!client || !address) return 0n
    return client.readContract({
      address: BOUNTYBOX_ADDRESS,
      abi: bountyBoxAbi,
      functionName: 'contributionOf',
      args: [bountyId, address],
    })
  }
  const readClaimsBy = async (bountyId: bigint): Promise<bigint> => {
    if (!client || !address) return 0n
    return client.readContract({
      address: BOUNTYBOX_ADDRESS,
      abi: bountyBoxAbi,
      functionName: 'claimsBy',
      args: [bountyId, address],
    })
  }

  /** Skipped entirely (no wallet prompt) when the current allowance already covers the amount. */
  const approveStep = (amount: bigint): Step => ({
    label: 'Allow USDC',
    skip: async () => (await readAllowance()) >= amount,
    send: () =>
      writeContractAsync({
        address: USDC_ADDRESS,
        abi: erc20Abi,
        functionName: 'approve',
        args: [BOUNTYBOX_ADDRESS, amount],
        chainId: CHAIN_ID,
      }),
    confirmed: async () => (await readAllowance()) >= amount,
  })

  const create = async (input: {
    title: string
    description: string
    criteria: string
    expiry: number
    amount: bigint
    aiMode: boolean
    requireHandle: boolean
  }) => {
    const { title, description, criteria, expiry, amount, aiMode, requireHandle } = input
    let before = 0n
    let foundId: bigint | null = null
    const result = await flow.run([
      approveStep(amount),
      {
        label: 'Create bounty',
        send: async () => {
          before = await readCount()
          return writeContractAsync({
            address: BOUNTYBOX_ADDRESS,
            abi: bountyBoxAbi,
            functionName: 'createBounty',
            args: [title, description, criteria, BigInt(expiry), amount, aiMode ? JudgeMode.AI : JudgeMode.Poster, requireHandle],
            chainId: CHAIN_ID,
          })
        },
        confirmed: async () => {
          if (!client || !address) return false
          const after = await readCount()
          for (let id = before + 1n; id <= after; id++) {
            const bounty = await client.readContract({
              address: BOUNTYBOX_ADDRESS,
              abi: bountyBoxAbi,
              functionName: 'getBounty',
              args: [id],
            })
            if (isAddressEqual(bounty.poster, address) && bounty.title === title) {
              foundId = id
              return true
            }
          }
          return false
        },
      },
    ])
    if (!result) return null
    return createdIdFromLogs(result.logs) ?? foundId
  }

  const contribute = (bountyId: bigint, amount: bigint) => {
    let before = 0n
    return flow.run(
      [
        approveStep(amount),
        {
          label: 'Add to pot',
          send: async () => {
            before = await readShare(bountyId)
            return writeContractAsync({
              address: BOUNTYBOX_ADDRESS,
              abi: bountyBoxAbi,
              functionName: 'contribute',
              args: [bountyId, amount],
              chainId: CHAIN_ID,
            })
          },
          confirmed: async () => (await readShare(bountyId)) >= before + amount,
        },
      ],
      bountyId.toString(),
    )
  }

  const submitClaim = (bountyId: bigint, proofURL: string, note: string, handle: string) => {
    let before = 0n
    return flow.run(
      [
        {
          label: 'Submit claim',
          send: async () => {
            before = await readClaimsBy(bountyId)
            return writeContractAsync({
              address: BOUNTYBOX_ADDRESS,
              abi: bountyBoxAbi,
              functionName: 'submitClaim',
              args: [bountyId, proofURL, note, handle],
              chainId: CHAIN_ID,
            })
          },
          confirmed: async () => (await readClaimsBy(bountyId)) > before,
        },
      ],
      bountyId.toString(),
    )
  }

  const acceptClaim = (bountyId: bigint, claimId: bigint) =>
    flow.run(
      [
        {
          label: 'Accept claim',
          send: () =>
            writeContractAsync({
              address: BOUNTYBOX_ADDRESS,
              abi: bountyBoxAbi,
              functionName: 'acceptClaim',
              args: [bountyId, claimId],
              chainId: CHAIN_ID,
            }),
          confirmed: async () => {
            if (!client) return false
            const bounty = await client.readContract({
              address: BOUNTYBOX_ADDRESS,
              abi: bountyBoxAbi,
              functionName: 'getBounty',
              args: [bountyId],
            })
            return bounty.hasAccepted && bounty.winningClaimId === claimId
          },
        },
      ],
      bountyId.toString(),
    )

  const refund = (bountyId: bigint) =>
    flow.run(
      [
        {
          label: 'Refund my share',
          send: () =>
            writeContractAsync({
              address: BOUNTYBOX_ADDRESS,
              abi: bountyBoxAbi,
              functionName: 'refund',
              args: [bountyId],
              chainId: CHAIN_ID,
            }),
          confirmed: async () => (await readShare(bountyId)) === 0n,
        },
      ],
      bountyId.toString(),
    )

  return { flow, create, contribute, submitClaim, acceptClaim, refund, allowance }
}
