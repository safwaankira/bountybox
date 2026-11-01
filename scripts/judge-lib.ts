import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { initiateDeveloperControlledWalletsClient } from '@circle-fin/developer-controlled-wallets'

/** Shared helpers for the judge setup scripts. Never prints secret values. */

export function requireEnv(...names: string[]): Record<string, string> {
  const out: Record<string, string> = {}
  const missing: string[] = []
  for (const name of names) {
    const value = process.env[name]?.trim()
    if (value) out[name] = value
    else missing.push(name)
  }
  if (missing.length > 0) {
    console.error(`Missing environment variables: ${missing.join(', ')}`)
    process.exit(2)
  }
  return out
}

export function circleClient() {
  const apiKey = process.env.CIRCLE_API_KEY?.trim()
  const entitySecret = (process.env.CIRCLE_ENTITY_SECRET ?? process.env.ENTITY_SECRET)?.trim()
  if (!apiKey || !entitySecret) {
    console.error('CIRCLE_API_KEY and CIRCLE_ENTITY_SECRET must be set in .env (see README, "Judge worker").')
    process.exit(2)
  }
  return initiateDeveloperControlledWalletsClient({ apiKey, entitySecret })
}

/** Appends KEY=value to .env unless the key already exists. Returns true if it wrote. */
export function appendEnv(key: string, value: string, file = '.env'): boolean {
  const current = existsSync(file) ? readFileSync(file, 'utf8') : ''
  if (new RegExp(`^${key}=`, 'm').test(current)) return false
  appendFileSync(file, `${current.endsWith('\n') || current === '' ? '' : '\n'}${key}=${value}\n`)
  return true
}
