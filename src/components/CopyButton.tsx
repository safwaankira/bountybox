import { useEffect, useRef, useState } from 'react'
import { Check, Copy } from 'lucide-react'
import { shortAddress } from '@/bountybox/format'

async function writeClipboard(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    // Fallback for browsers or iframes where the async clipboard API is blocked.
    const area = document.createElement('textarea')
    area.value = text
    area.setAttribute('readonly', '')
    area.style.position = 'fixed'
    area.style.opacity = '0'
    document.body.appendChild(area)
    area.select()
    const ok = document.execCommand('copy')
    document.body.removeChild(area)
    return ok
  }
}

/** Copies the full value (never the shortened text) and confirms for a moment. */
export function CopyButton({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false)
  const timer = useRef<number | undefined>(undefined)
  useEffect(() => () => window.clearTimeout(timer.current), [])

  return (
    <button
      type="button"
      className="relative z-10 inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-md pointer-events-auto transition-colors hover:bg-white/10 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-1"
      style={{ color: copied ? 'var(--success)' : 'var(--muted)', outlineColor: 'var(--accent)' }}
      aria-label={copied ? `${label} copied` : `Copy ${label}`}
      title={copied ? 'Copied' : `Copy ${label}`}
      onClick={(event) => {
        event.preventDefault()
        event.stopPropagation()
        void writeClipboard(value).then((ok) => {
          if (!ok) return
          setCopied(true)
          window.clearTimeout(timer.current)
          timer.current = window.setTimeout(() => setCopied(false), 1500)
        })
      }}
    >
      {copied ? <Check className="size-3.5" aria-hidden /> : <Copy className="size-3.5" aria-hidden />}
    </button>
  )
}

/** A truncated address with a copy button. Pass href to link the text to an explorer. */
export function AddressText({ address, href, label = 'address' }: { address: string; href?: string; label?: string }) {
  return (
    <span className="inline-flex items-center gap-0.5">
      {href ? (
        <a href={href} target="_blank" rel="noopener noreferrer" className="mono relative z-10 pointer-events-auto underline-offset-2 hover:underline" title={address}>
          {shortAddress(address)}
        </a>
      ) : (
        <span className="mono" title={address}>
          {shortAddress(address)}
        </span>
      )}
      <CopyButton value={address} label={label} />
    </span>
  )
}
