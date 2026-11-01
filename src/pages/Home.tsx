import { useState } from 'react'
import { Plus, Inbox } from 'lucide-react'
import { Link } from '@/router'
import { BountyCard } from '@/components/BountyCard'
import { JudgeIdentity } from '@/components/JudgeIdentity'
import { JudgeRetiredBanner } from '@/components/JudgeRetiredBanner'
import { bountyState, useBounties, useNow } from '@/bountybox/data'
import { fmtUsdc } from '@/bountybox/format'

type Tab = 'open' | 'expired' | 'paid'

const TABS: { id: Tab; label: string }[] = [
  { id: 'open', label: 'Open' },
  { id: 'expired', label: 'Expired' },
  { id: 'paid', label: 'Closed' },
]

const EMPTY: Record<Tab, { title: string; body: string }> = {
  open: { title: 'No open bounties', body: 'Post the first one and put some USDC behind it.' },
  expired: { title: 'Nothing expired', body: 'Bounties past their deadline show up here: first the poster’s grace period if claims came in, then refunds for backers.' },
  paid: { title: 'No payouts yet', body: 'Once a claim is accepted, by the poster or the AI judge, the bounty and its winner land here.' },
}

export function Home() {
  const [tab, setTab] = useState<Tab>('open')
  const now = useNow(15_000)
  const { bounties, isLoading, isError, refetch } = useBounties()

  const grouped: Record<Tab, typeof bounties> = { open: [], expired: [], paid: [] }
  for (const b of bounties) {
    const state = bountyState(b, now)
    grouped[state === 'open' ? 'open' : state === 'paid' ? 'paid' : 'expired'].push(b)
  }
  const openPot = grouped.open.reduce((sum, b) => sum + b.pot, 0n)
  const paidOut = grouped.paid.reduce((sum, b) => sum + b.paidAmount, 0n)
  const visible = grouped[tab]
  const nothingOpen = !isLoading && !isError && grouped.open.length === 0

  return (
    <div className="space-y-5">
      <JudgeRetiredBanner compact />
      <section className="card p-5 sm:p-6">
        {nothingOpen ? (
          <>
            <p className="label">{paidOut > 0n ? 'Paid out to hunters' : 'No bounties yet'}</p>
            {paidOut > 0n ? (
              <div className="mt-2 flex items-baseline gap-2">
                <span className="display text-5xl font-bold tabular-nums">{fmtUsdc(paidOut)}</span>
                <span className="text-lg font-medium" style={{ color: 'var(--subtle)' }}>
                  USDC
                </span>
              </div>
            ) : (
              <h1 className="display mt-2 text-3xl font-bold text-balance sm:text-4xl">Put USDC behind something you want done</h1>
            )}
            <p className="mt-2 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
              {paidOut > 0n
                ? `${grouped.paid.length} ${grouped.paid.length === 1 ? 'bounty' : 'bounties'} paid out so far. Nothing is open right now.`
                : 'The winner is paid straight from escrow, and if nobody wins every backer gets their share back.'}
            </p>
          </>
        ) : (
          <>
            <p className="label">Up for grabs right now</p>
            <div className="mt-2 flex items-baseline gap-2">
              <span className="display text-5xl font-bold tabular-nums">{isLoading ? '…' : fmtUsdc(openPot)}</span>
              <span className="text-lg font-medium" style={{ color: 'var(--subtle)' }}>
                USDC
              </span>
            </div>
            <p className="mt-2 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
              {isLoading
                ? 'Loading live bounties…'
                : `${grouped.open.length} open ${grouped.open.length === 1 ? 'bounty' : 'bounties'} · ${fmtUsdc(paidOut)} USDC paid out so far`}
            </p>
          </>
        )}
        <Link to="/new" className="btn btn-primary mt-4 w-full sm:w-auto">
          <Plus className="size-4" aria-hidden /> {nothingOpen ? 'Post the first bounty' : 'Post a bounty'}
        </Link>
      </section>

      <div role="tablist" aria-label="Bounty status" className="card flex gap-1 p-1">
        {TABS.map((t) => (
          <button
            key={t.id}
            role="tab"
            aria-selected={tab === t.id}
            className="tab"
            onClick={() => setTab(t.id)}
          >
            {t.label} <span className="tab-count tabular-nums">{isLoading ? '' : grouped[t.id].length}</span>
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="space-y-3" aria-busy="true">
          {[0, 1, 2].map((i) => (
            <div key={i} className="skeleton h-28" />
          ))}
        </div>
      ) : isError ? (
        <div className="card p-6 text-center">
          <p className="text-sm" style={{ color: 'var(--danger)' }}>
            Could not load bounties from the network.
          </p>
          <button className="btn btn-ghost mt-3" onClick={refetch}>
            Try again
          </button>
        </div>
      ) : visible.length === 0 ? (
        <div className="card flex flex-col items-center px-6 py-12 text-center">
          <Inbox className="size-8" style={{ color: 'var(--subtle)' }} aria-hidden />
          <h2 className="display mt-3 text-lg font-semibold">{EMPTY[tab].title}</h2>
          <p className="mt-1 max-w-xs text-sm text-pretty" style={{ color: 'var(--muted)' }}>
            {EMPTY[tab].body}
          </p>
        </div>
      ) : (
        <ul className="space-y-3">
          {visible.map((b) => (
            <li key={b.id.toString()}>
              <BountyCard bounty={b} now={now} />
            </li>
          ))}
        </ul>
      )}

      <JudgeIdentity />
    </div>
  )
}
