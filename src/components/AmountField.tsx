import { TokenUSDC } from '@web3icons/react'
import { GAS_RESERVE_RAW } from '@/bountybox/config'
import { fmtUsdc, sanitizeAmountInput } from '@/bountybox/format'
import { formatUsdc } from '@/onchain-money'

interface AmountFieldProps {
  id: string
  label: string
  value: string
  onChange: (value: string) => void
  balance?: bigint
  disabled?: boolean
}

const QUICK = ['1', '5', '10', '25']

export function AmountField({ id, label, value, onChange, balance, disabled }: AmountFieldProps) {
  const maxRaw = balance !== undefined && balance > GAS_RESERVE_RAW ? balance - GAS_RESERVE_RAW : 0n

  return (
    <div>
      <label htmlFor={id} className="label">
        {label}
      </label>
      <div className="inner mt-1.5 p-3.5">
        <div className="flex items-center gap-2">
          <input
            id={id}
            inputMode="decimal"
            autoComplete="off"
            placeholder="0.00"
            value={value}
            disabled={disabled}
            onChange={(e) => {
              const next = sanitizeAmountInput(e.target.value)
              if (next !== null) onChange(next)
            }}
            className="display w-full min-w-0 bg-transparent text-3xl font-bold tabular-nums outline-none placeholder:text-slate-500"
            style={{ color: 'var(--ink)' }}
          />
          <span className="flex shrink-0 items-center gap-1.5 text-sm font-semibold" style={{ color: 'var(--muted)' }}>
            <TokenUSDC variant="branded" size={20} /> USDC
          </span>
        </div>
        <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
          <div className="flex gap-1.5">
            {QUICK.map((q) => (
              <button key={q} type="button" className="chip" disabled={disabled} onClick={() => onChange(q)}>
                {q}
              </button>
            ))}
          </div>
          {balance !== undefined ? (
            <button
              type="button"
              disabled={disabled || maxRaw === 0n}
              onClick={() => onChange(formatUsdc(maxRaw))}
              className="text-xs font-semibold tabular-nums disabled:opacity-40"
              style={{ color: 'var(--accent)' }}
              title="Keeps a little USDC back for network fees"
            >
              Balance {fmtUsdc(balance)} · Max
            </button>
          ) : null}
        </div>
      </div>
    </div>
  )
}
