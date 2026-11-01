import { useState } from 'react'
import { ArrowLeft, Bot, UserCheck } from 'lucide-react'
import { Link, navigate } from '@/router'
import { AmountField } from '@/components/AmountField'
import { GateButton } from '@/components/GateButton'
import { JudgeIdentity } from '@/components/JudgeIdentity'
import { JudgeRetiredBanner } from '@/components/JudgeRetiredBanner'
import { TxStatus } from '@/components/TxStatus'
import { GRACE_PERIOD_SECONDS, LIMITS, MAX_DURATION_SECONDS, MIN_AMOUNT_RAW } from '@/bountybox/abi'
import { useJudgeLimits, useNow, useUsdcAccount } from '@/bountybox/data'
import { fmtDate, fmtUsdc, toDatetimeLocal, tryParseUsdc } from '@/bountybox/format'
import { useBountyActions } from '@/bountybox/actions'

const DURATIONS = [
  { id: '1', label: '1 day', seconds: 86_400 },
  { id: '3', label: '3 days', seconds: 3 * 86_400 },
  { id: '7', label: '7 days', seconds: 7 * 86_400 },
  { id: '30', label: '30 days', seconds: 30 * 86_400 },
  { id: '60', label: '60 days', seconds: 60 * 86_400 },
  { id: 'custom', label: 'Custom', seconds: 0 },
] as const

const MIN_LEAD_SECONDS = 300
/** Stay clear of the 90 day cap so a small clock difference with the chain cannot trip it. */
const MAX_LEAD_SECONDS = MAX_DURATION_SECONDS - 3_600
const byteLength = (s: string) => new TextEncoder().encode(s).length

export function Create() {
  const now = useNow(30_000)
  const { balance } = useUsdcAccount()
  const limits = useJudgeLimits()
  const { flow, create, allowance } = useBountyActions()

  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [duration, setDuration] = useState<string>('7')
  const [custom, setCustom] = useState('')
  const [amount, setAmount] = useState('')
  const [aiMode, setAiMode] = useState(false)
  const [criteria, setCriteria] = useState('')
  const [requireHandle, setRequireHandle] = useState(false)
  const [aiChosen, setAiChosen] = useState(false)

  const preset = DURATIONS.find((d) => d.id === duration)
  const customSeconds = custom ? Math.floor(new Date(custom).getTime() / 1000) : 0
  const expiry = duration === 'custom' ? customSeconds : now + (preset?.seconds ?? 0)
  const raw = tryParseUsdc(amount)

  const problem = (() => {
    if (!title.trim()) return 'Add a title'
    if (byteLength(title) > LIMITS.title) return `Title is over ${LIMITS.title} characters`
    if (byteLength(description) > LIMITS.description) return 'Description is too long'
    if (aiMode && limits.retired) return 'The AI judge has been retired, so new AI-judged bounties are blocked'
    if (aiMode && !criteria.trim()) return 'Write the acceptance criteria the AI judge will check'
    if (byteLength(criteria) > LIMITS.criteria) return `Criteria are over ${LIMITS.criteria} characters`
    if (!expiry || expiry < now + MIN_LEAD_SECONDS) return 'Pick an expiry at least 5 minutes from now'
    if (expiry > now + MAX_LEAD_SECONDS) return 'Deadline can be at most 90 days away'
    if (raw === null) return 'Enter a USDC amount'
    if (raw < MIN_AMOUNT_RAW) return 'Minimum deposit is 0.01 USDC'
    if (aiMode && limits.maxAIPot !== undefined && raw > limits.maxAIPot) return `AI-judged bounties are capped at ${fmtUsdc(limits.maxAIPot)} USDC`
    if (balance !== undefined && raw > balance) return 'Not enough USDC in your wallet'
    return null
  })()

  const needsAllowance = raw !== null && (allowance ?? 0n) < raw

  const submit = async () => {
    if (problem || raw === null) return
    const id = await create({
      title: title.trim(),
      description: description.trim(),
      criteria: criteria.trim(),
      expiry,
      amount: raw,
      aiMode,
      requireHandle: aiMode && requireHandle,
    })
    if (id !== null) navigate(`/bounty/${id}`)
  }

  return (
    <div className="space-y-5">
      <Link to="/" className="inline-flex items-center gap-1.5 text-sm" style={{ color: 'var(--muted)' }}>
        <ArrowLeft className="size-4" aria-hidden /> All bounties
      </Link>

      <section className="card space-y-5 p-5 sm:p-6">
        <div>
          <h1 className="display text-3xl font-bold text-balance">Post a bounty</h1>
          <p className="mt-1 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
            Your USDC is held in escrow. {aiMode ? 'An AI judge decides the winner.' : 'You pick the winner.'} If nobody is paid by
            the deadline, every backer can take their own share back (after a 7 day grace period if claims are waiting).
          </p>
        </div>

        <JudgeRetiredBanner compact />

        <div>
          <label htmlFor="title" className="label">
            Title
          </label>
          <input
            id="title"
            className="field mt-1.5"
            placeholder="Photo of a red phone booth in Lisbon"
            maxLength={LIMITS.title}
            value={title}
            disabled={flow.busy}
            onChange={(e) => setTitle(e.target.value)}
          />
        </div>

        <div>
          <label htmlFor="description" className="label">
            What counts as proof
          </label>
          <textarea
            id="description"
            className="field mt-1.5 min-h-28 resize-y"
            placeholder="Describe what hunters need to show, and any rules."
            value={description}
            disabled={flow.busy}
            onChange={(e) => setDescription(e.target.value)}
          />
        </div>

        <div>
          <span className="label">Who picks the winner</span>
          <div className="mt-1.5 grid gap-2 sm:grid-cols-2" role="radiogroup" aria-label="Who picks the winner">
            <button
              type="button"
              role="radio"
              aria-checked={!aiMode}
              className="chip h-auto justify-start gap-3 rounded-2xl p-3.5 text-left"
              data-active={!aiMode}
              disabled={flow.busy}
              onClick={() => setAiMode(false)}
            >
              <UserCheck className="size-5 shrink-0" aria-hidden />
              <span>
                <span className="block text-sm font-semibold">I pick the winner</span>
                <span className="chip-sub block text-xs font-normal">You review claims and accept one.</span>
              </span>
            </button>
            <button
              type="button"
              role="radio"
              aria-checked={aiMode}
              className="chip h-auto justify-start gap-3 rounded-2xl p-3.5 text-left"
              data-active={aiMode}
              disabled={flow.busy || limits.retired}
              onClick={() => {
                setAiMode(true)
                // On by default for AI bounties: it stops copycats. The poster can still turn it off.
                if (!aiChosen) setRequireHandle(true)
                setAiChosen(true)
              }}
            >
              <Bot className="size-5 shrink-0" aria-hidden />
              <span>
                <span className="block text-sm font-semibold">AI judge (two independent models must agree)</span>
                <span className="chip-sub block text-xs font-normal">Both models must approve each claim. You cannot accept.</span>
              </span>
            </button>
          </div>
        </div>

        {aiMode && (
          <div className="space-y-4">
            <JudgeIdentity />
            {limits.maxAIPot !== undefined && (
              <p className="inner p-3 text-sm" style={{ color: 'var(--ink-2)' }}>
                <span className="font-semibold">Max AI bounty: {fmtUsdc(limits.maxAIPot)} USDC.</span>{' '}
                <span style={{ color: 'var(--muted)' }}>
                  The contract refuses an AI-judged pot above this, which limits the loss if the judge ever misbehaves. Bounties where you pick the winner have no cap.
                </span>
              </p>
            )}

            <div>
              <label htmlFor="criteria" className="label">
                Acceptance criteria
              </label>
              <textarea
                id="criteria"
                className="field mt-1.5 min-h-28 resize-y"
                placeholder="A pull request merged into github.com/acme/app after this bounty was posted that fixes the login redirect bug and adds a test."
                value={criteria}
                maxLength={LIMITS.criteria}
                disabled={flow.busy}
                onChange={(e) => setCriteria(e.target.value)}
              />
              <div className="mt-1 flex justify-between text-xs" style={{ color: 'var(--subtle)' }}>
                <span>Stored onchain. The judge scores claims against exactly this text.</span>
                <span className="tabular-nums">{byteLength(criteria)}/{LIMITS.criteria}</span>
              </div>
              <ul className="mt-2 list-disc space-y-1 pl-5 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
                <li>Name the proof a hunter should link: a merged GitHub pull request, an X post, an Arc transaction, or a web page.</li>
                <li>State checkable facts: which repo and what it must change, who must post and what it must say, which contract and action.</li>
                <li>The work must be dated after this bounty is posted. Older work is rejected automatically.</li>
                <li>Avoid taste words like "great" or "creative". If a person could not verify it from the link, the judge cannot either.</li>
              </ul>
            </div>

            <label className="inner flex cursor-pointer items-start gap-3 p-3.5 text-sm">
              <input
                type="checkbox"
                className="mt-0.5 size-4 shrink-0"
                checked={requireHandle}
                disabled={flow.busy}
                onChange={(e) => setRequireHandle(e.target.checked)}
              />
              <span>
                <span className="block font-semibold">Hunter must link their X or GitHub handle</span>
                <span className="block text-xs" style={{ color: 'var(--muted)' }}>
                  Stops copycats: only a proof written by the handle the hunter links can win (GitHub pull requests and X posts).
                </span>
              </span>
            </label>
          </div>
        )}

        <div>
          <span className="label">Deadline</span>
          <div className="mt-1.5 flex flex-wrap gap-1.5" role="group" aria-label="Deadline">
            {DURATIONS.map((d) => (
              <button
                key={d.id}
                type="button"
                className="chip"
                data-active={duration === d.id}
                disabled={flow.busy}
                onClick={() => setDuration(d.id)}
              >
                {d.label}
              </button>
            ))}
          </div>
          {duration === 'custom' && (
            <input
              type="datetime-local"
              aria-label="Custom deadline"
              max={toDatetimeLocal(now + MAX_LEAD_SECONDS)}
              className="field mt-2"
              value={custom}
              disabled={flow.busy}
              onChange={(e) => setCustom(e.target.value)}
            />
          )}
          {expiry > now && (
            <p className="mt-2 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
              Claims and top-ups close {fmtDate(expiry)} (up to 90 days out). If claims are waiting then, you get{' '}
              {GRACE_PERIOD_SECONDS / 86_400} more days to pick a winner before refunds open.
            </p>
          )}
        </div>

        <AmountField
          id="amount"
          label="Your deposit"
          value={amount}
          onChange={setAmount}
          balance={balance}
          disabled={flow.busy}
        />

        {raw !== null && raw >= MIN_AMOUNT_RAW && (
          <dl className="inner space-y-2 p-3.5 text-sm">
            <div className="flex justify-between">
              <dt style={{ color: 'var(--muted)' }}>Goes into escrow</dt>
              <dd className="tabular-nums font-semibold">{fmtUsdc(raw)} USDC</dd>
            </div>
            <div className="flex justify-between">
              <dt style={{ color: 'var(--muted)' }}>Wallet steps</dt>
              <dd className="font-semibold">{needsAllowance ? '2 (allow, then deposit)' : '1 (deposit)'}</dd>
            </div>
            <div className="flex justify-between">
              <dt style={{ color: 'var(--muted)' }}>Network fees</dt>
              <dd className="font-semibold">Paid in USDC</dd>
            </div>
          </dl>
        )}

        <div>
          <GateButton
            label={needsAllowance ? 'Allow USDC and create bounty' : 'Create bounty'}
            busyLabel={flow.state.phase === 'wallet' ? 'Confirm in wallet…' : 'Confirming…'}
            busy={flow.busy}
            disabled={problem !== null}
            onClick={() => void submit()}
          />
          {problem && (
            <p className="mt-2 text-center text-xs" style={{ color: 'var(--subtle)' }}>
              {problem}
            </p>
          )}
          <TxStatus flow={flow.state} successText="Bounty created. Opening it now…" />
        </div>
      </section>
    </div>
  )
}
