import { Info } from 'lucide-react'
import { useJudgeLimits } from '@/bountybox/data'
import { fmtUsdc } from '@/bountybox/format'

/**
 * Short, plain disclosures about how the contract behaves. Shown on the bounty page and while posting.
 * `ai` adds the AI cap note (only when it applies to what the person is looking at).
 */
export function SafetyNotes({ ai, className = '' }: { ai: boolean; className?: string }) {
  const { maxAIPot } = useJudgeLimits()
  return (
    <aside className={`inner p-3.5 text-xs ${className}`} aria-label="Good to know" style={{ color: 'var(--muted)' }}>
      <p className="flex items-center gap-1.5 font-semibold" style={{ color: 'var(--ink-2)' }}>
        <Info className="size-3.5" aria-hidden /> Good to know
      </p>
      <ul className="mt-2 list-disc space-y-1.5 pl-5 text-pretty">
        <li>
          <span className="font-semibold" style={{ color: 'var(--ink-2)' }}>Always use this app to add money.</span> USDC sent straight to the contract
          is not credited to any bounty and cannot be recovered by anyone.
        </li>
        <li>
          A single claim submitted before the deadline, even a junk one, adds a 7 day grace period before refunds open.
        </li>
        {ai && (
          <li>
            {maxAIPot !== undefined ? `The ${fmtUsdc(maxAIPot)} USDC` : 'The'} AI bounty cap applies to each AI-judged bounty on its own. It is not a
            total across bounties.
          </li>
        )}
        <li>
          If USDC has blocklisted your address, your own share cannot be refunded to you. Everyone else&apos;s refunds are unaffected.
        </li>
      </ul>
    </aside>
  )
}
