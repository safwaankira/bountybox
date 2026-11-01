import { findDuplicateOf } from './dedupe'
import { runChecks, allPassed } from './checks'
import type { ChainReader } from './chain'
import type { JudgeConfig } from './config'
import { buildEvidence, type EvidenceBundle } from './evidence'
import { TransientError } from './evidence/errors'
import type { XFetcher } from './evidence/x'
import { decide, MIN_CONFIDENCE, ModelOutputError, type ModelScorer } from './llm'
import { errorMessage, log as defaultLog, type Logger } from './log'
import type { JudgeSigner } from './signer'
import type { BountyView, ClaimStatus, ClaimView, Store } from './types'
import { buildVerdict, publishEvidence, readStatus, summarizeReasons, verdictKey, verdictURL, writeStatus } from './verdict'

export interface JudgeDeps {
  config: Pick<JudgeConfig, 'baseURL' | 'baseIsLocal' | 'maxClaimsPerTick' | 'tickBudgetMs' | 'githubToken' | 'xBearerToken'>
  store: Store
  chain: ChainReader
  /** Null runs the worker in read-and-publish mode: verdicts are published but nothing is sent onchain. */
  signer: JudgeSigner | null
  scorers: ModelScorer[]
  xFetchers?: XFetcher[]
  /** Test seam. Production leaves this unset. */
  evidenceBuilder?: typeof buildEvidence
  nowSeconds?: () => number
  log?: Logger
}

export interface TickSummary {
  scanned: number
  evaluated: number
  accepted: number
  rejected: number
  retrying: number
  skipped?: string
}

const LEASE_SECONDS = 13 * 60
const BACKOFF_BASE_SECONDS = 60
const BACKOFF_MAX_SECONDS = 30 * 60

function backoff(attempts: number): number {
  return Math.min(BACKOFF_MAX_SECONDS, BACKOFF_BASE_SECONDS * 2 ** Math.max(0, attempts - 1))
}

/* ------------------------------- lease ------------------------------- */

async function acquireLease(deps: JudgeDeps, now: number): Promise<boolean> {
  const key = `lock/${deps.chain.chainId}.json`
  const text = await deps.store.getText(key)
  if (text) {
    try {
      const lease = JSON.parse(text) as { until?: number }
      if (typeof lease.until === 'number' && lease.until > now) return false
    } catch {
      // a corrupt lease is treated as expired
    }
  }
  await deps.store.setText(key, JSON.stringify({ until: now + LEASE_SECONDS }), 'application/json')
  return true
}

async function releaseLease(deps: JudgeDeps): Promise<void> {
  await deps.store.setText(`lock/${deps.chain.chainId}.json`, JSON.stringify({ until: 0 }), 'application/json')
}

/* --------------------------- closed bounty set --------------------------- */

async function readClosed(deps: JudgeDeps): Promise<Set<string>> {
  const text = await deps.store.getText(`closed/${deps.chain.chainId}.json`)
  try {
    return new Set<string>(text ? (JSON.parse(text) as string[]) : [])
  } catch {
    return new Set()
  }
}

async function writeClosed(deps: JudgeDeps, closed: Set<string>): Promise<void> {
  await deps.store.setText(`closed/${deps.chain.chainId}.json`, JSON.stringify([...closed]), 'application/json')
}

/* -------------------------------- tick -------------------------------- */

export async function runJudgeTick(deps: JudgeDeps): Promise<TickSummary> {
  const log = deps.log ?? defaultLog
  const nowSeconds = deps.nowSeconds ?? (() => Math.floor(Date.now() / 1000))
  const startedAt = Date.now()
  const summary: TickSummary = { scanned: 0, evaluated: 0, accepted: 0, rejected: 0, retrying: 0 }

  if (!(await acquireLease(deps, nowSeconds()))) return { ...summary, skipped: 'another run holds the lease' }

  try {
    // Refuse to run if the signing wallet is not the contract's judge: judgeAccept would just revert.
    const judge = await deps.chain.aiJudge()
    if (deps.signer) {
      const signerAddress = await deps.signer.address()
      if (signerAddress.toLowerCase() !== judge.toLowerCase()) {
        throw new Error(`The signing wallet ${signerAddress} is not the contract's aiJudge ${judge}`)
      }
    }
    if (await deps.chain.judgeRetired()) {
      log('the judge has been retired onchain: nothing will be reviewed or paid')
      return { ...summary, skipped: 'judge retired onchain' }
    }
    if (deps.scorers.length < 2) throw new Error('Both model providers (OpenAI and Gemini) must be configured')

    const closed = await readClosed(deps)
    const count = await deps.chain.bountyCount()
    let work = 0

    for (let n = 1; n <= count; n++) {
      const id = BigInt(n)
      if (closed.has(id.toString())) continue
      const bounty = await deps.chain.getBounty(id)
      summary.scanned++

      const now = nowSeconds()
      if (!bounty.aiMode) {
        closed.add(id.toString())
        continue
      }
      const done = bounty.status !== 'open' || bounty.hasAccepted || (bounty.claimCount > 0 ? now >= bounty.settlementTime : now >= bounty.expiry)
      if (done) {
        await markUnresolvedClosed(deps, bounty)
        closed.add(id.toString())
        continue
      }
      if (bounty.claimCount === 0) continue

      const claims = await deps.chain.getClaims(id)
      for (const claim of claims) {
        if (work >= deps.config.maxClaimsPerTick || Date.now() - startedAt > deps.config.tickBudgetMs) {
          await writeClosed(deps, closed)
          return { ...summary, skipped: 'work budget reached; continuing next run' }
        }
        const outcome = await processClaim(deps, judge, bounty, claim, claims, log, nowSeconds)
        if (outcome === 'idle') continue
        work++
        if (outcome === 'evaluating-done') summary.evaluated++
        if (outcome === 'accepted') {
          summary.evaluated++
          summary.accepted++
          closed.add(id.toString())
          await markUnresolvedClosed(deps, { ...bounty, status: 'paid', hasAccepted: true })
          break
        }
        if (outcome === 'rejected') {
          summary.evaluated++
          summary.rejected++
        }
        if (outcome === 'retry') summary.retrying++
      }
    }
    await writeClosed(deps, closed)
    return summary
  } finally {
    await releaseLease(deps)
  }
}

/** Marks claims that never got a decision as closed so the UI stops showing "pending". */
async function markUnresolvedClosed(deps: JudgeDeps, bounty: BountyView): Promise<void> {
  if (bounty.claimCount === 0) return
  const claims = await deps.chain.getClaims(bounty.id)
  for (const claim of claims) {
    const status = await readStatus(deps.store, deps.chain.chainId, bounty.id, claim.id)
    if (status && (status.state === 'accepted' || status.state === 'rejected' || status.state === 'closed')) continue
    const now = (deps.nowSeconds ?? (() => Math.floor(Date.now() / 1000)))()
    await writeStatus(deps.store, deps.chain.chainId, bounty.id, claim.id, {
      state: 'closed',
      attempts: status?.attempts ?? 0,
      nextAttemptAt: 0,
      updatedAt: now,
      verdictURL: status?.verdictURL,
      verdictHash: status?.verdictHash,
      evidenceURL: status?.evidenceURL,
      reasons: status?.reasons,
      lastError: undefined,
    })
  }
}

type Outcome = 'idle' | 'evaluating-done' | 'accepted' | 'rejected' | 'retry' | 'approved-pending'

async function processClaim(
  deps: JudgeDeps,
  judge: `0x${string}`,
  bounty: BountyView,
  claim: ClaimView,
  claims: readonly ClaimView[],
  log: Logger,
  nowSeconds: () => number,
): Promise<Outcome> {
  const chainId = deps.chain.chainId
  const existing = await readStatus(deps.store, chainId, bounty.id, claim.id)
  const now = nowSeconds()
  const status: ClaimStatus = existing ?? { state: 'pending', attempts: 0, nextAttemptAt: 0, updatedAt: now }

  if (status.state === 'accepted' || status.state === 'rejected' || status.state === 'closed') return 'idle'
  if (status.state === 'approved') return finalize(deps, bounty, claim, status, log, nowSeconds)
  if (status.nextAttemptAt > now) return 'idle'

  // The same proof link may only win for the claim that submitted it first. No evidence or model call is needed.
  const duplicateOf = findDuplicateOf(claim, claims)
  if (duplicateOf !== null) {
    const checks = [
      {
        name: 'duplicate_proof',
        ok: false,
        detail: `Duplicate of claim #${duplicateOf}: this proof link was already submitted earlier on this bounty, and the earliest claim wins.`,
      },
    ]
    const reasons = summarizeReasons(checks, [], false)
    const { json, hash } = buildVerdict({
      chainId,
      contract: deps.chain.contract,
      judge,
      bounty,
      claim,
      checks,
      models: [],
      approved: false,
      reasons,
      evidence: null,
      minConfidence: MIN_CONFIDENCE,
      now: new Date(nowSeconds() * 1000),
    })
    await deps.store.setText(verdictKey(chainId, bounty.id, claim.id), json, 'application/json')
    await writeStatus(deps.store, chainId, bounty.id, claim.id, {
      state: 'rejected',
      attempts: status.attempts,
      nextAttemptAt: 0,
      updatedAt: nowSeconds(),
      verdictURL: verdictURL(deps.config.baseURL, chainId, bounty.id, claim.id),
      verdictHash: hash,
      reasons,
    })
    log(`bounty ${bounty.id} claim ${claim.id}: rejected (duplicate of claim ${duplicateOf})`)
    return 'rejected'
  }

  log(`evaluating bounty ${bounty.id} claim ${claim.id}`)
  let bundle: EvidenceBundle
  try {
    bundle = await (deps.evidenceBuilder ?? buildEvidence)({ claim, bounty, config: deps.config, xFetchers: deps.xFetchers })
  } catch (error) {
    return recordRetry(deps, bounty, claim, status, error, log, nowSeconds)
  }

  const checks = runChecks({ bounty, claim, evidence: bundle.evidence, facts: bundle.facts })
  let models: Awaited<ReturnType<ModelScorer['score']>>[] = []
  let approved = false

  if (allPassed(checks)) {
    const images = bundle.blobs.filter((b) => b.path.startsWith('img/'))
    const results = await Promise.allSettled(deps.scorers.map((scorer) => scorer.score({ bounty, claim, evidence: bundle.evidence, checks, images })))
    const failure = results.find((r): r is PromiseRejectedResult => r.status === 'rejected')
    if (failure) {
      const reason = failure.reason as unknown
      // A malformed or failed model answer is retried later, never turned into a rejection.
      return recordRetry(deps, bounty, claim, status, reason instanceof ModelOutputError ? new TransientError(reason.message) : reason, log, nowSeconds)
    }
    models = results.map((r) => (r as PromiseFulfilledResult<(typeof models)[number]>).value)
    approved = decide(models)
  }

  // An approval is about to be written onchain with links in it: never let those point at localhost.
  if (approved && deps.config.baseIsLocal) {
    return recordRetry(
      deps,
      bounty,
      claim,
      status,
      new Error('JUDGE_PUBLIC_BASE_URL is not a public origin; refusing to publish an approval whose links would be written onchain'),
      log,
      nowSeconds,
    )
  }

  const published = await publishEvidence(deps.store, deps.config.baseURL, bundle.evidence, bundle.blobs)
  const reasons = summarizeReasons(checks, models, approved)
  const { json, hash } = buildVerdict({
    chainId,
    contract: deps.chain.contract,
    judge,
    bounty,
    claim,
    checks,
    models,
    approved,
    reasons,
    evidence: published,
    minConfidence: MIN_CONFIDENCE,
    now: new Date(nowSeconds() * 1000),
  })
  await deps.store.setText(verdictKey(chainId, bounty.id, claim.id), json, 'application/json')
  const url = verdictURL(deps.config.baseURL, chainId, bounty.id, claim.id)

  const next: ClaimStatus = {
    state: approved ? 'approved' : 'rejected',
    attempts: status.attempts,
    nextAttemptAt: 0,
    updatedAt: nowSeconds(),
    verdictURL: url,
    verdictHash: hash,
    evidenceURL: published.url,
    reasons,
  }
  await writeStatus(deps.store, chainId, bounty.id, claim.id, next)
  log(`bounty ${bounty.id} claim ${claim.id}: ${next.state}`)

  if (!approved) return 'rejected'
  return finalize(deps, bounty, claim, next, log, nowSeconds)
}

async function recordRetry(
  deps: JudgeDeps,
  bounty: BountyView,
  claim: ClaimView,
  status: ClaimStatus,
  error: unknown,
  log: Logger,
  nowSeconds: () => number,
): Promise<Outcome> {
  const attempts = status.attempts + 1
  const now = nowSeconds()
  const message = errorMessage(error)
  log(`bounty ${bounty.id} claim ${claim.id}: will retry (attempt ${attempts}): ${message}`)
  await writeStatus(deps.store, deps.chain.chainId, bounty.id, claim.id, {
    ...status,
    state: 'error',
    attempts,
    nextAttemptAt: now + backoff(attempts),
    updatedAt: now,
    lastError: message.slice(0, 300),
  })
  return 'retry'
}

/** Sends judgeAccept for an approved claim, after re-checking the chain. Safe to call repeatedly. */
async function finalize(
  deps: JudgeDeps,
  bounty: BountyView,
  claim: ClaimView,
  status: ClaimStatus,
  log: Logger,
  nowSeconds: () => number,
): Promise<Outcome> {
  const chainId = deps.chain.chainId
  const now = nowSeconds()
  const fresh = await deps.chain.getBounty(bounty.id)

  if (fresh.hasAccepted || fresh.status !== 'open') {
    const verdictHash = await deps.chain.getVerdictHash(bounty.id)
    const ours = verdictHash.toLowerCase() === (status.verdictHash ?? '').toLowerCase()
    await writeStatus(deps.store, chainId, bounty.id, claim.id, { ...status, state: ours ? 'accepted' : 'closed', updatedAt: now, nextAttemptAt: 0 })
    return ours ? 'accepted' : 'idle'
  }
  if (now >= fresh.settlementTime) {
    await writeStatus(deps.store, chainId, bounty.id, claim.id, { ...status, state: 'closed', updatedAt: now, nextAttemptAt: 0 })
    return 'idle'
  }
  if (!deps.signer || !status.verdictHash || !status.verdictURL) return 'approved-pending'
  if (status.nextAttemptAt > now) return 'approved-pending'

  try {
    const sent = await deps.signer.judgeAccept({ bountyId: bounty.id, claimId: claim.id, verdictHash: status.verdictHash, verdictURI: status.verdictURL })
    const after = await deps.chain.getBounty(bounty.id)
    if (!after.hasAccepted) throw new Error('judgeAccept completed but the bounty is not closed onchain yet')
    await writeStatus(deps.store, chainId, bounty.id, claim.id, {
      ...status,
      state: 'accepted',
      updatedAt: nowSeconds(),
      nextAttemptAt: 0,
      txId: sent.txId,
      txHash: sent.txHash ?? undefined,
      lastError: undefined,
    })
    log(`bounty ${bounty.id} claim ${claim.id}: paid out (judgeAccept confirmed)`)
    return 'accepted'
  } catch (error) {
    const attempts = status.attempts + 1
    const message = errorMessage(error)
    log(`bounty ${bounty.id} claim ${claim.id}: judgeAccept failed (attempt ${attempts}): ${message}`)
    await writeStatus(deps.store, chainId, bounty.id, claim.id, {
      ...status,
      attempts,
      updatedAt: nowSeconds(),
      nextAttemptAt: nowSeconds() + backoff(attempts),
      lastError: message.slice(0, 300),
    })
    return 'retry'
  }
}
