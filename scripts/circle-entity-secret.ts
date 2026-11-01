/**
 * One-time Circle setup: generates an entity secret, registers it with Circle, saves it to .env
 * and writes the recovery file OUTSIDE the repo (~/bountybox/circle-recovery). Never prints secrets.
 *   bun run scripts/circle-entity-secret.ts
 */
import { randomBytes } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { registerEntitySecretCiphertext } from '@circle-fin/developer-controlled-wallets'
import { appendEnv } from './judge-lib'

const apiKey = process.env.CIRCLE_API_KEY?.trim()
if (!apiKey) { console.error('CIRCLE_API_KEY is not in .env'); process.exit(2) }
if ((process.env.CIRCLE_ENTITY_SECRET ?? '').trim()) {
  console.log('CIRCLE_ENTITY_SECRET already set in .env; nothing to do.')
  process.exit(0)
}
const entitySecret = randomBytes(32).toString('hex')
const recoveryDir = join(homedir(), 'bountybox', 'circle-recovery')
mkdirSync(recoveryDir, { recursive: true })
await registerEntitySecretCiphertext({ apiKey, entitySecret, recoveryFileDownloadPath: recoveryDir })
appendEnv('CIRCLE_ENTITY_SECRET', entitySecret)
console.log('Entity secret registered with Circle and saved to .env (not shown).')
console.log(`Recovery file saved in ${recoveryDir} - back it up somewhere safe, then you can delete it from this Mac.`)
