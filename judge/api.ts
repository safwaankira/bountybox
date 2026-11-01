import type { Store } from './types'

/**
 * Read-only public API for verdicts and evidence. Shared by the Netlify function and the local dev server.
 *
 *   GET /verdicts/<chainId>/<bountyId>/index.json        status of every claim of a bounty
 *   GET /verdicts/<chainId>/<bountyId>/<claimId>/status.json  status of one claim (use this for paged lists)
 *   GET /verdicts/<chainId>/<bountyId>/<claimId>.json    the published verdict (exact bytes that were hashed)
 *   GET /evidence/<id>/snapshot.json                     the evidence snapshot
 *   GET /evidence/<id>/img/<n>                           a stored evidence image
 */

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, OPTIONS',
  'x-content-type-options': 'nosniff',
}

function json(body: string, cache: string, status = 200): Response {
  return new Response(body, { status, headers: { ...CORS, 'content-type': 'application/json; charset=utf-8', 'cache-control': cache } })
}

function notFound(): Response {
  return json(JSON.stringify({ error: 'not found' }), 'no-store', 404)
}

export async function handleApi(req: Request, store: Store): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS })
  if (req.method !== 'GET' && req.method !== 'HEAD') return json(JSON.stringify({ error: 'method not allowed' }), 'no-store', 405)

  const path = new URL(req.url).pathname

  const index = /^\/verdicts\/(\d{1,12})\/(\d{1,12})\/index\.json$/.exec(path)
  if (index) {
    const text = await store.getText(`status/${index[1]}/${index[2]}/index.json`)
    return text ? json(text, 'public, max-age=10') : notFound()
  }

  const one = /^\/verdicts\/(\d{1,12})\/(\d{1,12})\/(\d{1,6})\/status\.json$/.exec(path)
  if (one) {
    const text = await store.getText(`status/${one[1]}/${one[2]}/${one[3]}.json`)
    return text ? json(text, 'public, max-age=5') : notFound()
  }

  const verdict = /^\/verdicts\/(\d{1,12})\/(\d{1,12})\/(\d{1,6})\.json$/.exec(path)
  if (verdict) {
    const text = await store.getText(`verdicts/${verdict[1]}/${verdict[2]}/${verdict[3]}.json`)
    // Verdicts never change once written, so they can be cached hard.
    return text ? json(text, 'public, max-age=3600') : notFound()
  }

  const snapshot = /^\/evidence\/([a-f0-9]{24})\/snapshot\.json$/.exec(path)
  if (snapshot) {
    const text = await store.getText(`evidence/${snapshot[1]}/snapshot.json`)
    return text ? json(text, 'public, max-age=31536000, immutable') : notFound()
  }

  const image = /^\/evidence\/([a-f0-9]{24})\/img\/([0-2])$/.exec(path)
  if (image) {
    const blob = await store.getBytes(`evidence/${image[1]}/img/${image[2]}`)
    if (!blob || !/^image\/(png|jpeg|webp|gif)$/.test(blob.contentType)) return notFound()
    return new Response(blob.bytes as unknown as BodyInit, {
      headers: {
        ...CORS,
        'content-type': blob.contentType,
        'cache-control': 'public, max-age=31536000, immutable',
        'content-security-policy': "default-src 'none'; sandbox",
      },
    })
  }

  return notFound()
}
