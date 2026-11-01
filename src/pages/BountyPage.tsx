import { ArrowLeft, Clock, FileCheck2, ListChecks, Trophy, Users } from 'lucide-react'
import { useAccount } from 'wagmi'
import { Link } from '@/router'
import { Hourglass } from 'lucide-react'
import { AddToPot } from '@/components/AddToPot'
import { StateTag } from '@/components/BountyCard'
import { ClaimsList } from '@/components/ClaimsList'
import { AiBadge, JudgeIdentity } from '@/components/JudgeIdentity'
import { JudgeRetiredBanner } from '@/components/JudgeRetiredBanner'
import { SafetyNotes } from '@/components/SafetyNotes'
import { Contributors } from '@/components/Contributors'
import { RefundPanel } from '@/components/RefundPanel'
import { SubmitClaim } from '@/components/SubmitClaim'
import { TxLink } from '@/components/TxStatus'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID } from '@/bountybox/config'
import { bountyState, refundOpensAt, useBountyDetail, useJudgedInfo, useJudgeLimits, useMyContribution, useNow, usePayoutTx } from '@/bountybox/data'
import { fmtDate, fmtUsdc, timeLeft } from '@/bountybox/format'
import { AddressText } from '@/components/CopyButton'
import { usePagedClaims, usePagedContributors } from '@/bountybox/paging'
import { useClaimStatuses } from '@/bountybox/judge'
import { useTxHistory } from '@/bountybox/tx'

function BackLink() {
  return (
    <Link to="/" className="inline-flex items-center gap-1.5 text-sm" style={{ color: 'var(--muted)' }}>
      <ArrowLeft className="size-4" aria-hidden /> All bounties
    </Link>
  )
}

function AddressLink({ address, label = 'address' }: { address: string; label?: string }) {
  return <AddressText address={address} label={label} href={buildAddressExplorerUrl(CHAIN_ID, address)} />
}

export function BountyPage({ id }: { id: bigint }) {
  const now = useNow(1000)
  const { address } = useAccount()
  const { bounty, isLoading, notFound } = useBountyDetail(id)
  const claimPages = usePagedClaims(id)
  const contributorPages = usePagedContributors(id)
  const myShare = useMyContribution(id)
  const history = useTxHistory(id.toString())
  const payoutTx = usePayoutTx(id, Boolean(bounty?.hasAccepted))
  const { statuses, unreachable } = useClaimStatuses(
    id,
    Boolean(bounty?.aiMode),
    claimPages.items.map((c) => c.id),
  )
  const judged = useJudgedInfo(bounty)
  const limits = useJudgeLimits()

  if (isLoading) {
    return (
      <div className="space-y-4" aria-busy="true">
        <BackLink />
        <div className="skeleton h-48" />
        <div className="skeleton h-40" />
      </div>
    )
  }

  if (notFound || !bounty) {
    return (
      <div className="space-y-4">
        <BackLink />
        <div className="card p-8 text-center">
          <h1 className="display text-2xl font-semibold">Bounty not found</h1>
          <p className="mt-1 text-sm" style={{ color: 'var(--muted)' }}>
            There is no bounty #{id.toString()} on this contract.
          </p>
        </div>
      </div>
    )
  }

  const state = bountyState(bounty, now)
  const left = timeLeft(bounty.expiry, now)
  const isPoster = address?.toLowerCase() === bounty.poster.toLowerCase()
  const isOpen = state === 'open'
  const inGrace = state === 'grace'
  const refundable = state === 'expired' || state === 'refunded'
  const decideBy = refundOpensAt(bounty)

  return (
    <div className="space-y-4">
      <BackLink />

      <section className="card p-5 sm:p-6">
        <div className="flex items-start justify-between gap-3">
          <span className="flex flex-wrap items-center gap-2">
            <StateTag bounty={bounty} now={now} />
            {bounty.aiMode && <AiBadge />}
          </span>
          <span className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
            #{bounty.id.toString()}
          </span>
        </div>
        <h1 className="display mt-3 text-3xl font-bold text-balance">{bounty.title}</h1>
        <p className="mt-1 text-sm" style={{ color: 'var(--muted)' }}>
          Posted by <AddressLink address={bounty.poster} /> {isPoster && <span className="tag ml-1">You</span>} ·{' '}
          {fmtDate(bounty.createdAt)}
        </p>

        <div className="mt-5">
          <p className="label">{state === 'paid' ? 'Paid out' : refundable ? 'Left to refund' : 'Pot'}</p>
          <div className="mt-1 flex items-baseline gap-2">
            <span className="display text-5xl font-bold tabular-nums">
              {fmtUsdc(state === 'paid' ? bounty.paidAmount : bounty.pot)}
            </span>
            <span className="text-lg font-medium" style={{ color: 'var(--subtle)' }}>
              USDC
            </span>
          </div>
        </div>

        <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-sm tabular-nums" style={{ color: 'var(--muted)' }}>
          <span className="flex items-center gap-1.5" style={{ color: left.urgent && isOpen ? 'var(--warn)' : undefined }}>
            <Clock className="size-4" aria-hidden />
            {state === 'paid' ? 'Closed' : isOpen ? left.label : `Deadline passed ${fmtDate(bounty.expiry)}`}
          </span>
          <span className="flex items-center gap-1.5">
            <FileCheck2 className="size-4" aria-hidden /> {bounty.claimCount} {bounty.claimCount === 1 ? 'claim' : 'claims'}
          </span>
          <span className="flex items-center gap-1.5">
            <Users className="size-4" aria-hidden /> {bounty.contributorCount}{' '}
            {bounty.contributorCount === 1 ? 'backer' : 'backers'}
          </span>
        </div>

        {bounty.aiMode && limits.maxAIPot !== undefined && (
          <p className="mt-3 text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
            Max AI bounty: {fmtUsdc(limits.maxAIPot)} USDC (set in the contract)
          </p>
        )}

        {bounty.criteria && (
          <div className="inner mt-5 p-3.5">
            <p className="label flex items-center gap-1.5">
              <ListChecks className="size-3.5" aria-hidden /> {bounty.aiMode ? 'Acceptance criteria (the AI judge scores against this)' : 'Criteria'}
            </p>
            <p className="mt-1.5 whitespace-pre-wrap text-sm leading-relaxed text-pretty" style={{ color: 'var(--ink-2)' }}>
              {bounty.criteria}
            </p>
            {bounty.requireHandle && (
              <p className="mt-2 text-xs" style={{ color: 'var(--muted)' }}>
                Hunters must link a GitHub or X handle that matches the author of their proof.
              </p>
            )}
          </div>
        )}

        {bounty.description && (
          <p className="mt-5 whitespace-pre-wrap text-sm leading-relaxed text-pretty" style={{ color: 'var(--ink-2)' }}>
            {bounty.description}
          </p>
        )}
      </section>

      {state === 'paid' && bounty.winner && bounty.winningClaimId !== null && (
        <section className="card p-5" style={{ borderColor: 'rgba(141,216,159,0.45)', background: 'rgba(141,216,159,0.07)' }}>
          <div className="flex items-center gap-2 font-semibold" style={{ color: 'var(--success)' }}>
            <Trophy className="size-5" aria-hidden /> Winner
          </div>
          <p className="mt-2 text-sm">
            <AddressLink address={bounty.winner} /> received{' '}
            <span className="tabular-nums font-semibold">{fmtUsdc(bounty.paidAmount)} USDC</span> for claim #
            {bounty.winningClaimId.toString()}.
          </p>
          {payoutTx && (
            <div className="mt-2">
              <TxLink hash={payoutTx} label="Payout transaction" />
            </div>
          )}
        </section>
      )}

      {bounty.aiMode && <JudgeRetiredBanner />}

      {inGrace && (
        <section className="card space-y-1 p-5" style={{ borderColor: 'rgba(172,198,233,0.4)' }}>
          <div className="flex items-center gap-2 font-semibold" style={{ color: 'var(--accent)' }}>
            <Hourglass className="size-5" aria-hidden /> Grace period
          </div>
          <p className="text-sm text-pretty" style={{ color: 'var(--ink-2)' }}>
            The deadline passed with {bounty.claimCount} {bounty.claimCount === 1 ? 'claim' : 'claims'} waiting. {bounty.aiMode ? 'The AI judge' : 'The poster'} can still
            {bounty.aiMode ? ' decide' : ' pick a winner'} until {fmtDate(decideBy)} ({timeLeft(decideBy, now).label}). Refunds open after that if nobody is paid.
          </p>
        </section>
      )}

      {refundable && <RefundPanel bounty={bounty} myShare={myShare} fullyRefunded={state === 'refunded'} />}

      {isOpen && <AddToPot bounty={bounty} />}
      {isOpen && !isPoster && !(bounty.aiMode && limits.retired) && <SubmitClaim bounty={bounty} />}
      {(isOpen || inGrace) && isPoster && (
        <p className="card p-4 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          {bounty.aiMode
            ? 'You posted this AI-judged bounty. You cannot accept a claim or submit one; the judge decides.'
            : 'You posted this bounty, so you pick the winner below. You can’t submit a claim on your own bounty.'}
        </p>
      )}

      {bounty.aiMode && (
        <section className="card p-5">
          <h2 className="display text-xl font-semibold">AI judge (two independent models must agree)</h2>
          <div className="mt-3">
            <JudgeIdentity />
          </div>
        </section>
      )}

      <ClaimsList
        bounty={bounty}
        claims={claimPages.items}
        total={claimPages.total}
        hasMore={claimPages.hasMore}
        loadingMore={claimPages.isLoadingMore}
        onLoadMore={claimPages.loadMore}
        acceptable={isOpen || inGrace}
        statuses={statuses}
        judgeUnreachable={unreachable}
        judged={judged}
      />
      <Contributors
        contributors={contributorPages.items}
        count={bounty.contributorCount}
        hasMore={contributorPages.hasMore}
        loadingMore={contributorPages.isLoadingMore}
        onLoadMore={contributorPages.loadMore}
        total={state === 'paid' ? bounty.paidAmount : bounty.pot}
        poster={bounty.poster}
      />

      {history.length > 0 && (
        <section className="card p-5">
          <h2 className="display text-xl font-semibold">Your transactions</h2>
          <ul className="mt-3 space-y-2">
            {history.map((tx) => (
              <li key={tx.hash} className="flex items-center justify-between gap-3 text-sm">
                <span style={{ color: 'var(--ink-2)' }}>{tx.label}</span>
                <TxLink hash={tx.hash} label={`${tx.hash.slice(0, 8)}…${tx.hash.slice(-6)}`} />
              </li>
            ))}
          </ul>
        </section>
      )}

      <SafetyNotes ai={bounty.aiMode} />
    </div>
  )
}
