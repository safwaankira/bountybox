/** A failure that may go away on its own (network, 5xx, rate limit). The claim is retried, never rejected for it. */
export class TransientError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'TransientError'
  }
}

/** Throws TransientError for statuses worth retrying; returns for everything else so the caller can reject on 4xx. */
export function assertNotTransient(status: number, what: string): void {
  if (status === 429 || status >= 500) throw new TransientError(`${what} returned HTTP ${status}`)
}

export async function guard<T>(what: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run()
  } catch (error) {
    if (error instanceof TransientError) throw error
    const name = error instanceof Error ? error.name : ''
    if (name === 'AbortError' || name === 'TimeoutError' || (error instanceof TypeError && /fetch|network|socket|ECONN|ENOTFOUND/i.test(error.message))) {
      throw new TransientError(`${what} failed: ${error instanceof Error ? error.message : 'network error'}`)
    }
    throw error
  }
}
