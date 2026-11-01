import { Loader2 } from 'lucide-react'
import { ConnectKitButton } from 'connectkit'
import { useAccount, useSwitchChain } from 'wagmi'
import { CHAIN_ID, CHAIN_NAME } from '@/bountybox/config'

interface GateButtonProps {
  label: string
  busyLabel?: string
  busy?: boolean
  disabled?: boolean
  onClick: () => void
  variant?: 'primary' | 'ghost'
  className?: string
}

/** One CTA that walks through connect, switch network, then the real action. */
export function GateButton({
  label,
  busyLabel,
  busy = false,
  disabled = false,
  onClick,
  variant = 'primary',
  className = '',
}: GateButtonProps) {
  const { isConnected, chainId } = useAccount()
  const { switchChain, isPending } = useSwitchChain()
  const base = `btn ${variant === 'primary' ? 'btn-primary' : 'btn-ghost'} w-full ${className}`

  if (!isConnected) {
    return (
      <ConnectKitButton.Custom>
        {({ show }) => (
          <button type="button" className={base} onClick={show}>
            Connect wallet
          </button>
        )}
      </ConnectKitButton.Custom>
    )
  }

  if (chainId !== CHAIN_ID) {
    return (
      <button type="button" className={base} disabled={isPending} onClick={() => switchChain({ chainId: CHAIN_ID })}>
        {isPending ? <Loader2 className="size-4 animate-spin" /> : null}
        Switch to {CHAIN_NAME}
      </button>
    )
  }

  return (
    <button type="button" className={base} disabled={disabled || busy} onClick={onClick}>
      {busy ? <Loader2 className="size-4 animate-spin" aria-hidden /> : null}
      {busy ? (busyLabel ?? label) : label}
    </button>
  )
}
