import { Plus } from 'lucide-react'
import { ConnectKitButton } from 'connectkit'
import { useAccount } from 'wagmi'
import { Link } from '@/router'
import { CHAIN_NAME, IS_MAINNET } from '@/bountybox/config'
import { fmtUsdc, shortAddress } from '@/bountybox/format'
import { useUsdcAccount } from '@/bountybox/data'

function BoxMark() {
  return (
    <svg width="26" height="26" viewBox="0 0 26 26" fill="none" aria-hidden>
      <rect x="2" y="7" width="22" height="16" rx="4" stroke="currentColor" strokeWidth="2" />
      <path d="M2 12h22" stroke="currentColor" strokeWidth="2" />
      <rect x="10.5" y="10" width="5" height="4" rx="1.5" fill="currentColor" />
      <path d="M8 7V5.5A2.5 2.5 0 0 1 10.5 3h5A2.5 2.5 0 0 1 18 5.5V7" stroke="currentColor" strokeWidth="2" />
    </svg>
  )
}

export function Header() {
  const { isConnected } = useAccount()
  const { balance } = useUsdcAccount()

  return (
    <header className="sticky top-0 z-30 border-b" style={{ borderColor: 'var(--border)', background: 'rgba(13,27,47,0.8)', backdropFilter: 'blur(16px)' }}>
      <div className="mx-auto flex h-16 max-w-3xl items-center justify-between gap-3 px-4">
        <Link to="/" className="flex items-center gap-2" style={{ color: 'var(--accent)' }}>
          <BoxMark />
          <span className="display text-lg font-bold" style={{ color: 'var(--ink)' }}>
            BountyBox
          </span>
        </Link>
        <div className="flex items-center gap-2">
          <span
            className="tag"
            style={IS_MAINNET ? { color: 'var(--warn)', borderColor: 'rgba(240,198,116,0.45)' } : undefined}
            title={IS_MAINNET ? 'Real USDC. Transactions are irreversible.' : undefined}
          >
            {IS_MAINNET ? `${CHAIN_NAME} · real USDC` : CHAIN_NAME}
          </span>
          <Link to="/new" className="btn btn-ghost !min-h-10 !px-3" aria-label="Create bounty">
            <Plus className="size-4" aria-hidden />
            <span className="hidden sm:inline">New bounty</span>
          </Link>
          <ConnectKitButton.Custom>
            {({ isConnected: connected, show, address }) => (
              <button type="button" onClick={show} className="btn btn-primary !min-h-10 !px-3.5 tabular-nums">
                {connected && address ? (
                  <span className="flex flex-col items-end leading-tight sm:flex-row sm:items-center sm:gap-2">
                    {isConnected && balance !== undefined ? (
                      <span className="text-xs font-bold">{fmtUsdc(balance)} USDC</span>
                    ) : null}
                    <span className="mono text-[11px] font-medium">{shortAddress(address)}</span>
                  </span>
                ) : (
                  'Connect'
                )}
              </button>
            )}
          </ConnectKitButton.Custom>
        </div>
      </div>
    </header>
  )
}
