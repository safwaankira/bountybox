import { timingSafeEqual } from 'node:crypto'
import { createDeps } from '../../judge/deps'
import { errorMessage } from '../../judge/log'
import { runJudgeTick } from '../../judge/run'
import { createNetlifyStore } from '../../judge/store'

function authorized(header: string | null): boolean {
  const secret = process.env.JUDGE_TRIGGER_SECRET
  if (!secret || !header) return false
  const expected = Buffer.from(`Bearer ${secret}`)
  const given = Buffer.from(header)
  return expected.length === given.length && timingSafeEqual(expected, given)
}

/** Background function (15 minute budget). Idempotent: safe to run twice or after a crash. */
export default async (req: Request): Promise<Response> => {
  if (req.method !== 'POST' || !authorized(req.headers.get('authorization'))) return new Response('forbidden', { status: 403 })
  try {
    const { deps } = createDeps(await createNetlifyStore())
    const summary = await runJudgeTick(deps)
    console.log(`[judge] run finished ${JSON.stringify(summary)}`)
  } catch (error) {
    console.log(`[judge] run failed: ${errorMessage(error)}`)
  }
  return new Response('done')
}
