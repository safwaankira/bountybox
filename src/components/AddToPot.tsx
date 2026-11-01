import { useState } from 'react'
import { AmountField } from '@/components/AmountField'
import { GateButton } from '@/components/GateButton'
import { TxStatus } from '@/components/TxStatus'
import { MIN_AMOUNT_RAW } from '@/bountybox/abi'
import { useJudgeLimits, useUsdcAccount, type Bounty } from '@/bountybox/data'
import { fmtUsdc, tryParseUsdc } from '@/bountybox/format'
import { useBountyActions } from '@/bountybox/actions'

export function AddToPot({ bounty }: { bounty: Bounty }) {
  const { balance } = useUsdcAccount()
  const limits = useJudgeLimits()
  const cap = bounty.aiMode ? limits.maxAIPot : undefined
  const room = cap !== undefined ? (cap > bounty.pot ? cap - bounty.pot : 0n) : undefined
  const { flow, contribute, allowance } = useBountyActions()
  const [amount, setAmount] = useState('')
  const raw = tryParseUsdc(amount)

  const problem =
    bounty.aiMode && limits.retired
      ? 'The AI judge has been retired, so this bounty takes no new money'
      : raw === null
      ? 'Enter a USDC amount'
      : raw < MIN_AMOUNT_RAW
        ? 'Minimum is 0.01 USDC'
        : room !== undefined && raw > room
          ? `AI-judged pots are capped at ${fmtUsdc(cap ?? 0n)} USDC, so at most ${fmtUsdc(room)} USDC more fits`
          : balance !== undefined && raw > balance
            ? 'Not enough USDC in your wallet'
            : null

  const needsAllowance = raw !== null && (allowance ?? 0n) < raw

  const submit = async () => {
    if (problem || raw === null) return
    const receipt = await contribute(bounty.id, raw)
    if (receipt) setAmount('')
  }

  return (
    <section className="card space-y-4 p-5">
      <div>
        <h2 className="display text-xl font-semibold">Add to the pot</h2>
        <p className="mt-0.5 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          Back this bounty. Your share is tracked, and you can take it back if it expires unpaid.
        </p>
      </div>
      {cap !== undefined && (
        <p className="text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
          Max AI bounty: {fmtUsdc(cap)} USDC · room left {fmtUsdc(room ?? 0n)} USDC
        </p>
      )}
      <AmountField id="pot-amount" label="Amount" value={amount} onChange={setAmount} balance={balance} disabled={flow.busy} />
      {raw !== null && raw >= MIN_AMOUNT_RAW && (
        <p className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
          Pot becomes {fmtUsdc(bounty.pot + raw)} USDC
        </p>
      )}
      <GateButton
        label={needsAllowance ? 'Allow USDC and add to pot' : 'Add to pot'}
        busyLabel={flow.state.phase === 'wallet' ? 'Confirm in wallet…' : 'Confirming…'}
        busy={flow.busy}
        disabled={problem !== null}
        onClick={() => void submit()}
      />
      {problem && (raw !== null || (bounty.aiMode && limits.retired)) ? (
        <p className="text-center text-xs" style={{ color: 'var(--subtle)' }}>
          {problem}
        </p>
      ) : null}
      <TxStatus flow={flow.state} successText="Added to the pot." />
    </section>
  )
}
