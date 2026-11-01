import { TransientError, assertNotTransient, guard } from './errors'

export interface XPost {
  id: string
  text: string
  authorUsername: string
  authorName: string
  /** ISO timestamp, or null when the source cannot supply it. */
  createdAt: string | null
  mediaURLs: string[]
  source: 'x-api' | 'syndication' | 'oembed'
}

/** Pluggable post fetcher. Returns null when the post does not exist (a permanent answer). */
export interface XFetcher {
  name: string
  fetchPost(id: string, urlUsername: string): Promise<XPost | null>
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}
function obj(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
}

/** Official API. Used when X_BEARER_TOKEN is set. */
export function createXApiFetcher(bearer: string): XFetcher {
  return {
    name: 'x-api',
    async fetchPost(id) {
      return guard('X API', async () => {
        const params = new URLSearchParams({
          'tweet.fields': 'created_at,author_id,text,attachments',
          expansions: 'author_id,attachments.media_keys',
          'user.fields': 'username,name',
          'media.fields': 'url,type',
        })
        const res = await fetch(`https://api.x.com/2/tweets/${id}?${params}`, {
          headers: { authorization: `Bearer ${bearer}`, 'user-agent': 'BountyBoxJudge/1.0' },
          signal: AbortSignal.timeout(10_000),
        })
        assertNotTransient(res.status, 'X API')
        if (res.status === 401 || res.status === 403) throw new Error(`X API rejected the token (HTTP ${res.status})`)
        if (!res.ok) return null
        const body = obj(await res.json())
        const tweet = obj(body.data)
        if (!str(tweet.id)) return null
        const includes = obj(body.includes)
        const users = Array.isArray(includes.users) ? includes.users : []
        const user = obj(users.find((u) => obj(u).id === tweet.author_id))
        const media = Array.isArray(includes.media) ? includes.media : []
        return {
          id,
          text: str(tweet.text),
          authorUsername: str(user.username),
          authorName: str(user.name),
          createdAt: str(tweet.created_at) || null,
          mediaURLs: media.map((m) => str(obj(m).url)).filter(Boolean),
          source: 'x-api',
        }
      })
    },
  }
}

/** Public fallback: the embed endpoint X serves to websites. No key, best effort. */
export const syndicationFetcher: XFetcher = {
  name: 'syndication',
  async fetchPost(id) {
    return guard('X syndication', async () => {
      const token = ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
      const res = await fetch(`https://cdn.syndication.twimg.com/tweet-result?id=${id}&lang=en&token=${token}`, {
        headers: { 'user-agent': 'Mozilla/5.0 (compatible; BountyBoxJudge/1.0)' },
        signal: AbortSignal.timeout(10_000),
      })
      assertNotTransient(res.status, 'X syndication')
      if (res.status === 404) return null
      if (!res.ok) throw new Error(`X syndication returned HTTP ${res.status}`)
      const text = await res.text()
      if (!text.trim()) return null
      const tweet = obj(JSON.parse(text))
      const user = obj(tweet.user)
      if (!str(user.screen_name)) return null
      const photos = Array.isArray(tweet.photos) ? tweet.photos : []
      return {
        id,
        text: str(tweet.text),
        authorUsername: str(user.screen_name),
        authorName: str(user.name),
        createdAt: str(tweet.created_at) || null,
        mediaURLs: photos.map((p) => str(obj(p).url)).filter(Boolean),
        source: 'syndication',
      }
    })
  },
}

/** Last resort: oEmbed. Gives text and author but only a calendar date, no time. */
export const oembedFetcher: XFetcher = {
  name: 'oembed',
  async fetchPost(id, urlUsername) {
    return guard('X oEmbed', async () => {
      const target = `https://x.com/${urlUsername}/status/${id}`
      const res = await fetch(`https://publish.twitter.com/oembed?omit_script=true&url=${encodeURIComponent(target)}`, {
        headers: { 'user-agent': 'Mozilla/5.0 (compatible; BountyBoxJudge/1.0)' },
        signal: AbortSignal.timeout(10_000),
      })
      assertNotTransient(res.status, 'X oEmbed')
      if (!res.ok) return null
      const body = obj(await res.json())
      const html = str(body.html)
      const authorURL = str(body.author_url)
      const paragraph = /<p[^>]*>([\s\S]*?)<\/p>/.exec(html)?.[1] ?? ''
      const text = paragraph.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").trim()
      const dateText = />([A-Za-z]+ \d{1,2}, \d{4})<\/a>\s*<\/blockquote>/.exec(html)?.[1]
      const parsed = dateText ? Date.parse(`${dateText} 00:00:00 UTC`) : Number.NaN
      return {
        id,
        text,
        authorUsername: authorURL.split('/').filter(Boolean).pop() ?? '',
        authorName: str(body.author_name),
        createdAt: Number.isNaN(parsed) ? null : new Date(parsed).toISOString(),
        mediaURLs: [],
        source: 'oembed',
      }
    })
  },
}

export function defaultXFetchers(bearer: string | null): XFetcher[] {
  return [...(bearer ? [createXApiFetcher(bearer)] : []), syndicationFetcher, oembedFetcher]
}

/**
 * Tries each fetcher in order; the first post wins. Returns post null only when at least one source said the
 * post does not exist. If every source failed outright the answer is unknown, so this throws TransientError.
 */
export async function fetchXPost(fetchers: XFetcher[], id: string, username: string): Promise<{ post: XPost | null; notes: string[] }> {
  const notes: string[] = []
  let definiteMissing = false
  for (const fetcher of fetchers) {
    try {
      const post = await fetcher.fetchPost(id, username)
      if (post) return { post, notes }
      definiteMissing = true
      notes.push(`${fetcher.name}: post not found`)
      if (fetcher.name === 'x-api') break
    } catch (error) {
      notes.push(`${fetcher.name}: ${error instanceof Error ? error.message : 'failed'}`)
    }
  }
  if (!definiteMissing) throw new TransientError(`Could not read the post from any source (${notes.join('; ')})`)
  return { post: null, notes }
}
