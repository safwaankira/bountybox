import { GateButton } from '@/components/GateButton'
import { TxStatus } from '@/components/TxStatus'
import type { Bounty } from '@/bountybox/data'
import { fmtUsdc } from '@/bountybox/format'
import { useBountyActions } from '@/bountybox/actions'

export function RefundPanel({ bounty, myShare, fullyRefunded }: { bounty: Bounty; myShare: bigint; fullyRefunded: boolean }) {
  const { flow, refund } = useBountyActions()

  return (
    <section className="card space-y-3 p-5" style={{ borderColor: 'rgba(240,198,116,0.35)' }}>
      <div>
        <h2 className="display text-xl font-semibold">{fullyRefunded ? 'Fully refunded' : 'This bounty expired unpaid'}</h2>
        <p className="mt-0.5 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          {myShare > 0n
            ? 'Your share is yours to take back. Each backer withdraws their own.'
            : fullyRefunded
              ? 'Every share has been refunded.'
              : 'Each backer can take their own share back, in any order. No more claims or contributions are accepted.'}
        </p>
      </div>
      {myShare > 0n && (
        <GateButton
          label={`Take back ${fmtUsdc(myShare)} USDC`}
          busyLabel={flow.state.phase === 'wallet' ? 'Confirm in wallet…' : 'Confirming…'}
          busy={flow.busy}
          onClick={() => void refund(bounty.id)}
        />
      )}
      <TxStatus flow={flow.state} successText="Refund sent to your wallet." />
    </section>
  )
}
