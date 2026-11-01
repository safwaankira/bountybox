import { ShieldAlert } from 'lucide-react'
import { useJudgeLimits } from '@/bountybox/data'

/** Shown on every page once the guardian has permanently retired the AI judge. */
export function JudgeRetiredBanner({ compact = false }: { compact?: boolean }) {
  const { retired } = useJudgeLimits()
  if (!retired) return null
  return (
    <div
      role="alert"
      className="flex items-start gap-3 rounded-2xl border p-4 text-sm"
      style={{ borderColor: 'rgba(240,198,116,0.45)', background: 'rgba(240,198,116,0.08)', color: 'var(--ink-2)' }}
    >
      <ShieldAlert className="mt-0.5 size-5 shrink-0" aria-hidden style={{ color: 'var(--warn)' }} />
      <div className="text-pretty">
        <p className="font-semibold" style={{ color: 'var(--warn)' }}>
          The AI judge has been retired
        </p>
        <p className="mt-1" style={{ color: 'var(--muted)' }}>
          {compact
            ? 'AI-judged bounties can no longer be paid out. They refund after the deadline and grace period.'
            : 'The contract’s guardian switched the AI judge off permanently. AI-judged bounties can no longer be paid out, take new money or accept new claims. Each backer gets their own share back after the deadline (plus the 7 day grace period if claims were waiting). Bounties where the poster picks the winner are not affected.'}
        </p>
      </div>
    </div>
  )
}
