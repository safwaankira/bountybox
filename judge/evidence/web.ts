import { createHash } from 'node:crypto'
import { safeFetch, UnsafeUrlError } from '../safeFetch'
import { TransientError, assertNotTransient, guard } from './errors'

export interface WebFacts {
  finalURL: string
  status: number
  title: string
  description: string
  text: string
  imageURLs: string[]
}

const TEXT_LIMIT = 20_000
const IMAGE_TYPES = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
const MAX_IMAGES = 3

function decodeEntities(s: string): string {
  return s
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Math.min(Number(code), 0x10ffff)))
}

function meta(html: string, key: string): string {
  const patterns = [
    new RegExp(`<meta[^>]+(?:property|name)=["']${key}["'][^>]*content=["']([^"']*)["']`, 'i'),
    new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']${key}["']`, 'i'),
  ]
  for (const pattern of patterns) {
    const found = pattern.exec(html)?.[1]
    if (found) return decodeEntities(found).trim()
  }
  return ''
}

export function extractText(html: string): string {
  return decodeEntities(
    html
      .replace(/<(script|style|noscript|svg|template)[\s\S]*?<\/\1>/gi, ' ')
      .replace(/<!--[\s\S]*?-->/g, ' ')
      .replace(/<\/(p|div|li|h[1-6]|tr|br|section|article)>/gi, '\n')
      .replace(/<[^>]+>/g, ' '),
  )
    .replace(/[ \t\f\v]+/g, ' ')
    .replace(/\s*\n\s*/g, '\n')
    .trim()
    .slice(0, TEXT_LIMIT)
}

function collectImages(html: string, base: string): string[] {
  const found = [meta(html, 'og:image'), meta(html, 'twitter:image')]
  for (const match of html.matchAll(/<img[^>]+src=["']([^"']+)["']/gi)) found.push(match[1] ?? '')
  const urls: string[] = []
  for (const candidate of found) {
    if (!candidate || candidate.startsWith('data:')) continue
    try {
      const abs = new URL(decodeEntities(candidate), base).toString()
      if (!urls.includes(abs)) urls.push(abs)
    } catch {
      // ignore malformed image URLs
    }
    if (urls.length >= 6) break
  }
  return urls
}

/** Fetches a page the hunter linked. 4xx is a permanent answer (reported as not reachable), 5xx/network is transient. */
export async function fetchWeb(url: string): Promise<WebFacts | { unreachable: string }> {
  return guard('Page fetch', async () => {
    let res
    try {
      res = await safeFetch(url, { maxBytes: 1_500_000, timeoutMs: 10_000 })
    } catch (error) {
      if (error instanceof UnsafeUrlError) return { unreachable: error.message }
      throw error
    }
    assertNotTransient(res.status, 'The page')
    if (res.status >= 400) return { unreachable: `The page returned HTTP ${res.status}` }
    const decoded = new TextDecoder('utf-8', { fatal: false }).decode(res.bytes)
    const isHtml = res.contentType.includes('html') || /<html|<body|<!doctype/i.test(decoded.slice(0, 500))
    if (!isHtml && !res.contentType.startsWith('text/') && res.contentType !== 'application/json') {
      return { finalURL: res.finalURL, status: res.status, title: '', description: `Non-text content (${res.contentType || 'unknown type'})`, text: '', imageURLs: IMAGE_TYPES.has(res.contentType) ? [res.finalURL] : [] }
    }
    if (!isHtml) {
      return { finalURL: res.finalURL, status: res.status, title: '', description: '', text: decoded.slice(0, TEXT_LIMIT), imageURLs: [] }
    }
    const title = decodeEntities(/<title[^>]*>([\s\S]*?)<\/title>/i.exec(decoded)?.[1] ?? '').trim()
    return {
      finalURL: res.finalURL,
      status: res.status,
      title: title.slice(0, 300) || meta(decoded, 'og:title').slice(0, 300),
      description: (meta(decoded, 'og:description') || meta(decoded, 'description')).slice(0, 600),
      text: extractText(decoded),
      imageURLs: collectImages(decoded, res.finalURL),
    }
  })
}

export interface DownloadedImage {
  url: string
  bytes: Uint8Array
  contentType: string
  sha256: string
}

/** Downloads up to three images (png, jpeg, webp, gif, 3 MB each). Failures are skipped, never fatal. */
export async function downloadImages(urls: string[]): Promise<{ images: DownloadedImage[]; notes: string[] }> {
  const images: DownloadedImage[] = []
  const notes: string[] = []
  for (const url of urls) {
    if (images.length >= MAX_IMAGES) break
    try {
      const res = await safeFetch(url, { maxBytes: 3_000_000, timeoutMs: 8_000, accept: 'image/png,image/jpeg,image/webp,image/gif' })
      if (res.status !== 200) {
        notes.push(`image ${url}: HTTP ${res.status}`)
        continue
      }
      if (!IMAGE_TYPES.has(res.contentType) || res.truncated) {
        notes.push(`image ${url}: skipped (${res.truncated ? 'too large' : res.contentType || 'unknown type'})`)
        continue
      }
      images.push({ url: res.finalURL, bytes: res.bytes, contentType: res.contentType, sha256: createHash('sha256').update(res.bytes).digest('hex') })
    } catch (error) {
      if (error instanceof TransientError) notes.push(`image ${url}: ${error.message}`)
      else notes.push(`image ${url}: ${error instanceof Error ? error.message : 'failed'}`)
    }
  }
  return { images, notes }
}
