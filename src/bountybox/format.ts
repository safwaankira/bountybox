import { Amount, parseUsdc } from '@/onchain-money'
import { USDC_DECIMALS } from '@/onchain-facts'

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

export function shortHash(hash: string): string {
  return hash.length > 18 ? `${hash.slice(0, 10)}…${hash.slice(-6)}` : hash
}

export function fmtUsdc(raw: bigint, digits = 2): string {
  const text = Amount.fromRaw(raw, USDC_DECIMALS).toFixed(digits)
  const [whole = '0', frac] = text.split('.')
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ',')
  return frac ? `${grouped}.${frac}` : grouped
}

/** Parse user input into 6-decimal base units; null when empty or malformed. */
export function tryParseUsdc(value: string): bigint | null {
  const trimmed = value.trim()
  if (!trimmed || !/^\d*\.?\d*$/.test(trimmed) || trimmed === '.') return null
  try {
    return parseUsdc(trimmed)
  } catch {
    return null
  }
}

export function sanitizeAmountInput(value: string): string | null {
  const cleaned = value.replace(/,/g, '')
  return /^\d*\.?\d{0,6}$/.test(cleaned) ? cleaned : null
}

export function timeLeft(expiry: number, now: number): { label: string; expired: boolean; urgent: boolean } {
  const diff = expiry - now
  if (diff <= 0) return { label: 'Expired', expired: true, urgent: false }
  const d = Math.floor(diff / 86400)
  const h = Math.floor((diff % 86400) / 3600)
  const m = Math.floor((diff % 3600) / 60)
  const s = diff % 60
  let label: string
  if (d > 0) label = `${d}d ${h}h left`
  else if (h > 0) label = `${h}h ${m}m left`
  else if (m > 0) label = `${m}m ${s}s left`
  else label = `${s}s left`
  return { label, expired: false, urgent: diff < 3600 }
}

export function fmtDate(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  })
}

export function safeHttpUrl(value: string): string | null {
  try {
    const url = new URL(value)
    return url.protocol === 'http:' || url.protocol === 'https:' ? url.toString() : null
  } catch {
    return null
  }
}

/** Value for a datetime-local input (local time, minute precision) at a unix timestamp. */
export function toDatetimeLocal(unixSeconds: number): string {
  const date = new Date(unixSeconds * 1000)
  return new Date(date.getTime() - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 16)
}
