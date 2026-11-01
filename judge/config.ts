import { isAddress, type Address, type Chain } from 'viem'
import { arc, arcTestnet } from 'viem/chains'

/**
 * Worker configuration, read from environment variables only. Nothing here is logged.
 * VITE_BOUNTYBOX_NETWORK / VITE_BOUNTYBOX_ADDRESS are shared with the frontend so the two can never diverge.
 */

export interface JudgeConfig {
  network: 'arc-testnet' | 'arc-mainnet'
  chain: Chain
  contract: Address
  rpcUrls: string[]
  /** Public origin that serves /verdicts and /evidence. These links are written onchain and into verdicts. */
  baseURL: string
  /** True when baseURL is a local fallback. Approved verdicts are never published or sent onchain in that case. */
  baseIsLocal: boolean
  openai: { apiKey: string; model: string; baseURL: string; label: string; vision: boolean } | null
  gemini: { apiKey: string; model: string } | null
  githubToken: string | null
  xBearerToken: string | null
  circle: { apiKey: string; entitySecret: string; walletId: string } | null
  maxClaimsPerTick: number
  /** Stop starting new work after this many ms (background functions last 15 minutes). */
  tickBudgetMs: number
}

type Env = Record<string, string | undefined>

function clean(value: string | undefined): string | null {
  const v = value?.trim()
  return v ? v : null
}

/** localhost, loopback, private and link-local hosts are never valid in a link that goes onchain. */
export function isLocalOrigin(url: string): boolean {
  let host: string
  try {
    host = new URL(url).hostname.toLowerCase().replace(/^\[|\]$/g, '')
  } catch {
    return true
  }
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) return true
  if (host === '::1' || host === '::' || host.startsWith('fe80:') || host.startsWith('fc') || host.startsWith('fd')) return true
  const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(host)
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])]
    return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
  }
  return false
}

/** Netlify sets NETLIFY and CONTEXT in builds and functions; NODE_ENV=production covers other hosts. */
export function isProductionEnv(env: Record<string, string | undefined>): boolean {
  return env.NETLIFY === 'true' || Boolean(clean(env.CONTEXT)) || env.NODE_ENV === 'production'
}

export function loadConfig(env: Env = process.env): JudgeConfig {
  const networkKey = clean(env.VITE_BOUNTYBOX_NETWORK) ?? 'arc-testnet'
  if (networkKey !== 'arc-testnet' && networkKey !== 'arc-mainnet') {
    throw new Error(`Unsupported VITE_BOUNTYBOX_NETWORK "${networkKey}"`)
  }
  if (networkKey === 'arc-mainnet' && env.JUDGE_ALLOW_MAINNET !== 'true') {
    throw new Error('The judge is testnet-only unless JUDGE_ALLOW_MAINNET=true is set deliberately.')
  }
  const chain: Chain = networkKey === 'arc-mainnet' ? arc : arcTestnet

  const contract = clean(env.VITE_BOUNTYBOX_ADDRESS)
  if (!contract || !isAddress(contract)) throw new Error('VITE_BOUNTYBOX_ADDRESS is missing or invalid')

  const rpcOverride = clean(env.JUDGE_RPC_URL)
  const rpcUrls = rpcOverride ? [rpcOverride, ...chain.rpcUrls.default.http] : [...chain.rpcUrls.default.http]

  // The public origin is baked into the verdict URI that is written onchain, so it must be the real site.
  const explicitBase = clean(env.JUDGE_PUBLIC_BASE_URL) ?? clean(env.URL)
  if (isProductionEnv(env)) {
    if (!explicitBase) {
      throw new Error(
        'JUDGE_PUBLIC_BASE_URL is not set and Netlify did not provide URL. Verdict and evidence links are written onchain, so the judge refuses to run without the public site origin (for example https://your-site.netlify.app).',
      )
    }
    if (isLocalOrigin(explicitBase)) {
      throw new Error(`JUDGE_PUBLIC_BASE_URL (${explicitBase}) is a local address. Set it to the public site origin before running in production.`)
    }
  }
  const baseURL = (explicitBase ?? 'http://localhost:3001').replace(/\/+$/, '')
  const baseIsLocal = isLocalOrigin(baseURL)

  const groqKey = clean(env.GROQ_API_KEY)
  const openaiKey = clean(env.OPENAI_API_KEY) ?? groqKey
  const geminiKey = clean(env.GEMINI_API_KEY) ?? clean(env.GOOGLE_API_KEY)
  const circleKey = clean(env.CIRCLE_API_KEY)
  const entitySecret = clean(env.CIRCLE_ENTITY_SECRET) ?? clean(env.ENTITY_SECRET)
  const walletId = clean(env.JUDGE_WALLET_ID)

  return {
    network: networkKey,
    chain,
    contract,
    rpcUrls,
    baseURL,
    baseIsLocal,
    openai: openaiKey
      ? groqKey && !clean(env.OPENAI_API_KEY)
        ? // Free route: Groq's OpenAI-compatible API (free tier). gpt-oss-120b is text-only; Gemini sees the images.
          { apiKey: openaiKey, model: clean(env.OPENAI_MODEL) ?? 'openai/gpt-oss-120b', baseURL: 'https://api.groq.com/openai/v1', label: 'groq', vision: env.OPENAI_VISION === 'true' }
        : { apiKey: openaiKey, model: clean(env.OPENAI_MODEL) ?? 'gpt-5-mini', baseURL: (clean(env.OPENAI_BASE_URL) ?? 'https://api.openai.com/v1').replace(/\/+$/, ''), label: 'openai', vision: env.OPENAI_VISION !== 'false' }
      : null,
    gemini: geminiKey ? { apiKey: geminiKey, model: clean(env.GEMINI_MODEL) ?? 'gemini-2.5-flash' } : null,
    githubToken: clean(env.GITHUB_TOKEN),
    xBearerToken: clean(env.X_BEARER_TOKEN),
    circle: circleKey && entitySecret && walletId ? { apiKey: circleKey, entitySecret, walletId } : null,
    maxClaimsPerTick: Number(clean(env.JUDGE_MAX_CLAIMS_PER_TICK) ?? '6'),
    tickBudgetMs: Number(clean(env.JUDGE_TICK_BUDGET_MS) ?? String(12 * 60_000)),
  }
}

/** Names of the variables the worker needs, for friendly startup errors. */
export function missingForProduction(config: JudgeConfig): string[] {
  const missing: string[] = []
  if (!config.openai) missing.push('GROQ_API_KEY (free) or OPENAI_API_KEY')
  if (!config.gemini) missing.push('GEMINI_API_KEY')
  if (!config.circle) missing.push('CIRCLE_API_KEY, CIRCLE_ENTITY_SECRET, JUDGE_WALLET_ID')
  return missing
}
