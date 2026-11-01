import type { Config } from '@netlify/functions'

/**
 * Runs every 5 minutes. Scheduled functions are short-lived, so this only wakes the background worker,
 * which has the time budget to fetch evidence, call both models and send the onchain transaction.
 */
export default async (): Promise<void> => {
  const base = process.env.URL ?? process.env.JUDGE_PUBLIC_BASE_URL
  const secret = process.env.JUDGE_TRIGGER_SECRET
  if (!base || !secret) {
    console.log('[judge] tick skipped: URL or JUDGE_TRIGGER_SECRET is not set')
    return
  }
  const res = await fetch(`${base.replace(/\/+$/, '')}/.netlify/functions/judge-run-background`, {
    method: 'POST',
    headers: { authorization: `Bearer ${secret}` },
  })
  console.log(`[judge] tick triggered the worker (HTTP ${res.status})`)
}

export const config: Config = { schedule: '*/5 * * * *' }
