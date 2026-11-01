import { useAccount } from 'wagmi'
import type { Contributor } from '@/bountybox/data'
import { fmtUsdc } from '@/bountybox/format'
import { AddressText } from '@/components/CopyButton'

export function Contributors({ contributors, total, poster }: { contributors: Contributor[]; total: bigint; poster: string }) {
  const { address } = useAccount()
  const sorted = [...contributors].sort((a, b) => (a.share === b.share ? 0 : a.share > b.share ? -1 : 1))

  return (
    <section className="card p-5">
      <h2 className="display text-xl font-semibold">
        Backers <span className="tabular-nums" style={{ color: 'var(--subtle)' }}>{contributors.length}</span>
      </h2>
      <ul className="mt-4 space-y-3">
        {sorted.map((c) => {
          const pct = total > 0n ? Number((c.share * 10_000n) / total) / 100 : 0
          const mine = address?.toLowerCase() === c.address.toLowerCase()
          return (
            <li key={c.address}>
              <div className="flex items-center justify-between gap-3 text-sm">
                <span className="flex items-center gap-2">
                  <span className="font-medium"><AddressText address={c.address} label="backer address" /></span>
                  {c.address.toLowerCase() === poster.toLowerCase() && <span className="tag">Poster</span>}
                  {mine && <span className="tag">You</span>}
                </span>
                <span className="tabular-nums font-semibold">{fmtUsdc(c.share)} USDC</span>
              </div>
              <div className="mt-1.5 h-1.5 overflow-hidden rounded-full" style={{ background: 'rgba(255,255,255,0.08)' }}>
                <div className="h-full rounded-full" style={{ width: `${pct}%`, background: 'var(--accent)' }} />
              </div>
            </li>
          )
        })}
      </ul>
    </section>
  )
}
