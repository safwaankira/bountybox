import { Bot, ExternalLink, ShieldCheck } from 'lucide-react'
import { buildAddressExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID } from '@/bountybox/config'
import { useAiJudge } from '@/bountybox/data'
import { AddressText } from '@/components/CopyButton'
import { IDENTITY_REGISTRY, JUDGE_AGENT_ID, useJudgeIdentity } from '@/bountybox/judge'

/** One name for the judge everywhere in the UI. */
export const AI_JUDGE_LABEL = 'AI judge (two independent models must agree)'

export function AiBadge({ className = '' }: { className?: string }) {
  return (
    <span
      className={`tag ${className}`}
      style={{ color: 'var(--accent)', borderColor: 'rgba(172,198,233,0.45)' }}
      title="Paid only if both independent AI models approve a claim"
    >
      <Bot className="size-3" aria-hidden /> AI-judged
    </span>
  )
}

/** The judge's onchain identity: its wallet from the contract, and its ERC-8004 agent registration when configured. */
export function JudgeIdentity() {
  const judge = useAiJudge()
  const identity = useJudgeIdentity()
  const matches = Boolean(identity && judge && identity.owner.toLowerCase() === judge.toLowerCase())

  if (!judge) {
    return (
      <section className="inner p-3.5 text-sm" aria-label="AI judge identity" style={{ color: 'var(--muted)' }}>
        Reading the judge wallet from the contract…
      </section>
    )
  }

  return (
    <section className="inner space-y-2 p-3.5 text-sm" aria-label="AI judge identity">
      <div className="flex items-center justify-between gap-2">
        <span className="flex items-center gap-1.5 font-semibold">
          <Bot className="size-4" aria-hidden style={{ color: 'var(--accent)' }} />
          {AI_JUDGE_LABEL}
        </span>
        {JUDGE_AGENT_ID !== null && (
          <span className="tag" style={matches ? { color: 'var(--success)', borderColor: 'rgba(141,216,159,0.4)' } : undefined}>
            <ShieldCheck className="size-3" aria-hidden /> ERC-8004 agent #{JUDGE_AGENT_ID.toString()}
          </span>
        )}
      </div>
      {identity?.name && (
        <p className="text-xs font-medium" style={{ color: 'var(--ink-2)' }}>
          Registered as “{identity.name}”
        </p>
      )}
      {identity?.description && (
        <p className="text-pretty" style={{ color: 'var(--muted)' }}>
          {identity.description}
        </p>
      )}
      <dl className="space-y-1 text-xs" style={{ color: 'var(--muted)' }}>
        <div className="flex justify-between gap-3">
          <dt>Judge wallet (set in the contract, cannot change)</dt>
          <dd>
            <AddressText address={judge} label="judge address" href={buildAddressExplorerUrl(CHAIN_ID, judge)} />
          </dd>
        </div>
        {JUDGE_AGENT_ID !== null && (
          <div className="flex justify-between gap-3">
            <dt>Identity registry</dt>
            <dd>
              <a
                href={buildAddressExplorerUrl(CHAIN_ID, IDENTITY_REGISTRY)}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 underline-offset-2 hover:underline"
              >
                {identity ? (matches ? 'Owner matches the judge wallet' : 'Registered') : 'View registry'} <ExternalLink className="size-3" aria-hidden />
              </a>
            </dd>
          </div>
        )}
      </dl>
      <p className="text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
        The judge can only pay a claim to the hunter who submitted it. It cannot refund, withdraw or redirect funds. If it
        never acts, backers get their shares back after the deadline and grace period.
      </p>
    </section>
  )
}
