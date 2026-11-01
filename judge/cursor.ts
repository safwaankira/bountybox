import type { Store } from './types'

/**
 * Per-bounty progress, persisted so a tick can stop at any point (budget, timeout, crash) and the next tick
 * resumes exactly there instead of re-reading every claim. Claim spam therefore costs a bounded amount of
 * work per tick, however many claims a bounty has.
 */
export interface BountyCursor {
  /** Every claim below this index has a final decision (rejected, accepted or closed) and is never visited again. */
  settled: number
  /** Where the next tick resumes scanning. Wraps back to `settled` after the last claim. */
  next: number
  /** Where the close-out pass resumes once the bounty is finished. */
  closeNext: number
}

export const EMPTY_CURSOR: BountyCursor = { settled: 0, next: 0, closeNext: 0 }

export function cursorKey(chainId: number, bountyId: bigint): string {
  return `cursor/${chainId}/${bountyId}.json`
}
export function ownersKey(chainId: number, bountyId: bigint): string {
  return `proofs/${chainId}/${bountyId}.json`
}

function nonNegativeInt(value: unknown): number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : 0
}

export async function readCursor(store: Store, chainId: number, bountyId: bigint): Promise<BountyCursor> {
  const text = await store.getText(cursorKey(chainId, bountyId))
  if (!text) return { ...EMPTY_CURSOR }
  try {
    const raw = JSON.parse(text) as Record<string, unknown>
    const settled = nonNegativeInt(raw.settled)
    return { settled, next: Math.max(settled, nonNegativeInt(raw.next)), closeNext: nonNegativeInt(raw.closeNext) }
  } catch {
    return { ...EMPTY_CURSOR }
  }
}

export async function writeCursor(store: Store, chainId: number, bountyId: bigint, cursor: BountyCursor): Promise<void> {
  await store.setText(cursorKey(chainId, bountyId), JSON.stringify(cursor), 'application/json')
}

/** Hash of the normalized proof link -> id of the earliest claim that used it. */
export type ProofOwners = Record<string, number>

export async function readOwners(store: Store, chainId: number, bountyId: bigint): Promise<ProofOwners> {
  const text = await store.getText(ownersKey(chainId, bountyId))
  if (!text) return {}
  try {
    const raw = JSON.parse(text) as Record<string, unknown>
    const owners: ProofOwners = {}
    for (const [key, value] of Object.entries(raw)) if (typeof value === 'number' && Number.isInteger(value) && value >= 0) owners[key] = value
    return owners
  } catch {
    return {}
  }
}

export async function writeOwners(store: Store, chainId: number, bountyId: bigint, owners: ProofOwners): Promise<void> {
  await store.setText(ownersKey(chainId, bountyId), JSON.stringify(owners), 'application/json')
}
