import { AlertCircle, CheckCircle2, ExternalLink, Loader2 } from 'lucide-react'
import { buildTxExplorerUrl } from '@/onchain-facts'
import { CHAIN_ID } from '@/bountybox/config'
import { shortHash } from '@/bountybox/format'
import type { TxRecord } from '@/bountybox/tx'
import { CopyButton } from '@/components/CopyButton'

interface FlowView {
  phase: 'idle' | 'wallet' | 'confirming' | 'success' | 'error'
  label: string
  hashes: TxRecord[]
  error?: string
}

export function TxLink({ hash, label }: { hash: string; label: string }) {
  return (
    <a
      href={buildTxExplorerUrl(CHAIN_ID, hash)}
      target="_blank"
      rel="noopener noreferrer"
      className="inline-flex items-center gap-1 text-xs font-medium underline-offset-2 hover:underline"
      style={{ color: 'var(--accent)' }}
    >
      {label}
      <ExternalLink className="size-3" aria-hidden />
    </a>
  )
}

/** Renders real wallet and confirmation state, with an explorer link for every transaction sent. */
export function TxStatus({ flow, successText }: { flow: FlowView; successText: string }) {
  if (flow.phase === 'idle' && flow.hashes.length === 0) return null

  return (
    <div className="inner mt-3 space-y-2 p-3 text-sm" role="status" aria-live="polite">
      {flow.phase === 'wallet' && (
        <p className="flex items-center gap-2" style={{ color: 'var(--ink-2)' }}>
          <Loader2 className="size-4 animate-spin" aria-hidden /> Confirm “{flow.label}” in your wallet…
        </p>
      )}
      {flow.phase === 'confirming' && (
        <p className="flex items-center gap-2" style={{ color: 'var(--ink-2)' }}>
          <Loader2 className="size-4 animate-spin" aria-hidden /> Confirming “{flow.label}” onchain…
        </p>
      )}
      {flow.phase === 'success' && (
        <p className="flex items-center gap-2 font-medium" style={{ color: 'var(--success)' }}>
          <CheckCircle2 className="size-4" aria-hidden /> {successText}
        </p>
      )}
      {flow.phase === 'error' && (
        <p className="flex items-start gap-2" style={{ color: 'var(--danger)' }}>
          <AlertCircle className="mt-0.5 size-4 shrink-0" aria-hidden /> <span>{flow.error}</span>
        </p>
      )}
      {flow.hashes.length > 0 && (
        <ul className="flex flex-wrap gap-x-4 gap-y-1">
          {flow.hashes.map((tx) => (
            <li key={tx.hash} className="inline-flex items-center gap-1">
              <TxLink hash={tx.hash} label={`${tx.label} on explorer`} />
              <span className="mono text-xs" style={{ color: 'var(--muted)' }} title={tx.hash}>
                {shortHash(tx.hash)}
              </span>
              <CopyButton value={tx.hash} label="transaction hash" />
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
