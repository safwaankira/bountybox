import type { Facts } from './evidence'
import { parseHandle } from './evidence/classify'
import type { BountyView, Check, ClaimView, Evidence } from './types'

/**
 * Deterministic checks run BEFORE any model. A failed check rejects the claim without spending model calls.
 * Evidence is data: nothing in it can change these results.
 */

const CLOCK_SKEW_SECONDS = 3_600

export interface CheckInput {
  bounty: BountyView
  claim: ClaimView
  evidence: Evidence
  facts: Facts
}

function pass(name: string, detail: string): Check {
  return { name, ok: true, detail }
}
function fail(name: string, detail: string): Check {
  return { name, ok: false, detail }
}

function datedAfterBounty(name: string, publishedAt: string | null, bounty: BountyView, claim: ClaimView, approximate = false): Check {
  if (!publishedAt) return fail(name, 'The evidence has no verifiable date.')
  const seconds = Math.floor(Date.parse(publishedAt) / 1000)
  if (Number.isNaN(seconds)) return fail(name, 'The evidence date could not be read.')
  // Calendar-only sources (oEmbed) are rounded down to midnight, so allow one extra day.
  const slack = approximate ? 86_400 : 0
  if (seconds + slack < bounty.createdAt) {
    return fail(name, `Dated ${publishedAt}, before the bounty was posted (${new Date(bounty.createdAt * 1000).toISOString()}).`)
  }
  if (seconds > claim.timestamp + CLOCK_SKEW_SECONDS) return fail(name, `Dated ${publishedAt}, after the claim was submitted.`)
  return pass(name, `Dated ${publishedAt}, after the bounty was posted.`)
}

function handleCheck(input: CheckInput): Check | null {
  const raw = input.claim.handle
  const required = input.bounty.requireHandle
  if (!raw.trim()) return required ? fail('handle_linked', 'This bounty requires a linked handle and the claim has none.') : null
  const handle = parseHandle(raw)
  if (!handle) return fail('handle_linked', `The linked handle "${raw}" is not valid. Use github:name or x:name.`)
  const author = input.evidence.author
  if (!author) {
    return required
      ? fail('handle_linked', 'The handle cannot be verified from this kind of evidence (it has no author).')
      : pass('handle_linked', 'A handle was given but this kind of evidence has no author to compare, so it was not used.')
  }
  if (handle.platform && handle.platform !== author.platform) {
    return fail('handle_linked', `The handle is on ${handle.platform} but the evidence author is on ${author.platform}.`)
  }
  if (handle.username.toLowerCase() !== author.username.toLowerCase()) {
    return fail('handle_linked', `The linked handle @${handle.username} does not match the evidence author @${author.username}.`)
  }
  return pass('handle_linked', `Linked handle @${handle.username} matches the evidence author.`)
}

export function runChecks(input: CheckInput): Check[] {
  const { facts, bounty, claim } = input
  const checks: Check[] = []

  if (facts.kind === 'github-pr') {
    const pr = facts.pr
    checks.push(pr.found ? pass('pr_exists', `Found ${pr.baseRepo} pull request.`) : fail('pr_exists', 'The pull request was not found.'))
    if (pr.found) {
      checks.push(pr.merged ? pass('pr_merged', `Merged at ${pr.mergedAt ?? 'unknown time'}.`) : fail('pr_merged', `The pull request is ${pr.state} and not merged.`))
      if (pr.merged) checks.push(datedAfterBounty('pr_dated_after_bounty', pr.mergedAt, bounty, claim))
    }
  } else if (facts.kind === 'x-post') {
    if (!facts.post) {
      checks.push(fail('post_exists', 'The post was not found.'))
    } else {
      checks.push(pass('post_exists', `Read the post through ${facts.post.source}.`))
      checks.push(
        facts.post.authorUsername.toLowerCase() === facts.urlUsername.toLowerCase()
          ? pass('post_author_matches_url', `The post author is @${facts.post.authorUsername}.`)
          : fail('post_author_matches_url', `The URL names @${facts.urlUsername} but the post author is @${facts.post.authorUsername}.`),
      )
      checks.push(datedAfterBounty('post_dated_after_bounty', facts.post.createdAt, bounty, claim, facts.post.source === 'oembed'))
    }
  } else if (facts.kind === 'onchain-tx') {
    const tx = facts.tx
    checks.push(tx.found ? pass('tx_exists', `Found the transaction in block ${tx.blockNumber}.`) : fail('tx_exists', 'The transaction was not found on that chain.'))
    if (tx.found) {
      checks.push(tx.success ? pass('tx_succeeded', 'The transaction succeeded.') : fail('tx_succeeded', 'The transaction reverted.'))
      checks.push(
        tx.from === claim.hunter.toLowerCase()
          ? pass('tx_sent_by_hunter', 'The transaction was sent by the claiming wallet.')
          : fail('tx_sent_by_hunter', `The transaction was sent by ${tx.from}, not the claiming wallet.`),
      )
      checks.push(datedAfterBounty('tx_dated_after_bounty', tx.timestamp ? new Date(tx.timestamp * 1000).toISOString() : null, bounty, claim))
    }
  } else if ('unreachable' in facts.web) {
    checks.push(fail('page_reachable', facts.web.unreachable))
  } else {
    checks.push(pass('page_reachable', `The page loaded (HTTP ${facts.web.status}).`))
  }

  const handle = handleCheck(input)
  if (handle) checks.push(handle)
  return checks
}

export function allPassed(checks: Check[]): boolean {
  return checks.length > 0 && checks.every((c) => c.ok)
}
