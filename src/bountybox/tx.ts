import { useCallback, useState, useSyncExternalStore } from 'react'
import { useAccount, usePublicClient } from 'wagmi'
import { useQueryClient } from '@tanstack/react-query'
import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, type Hex } from 'viem'
import { BOUNTYBOX_ADDRESS, BOUNTYBOX_CHAIN, CHAIN_ID } from './config'
import { waitForReceipt, type RawLog, type WalletProviderLike } from './receipt'
import { rpcUrlsFor } from './rpc'

/* ----------------------------- error messages ----------------------------- */

const REVERT_MESSAGES: Record<string, string> = {
  BountyNotFound: 'This bounty does not exist.',
  BountyNotOpen: 'This bounty is already closed.',
  BountyExpired: 'This bounty has expired.',
  AcceptWindowClosed: 'The window to accept a claim has closed.',
  RefundNotOpen: 'Refunds are not open yet.',
  ExpiryTooFar: 'Deadline can be at most 90 days from now.',
  TooManyClaims: 'You have already used your 3 claims on this bounty.',
  InvalidExpiry: 'Pick an expiry time in the future.',
  AmountTooSmall: 'The minimum amount is 0.01 USDC.',
  InvalidTitleLength: 'Title must be 1 to 100 characters.',
  DescriptionTooLong: 'Description is too long.',
  InvalidProofURLLength: 'Proof link must be 1 to 500 characters.',
  NoteTooLong: 'Note is too long.',
  PosterCannotSubmitClaim: 'The poster cannot claim their own bounty.',
  OnlyPoster: 'Only the poster can accept a claim.',
  ClaimNotFound: 'That claim does not exist.',
  NoContribution: 'You have no share to refund here.',
  JudgeRetired: 'The AI judge has been retired, so AI-judged bounties can no longer take new money or claims.',
  AIPotCapExceeded: 'That would put this AI-judged bounty over the maximum allowed pot.',
  HandleRequired: 'This bounty requires your GitHub or X handle.',
  JudgedByAI: 'This bounty is judged by the AI judge, so nobody can accept a claim by hand.',
}

/** Returns null when the user simply cancelled in their wallet. */
export function describeError(error: unknown): string | null {
  if (error instanceof BaseError) {
    if (error.walk((e) => e instanceof UserRejectedRequestError)) return null
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError) {
      const name = revert.data?.errorName
      if (name && REVERT_MESSAGES[name]) return REVERT_MESSAGES[name]
      if (revert.reason) return revert.reason
    }
    const text = error.shortMessage.toLowerCase()
    if (text.includes('user rejected') || text.includes('denied')) return null
    if (text.includes('insufficient funds') || text.includes('exceeds balance')) {
      return 'Not enough USDC for this amount plus network fees.'
    }
    return error.shortMessage
  }
  if (error instanceof Error) {
    if (error.message.toLowerCase().includes('user rejected')) return null
    return error.message
  }
  return 'Something went wrong. Please try again.'
}

/* ---------------------------- local tx history ----------------------------- */

export interface TxRecord {
  hash: Hex
  label: string
  at: number
  bountyId?: string
}

const listeners = new Set<() => void>()
let cache: { key: string; raw: string; value: TxRecord[] } | undefined

function storageKey(address: string | undefined): string {
  return `bountybox:txs:${CHAIN_ID}:${BOUNTYBOX_ADDRESS.toLowerCase()}:${(address ?? 'none').toLowerCase()}`
}

function readHistory(address: string | undefined): TxRecord[] {
  const key = storageKey(address)
  const raw = localStorage.getItem(key) ?? '[]'
  if (cache && cache.key === key && cache.raw === raw) return cache.value
  let value: TxRecord[] = []
  try {
    value = JSON.parse(raw) as TxRecord[]
  } catch {
    value = []
  }
  cache = { key, raw, value }
  return value
}

function pushHistory(address: string | undefined, record: TxRecord) {
  const next = [record, ...readHistory(address)].slice(0, 100)
  localStorage.setItem(storageKey(address), JSON.stringify(next))
  for (const l of listeners) l()
}

export function useTxHistory(bountyId?: string): TxRecord[] {
  const { address } = useAccount()
  const all = useSyncExternalStore(
    (cb) => {
      listeners.add(cb)
      return () => listeners.delete(cb)
    },
    () => readHistory(address),
  )
  return bountyId ? all.filter((r) => r.bountyId === bountyId) : all
}

/* ------------------------------- tx runner -------------------------------- */

type Phase = 'idle' | 'wallet' | 'confirming' | 'success' | 'error'

interface FlowState {
  phase: Phase
  label: string
  hashes: TxRecord[]
  error?: string
}

const IDLE: FlowState = { phase: 'idle', label: '', hashes: [] }

export interface Step {
  label: string
  /** Checked right before sending. Return true to skip the step (for example the allowance already covers it). */
  skip?: () => Promise<boolean>
  send: () => Promise<Hex>
  /** Onchain state check, used when no receipt can be fetched in time. Return true if the action took effect. */
  confirmed?: () => Promise<boolean>
}

export interface RunResult {
  /** Logs of the last transaction, or null when it was confirmed from onchain state instead of a receipt. */
  logs: RawLog[] | null
}

const STATE_CHECKS = 5
const STATE_CHECK_GAP_MS = 2_000
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

async function confirmedByState(check: () => Promise<boolean>): Promise<boolean> {
  for (let i = 0; i < STATE_CHECKS; i++) {
    try {
      if (await check()) return true
    } catch {
      // keep trying; a failed read is not proof either way
    }
    await sleep(STATE_CHECK_GAP_MS)
  }
  return false
}

function isWalletProvider(value: unknown): value is WalletProviderLike {
  return typeof value === 'object' && value !== null && 'request' in value && typeof value.request === 'function'
}

export function useTxFlow() {
  const { address, connector } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const queryClient = useQueryClient()
  const [state, setState] = useState<FlowState>(IDLE)

  const reset = useCallback(() => setState(IDLE), [])

  const run = useCallback(
    async (steps: Step[], bountyId?: string): Promise<RunResult | null> => {
      if (!client) return null
      const hashes: TxRecord[] = []
      let last: RunResult = { logs: null }
      try {
        const provider: unknown = await connector?.getProvider().catch(() => null)
        const wallet = isWalletProvider(provider) ? provider : null

        for (const step of steps) {
          let skipped = false
          try {
            skipped = (await step.skip?.()) === true
          } catch {
            skipped = false // could not read; do the step rather than guess
          }
          if (skipped) continue

          setState({ phase: 'wallet', label: step.label, hashes: [...hashes] })
          const hash = await step.send()
          const record: TxRecord = { hash, label: step.label, at: Date.now(), bountyId }
          hashes.push(record)
          pushHistory(address, record)
          setState({ phase: 'confirming', label: step.label, hashes: [...hashes] })

          const receipt = await waitForReceipt(hash, { rpcUrls: rpcUrlsFor(BOUNTYBOX_CHAIN), wallet })
          if (receipt) {
            if (receipt.status !== 'success') throw new Error(`${step.label} failed onchain.`)
            last = { logs: receipt.logs }
          } else {
            // No receipt in time. Trust the chain's state over a missing receipt before reporting an error.
            const done = step.confirmed ? await confirmedByState(step.confirmed) : false
            if (!done) {
              throw new Error(
                `We could not confirm "${step.label}" yet. It may still be pending. Check the explorer link below, refresh the page, then try again only if it did not go through.`,
              )
            }
            last = { logs: null }
          }
        }
        await queryClient.invalidateQueries()
        setState({ phase: 'success', label: '', hashes: [...hashes] })
        return last
      } catch (error) {
        const message = describeError(error)
        setState(
          message === null
            ? { ...IDLE, hashes: [...hashes] }
            : { phase: 'error', label: '', hashes: [...hashes], error: message },
        )
        return null
      }
    },
    [client, address, connector, queryClient],
  )

  return { state, run, reset, busy: state.phase === 'wallet' || state.phase === 'confirming' }
}
