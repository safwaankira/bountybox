/**
 * Logging that cannot leak secrets: every configured secret value is replaced before anything is printed.
 * Log identifiers and states, never request bodies, headers or env values.
 */

const SECRET_ENV_KEYS = [
  'CIRCLE_API_KEY',
  'CIRCLE_ENTITY_SECRET',
  'OPENAI_API_KEY',
  'GEMINI_API_KEY',
  'GITHUB_TOKEN',
  'X_BEARER_TOKEN',
  'JUDGE_TRIGGER_SECRET',
] as const

function secretValues(): string[] {
  return SECRET_ENV_KEYS.map((key) => process.env[key]).filter((v): v is string => typeof v === 'string' && v.length >= 6)
}

export function redact(text: string): string {
  let out = text
  for (const secret of secretValues()) out = out.split(secret).join('[redacted]')
  return out
}

function format(args: unknown[]): string {
  return redact(
    args
      .map((arg) => {
        if (typeof arg === 'string') return arg
        if (arg instanceof Error) return `${arg.name}: ${arg.message}`
        try {
          return JSON.stringify(arg)
        } catch {
          return String(arg)
        }
      })
      .join(' '),
  )
}

export type Logger = (...args: unknown[]) => void

export const log: Logger = (...args) => {
  console.log(`[judge] ${format(args)}`)
}

export function errorMessage(error: unknown): string {
  return redact(error instanceof Error ? error.message : String(error))
}
