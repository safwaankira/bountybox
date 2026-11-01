import { lookup } from 'node:dns/promises'
import { isIP } from 'node:net'

/**
 * Fetch for URLs that hunters control. Blocks private, loopback and link-local targets (including via
 * DNS and redirects), caps size and time, and never sends credentials.
 */

export class UnsafeUrlError extends Error {}

const MAX_REDIRECTS = 3

function ipv4ToInt(ip: string): number {
  return ip.split('.').reduce((acc, part) => acc * 256 + Number(part), 0)
}

function inRange(ip: number, base: string, bits: number): boolean {
  const size = 2 ** (32 - bits)
  const start = ipv4ToInt(base)
  return ip >= start && ip < start + size
}

const BLOCKED_V4: Array<[string, number]> = [
  ['0.0.0.0', 8],
  ['10.0.0.0', 8],
  ['100.64.0.0', 10],
  ['127.0.0.0', 8],
  ['169.254.0.0', 16],
  ['172.16.0.0', 12],
  ['192.0.0.0', 24],
  ['192.168.0.0', 16],
  ['198.18.0.0', 15],
  ['224.0.0.0', 3],
]

export function isBlockedIp(ip: string): boolean {
  if (isIP(ip) === 4) {
    const n = ipv4ToInt(ip)
    return BLOCKED_V4.some(([base, bits]) => inRange(n, base, bits))
  }
  const lower = ip.toLowerCase()
  if (lower === '::1' || lower === '::') return true
  if (lower.startsWith('fe80') || lower.startsWith('fc') || lower.startsWith('fd')) return true
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(lower)
  if (mapped?.[1]) return isBlockedIp(mapped[1])
  return false
}

export async function assertPublicUrl(raw: string): Promise<URL> {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new UnsafeUrlError('Not a valid URL')
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new UnsafeUrlError('Only http(s) URLs are allowed')
  if (url.username || url.password) throw new UnsafeUrlError('Credentials in URLs are not allowed')
  const host = url.hostname.replace(/^\[|\]$/g, '')
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.internal') || host.endsWith('.local')) {
    throw new UnsafeUrlError('Local hostnames are not allowed')
  }
  if (isIP(host)) {
    if (isBlockedIp(host)) throw new UnsafeUrlError('Private addresses are not allowed')
    return url
  }
  const records = await lookup(host, { all: true })
  if (records.length === 0) throw new UnsafeUrlError('Hostname did not resolve')
  for (const record of records) {
    if (isBlockedIp(record.address)) throw new UnsafeUrlError('Hostname resolves to a private address')
  }
  return url
}

export interface SafeFetchOptions {
  timeoutMs?: number
  maxBytes?: number
  accept?: string
}

export interface SafeFetchResult {
  finalURL: string
  status: number
  contentType: string
  bytes: Uint8Array
  truncated: boolean
}

async function readCapped(res: Response, maxBytes: number): Promise<{ bytes: Uint8Array; truncated: boolean }> {
  if (!res.body) return { bytes: new Uint8Array(), truncated: false }
  const reader = res.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  let truncated = false
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maxBytes) {
      const keep = value.byteLength - (total - maxBytes)
      if (keep > 0) chunks.push(value.subarray(0, keep))
      truncated = true
      await reader.cancel()
      break
    }
    chunks.push(value)
  }
  const bytes = new Uint8Array(Math.min(total, maxBytes))
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return { bytes, truncated }
}

export async function safeFetch(rawUrl: string, options: SafeFetchOptions = {}): Promise<SafeFetchResult> {
  const timeoutMs = options.timeoutMs ?? 10_000
  const maxBytes = options.maxBytes ?? 2_000_000
  let current = rawUrl
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const url = await assertPublicUrl(current)
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    try {
      const res = await fetch(url, {
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          'user-agent': 'BountyBoxJudge/1.0 (+evidence snapshot)',
          accept: options.accept ?? 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5',
        },
      })
      if (res.status >= 300 && res.status < 400 && res.headers.get('location')) {
        current = new URL(res.headers.get('location') ?? '', url).toString()
        continue
      }
      const { bytes, truncated } = await readCapped(res, maxBytes)
      return {
        finalURL: url.toString(),
        status: res.status,
        contentType: (res.headers.get('content-type') ?? '').split(';')[0]?.trim().toLowerCase() ?? '',
        bytes,
        truncated,
      }
    } finally {
      clearTimeout(timer)
    }
  }
  throw new UnsafeUrlError('Too many redirects')
}
