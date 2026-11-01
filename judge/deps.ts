import { createChainReader } from './chain'
import { loadConfig, type JudgeConfig } from './config'
import { createScorers } from './llm'
import type { JudgeDeps } from './run'
import { createCircleSigner } from './signer'
import type { Store } from './types'

/** Builds the worker's dependencies from the environment. Secrets stay inside the objects that use them. */
export function createDeps(store: Store, env: Record<string, string | undefined> = process.env): { config: JudgeConfig; deps: JudgeDeps } {
  const config = loadConfig(env)
  const chain = createChainReader(config)
  return {
    config,
    deps: {
      config,
      store,
      chain,
      signer: config.circle ? createCircleSigner(config.circle, config.contract) : null,
      scorers: createScorers(config),
    },
  }
}
