import { Clock, Trophy, Users, FileCheck2 } from 'lucide-react'
import { Link } from '@/router'
import { bountyState, refundOpensAt, type Bounty } from '@/bountybox/data'
import { AiBadge } from '@/components/JudgeIdentity'
import { fmtUsdc, timeLeft } from '@/bountybox/format'
import { AddressText } from '@/components/CopyButton'

export function StateTag({ bounty, now }: { bounty: Bounty; now: number }) {
  const state = bountyState(bounty, now)
  const styles: Record<string, { label: string; color?: string; border?: string }> = {
    open: { label: 'Open' },
    grace: { label: 'Grace period', color: 'var(--accent)', border: 'rgba(172,198,233,0.4)' },
    expired: { label: 'Expired', color: 'var(--warn)', border: 'rgba(240,198,116,0.35)' },
    refunded: { label: 'Refunded', color: 'var(--warn)', border: 'rgba(240,198,116,0.35)' },
    paid: { label: 'Paid out', color: 'var(--success)', border: 'rgba(141,216,159,0.35)' },
  }
  const style = styles[state] ?? styles.open
  return (
    <span className="tag" style={{ color: style?.color, borderColor: style?.border }}>
      {style?.label}
    </span>
  )
}

export function BountyCard({ bounty, now }: { bounty: Bounty; now: number }) {
  const state = bountyState(bounty, now)
  const left = timeLeft(bounty.expiry, now)
  const amount = state === 'paid' ? bounty.paidAmount : bounty.pot

  return (
    // The card is not itself a link, so the copy buttons inside it are valid interactive content.
    // A stretched link covers the card; the copy buttons sit above it.
    <div className="card relative p-4 transition-colors hover:bg-white/10 sm:p-5">
      <Link
        to={`/bounty/${bounty.id}`}
        aria-label={`Open bounty ${bounty.id.toString()}: ${bounty.title}`}
        className="absolute inset-0 rounded-[1.5rem] focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        style={{ outlineColor: 'var(--accent)' }}
      />
      <div className="pointer-events-none relative flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="display truncate text-lg font-semibold text-balance" style={{ color: 'var(--ink)' }}>
            {bounty.title}
          </h3>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs" style={{ color: 'var(--subtle)' }}>
            <span>
              #{bounty.id.toString()} · by <AddressText address={bounty.poster} label="poster address" />
            </span>
            {bounty.aiMode && <AiBadge />}
          </p>
        </div>
        <div className="shrink-0 text-right">
          <div className="display text-2xl font-bold tabular-nums leading-none" style={{ color: 'var(--ink)' }}>
            {fmtUsdc(amount)}
          </div>
          <div className="mt-1 text-[11px] font-semibold tracking-wider" style={{ color: 'var(--subtle)' }}>
            USDC
          </div>
        </div>
      </div>

      <div className="pointer-events-none relative mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs" style={{ color: 'var(--muted)' }}>
        {state === 'paid' && bounty.winner ? (
          <span className="flex items-center gap-1.5" style={{ color: 'var(--success)' }}>
            <Trophy className="size-3.5" aria-hidden /> Won by <AddressText address={bounty.winner} label="winner address" />
          </span>
        ) : state === 'grace' ? (
          <span className="flex items-center gap-1.5" style={{ color: 'var(--accent)' }}>
            <Clock className="size-3.5" aria-hidden /> {bounty.aiMode ? 'AI judge can still decide for' : 'Poster can pick for'} {timeLeft(refundOpensAt(bounty), now).label.replace(' left', '')}
          </span>
        ) : state === 'open' ? (
          <span className="flex items-center gap-1.5" style={{ color: left.urgent ? 'var(--warn)' : undefined }}>
            <Clock className="size-3.5" aria-hidden /> {left.label}
          </span>
        ) : (
          <span className="flex items-center gap-1.5" style={{ color: 'var(--warn)' }}>
            <Clock className="size-3.5" aria-hidden /> {state === 'refunded' ? 'Fully refunded' : 'Refunds open'}
          </span>
        )}
        <span className="flex items-center gap-1.5 tabular-nums">
          <FileCheck2 className="size-3.5" aria-hidden /> {bounty.claimCount} {bounty.claimCount === 1 ? 'claim' : 'claims'}
        </span>
        <span className="flex items-center gap-1.5 tabular-nums">
          <Users className="size-3.5" aria-hidden /> {bounty.contributorCount}{' '}
          {bounty.contributorCount === 1 ? 'backer' : 'backers'}
        </span>
      </div>
    </div>
  )
}
