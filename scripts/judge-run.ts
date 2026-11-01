/**
 * Runs one judge pass locally against the filesystem store (./.judge-data), using the same code as the
 * Netlify background function. Reads configuration from the environment (Bun loads .env).
 *   bun run judge:once
 */
import { createDeps } from '../judge/deps'
import { missingForProduction } from '../judge/config'
import { errorMessage, log } from '../judge/log'
import { runJudgeTick } from '../judge/run'
import { FsStore } from '../judge/store'

try {
  const { config, deps } = createDeps(new FsStore('.judge-data'))
  const missing = missingForProduction(config)
  if (missing.length > 0) {
    log(`missing configuration: ${missing.join('; ')}`)
    process.exit(2)
  }
  const summary = await runJudgeTick(deps)
  log('summary', summary)
} catch (error) {
  log(`failed: ${errorMessage(error)}`)
  process.exit(1)
}
