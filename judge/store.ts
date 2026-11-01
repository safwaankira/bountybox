import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join, normalize } from 'node:path'
import type { Store } from './types'

/** Keys are slash-separated and restricted so a key can never escape the store. */
const SAFE_KEY = /^[A-Za-z0-9._\-/]+$/

export function assertSafeKey(key: string): void {
  if (!SAFE_KEY.test(key) || key.includes('..') || key.startsWith('/')) {
    throw new Error(`Unsafe store key: ${key}`)
  }
}

/** Filesystem store for local runs and tests. Content types live next to the data. */
export class FsStore implements Store {
  constructor(private readonly root: string) {}

  private path(key: string): string {
    assertSafeKey(key)
    return join(this.root, normalize(key))
  }

  async getText(key: string): Promise<string | null> {
    try {
      return await readFile(this.path(key), 'utf8')
    } catch {
      return null
    }
  }

  async getBytes(key: string): Promise<{ bytes: Uint8Array; contentType: string } | null> {
    try {
      const bytes = new Uint8Array(await readFile(this.path(key)))
      const contentType = (await this.getText(`${key}.type`)) ?? 'application/octet-stream'
      return { bytes, contentType }
    } catch {
      return null
    }
  }

  async setText(key: string, value: string, contentType = 'application/json'): Promise<void> {
    const p = this.path(key)
    await mkdir(dirname(p), { recursive: true })
    await writeFile(p, value, 'utf8')
    await writeFile(`${p}.type`, contentType, 'utf8')
  }

  async setBytes(key: string, value: Uint8Array, contentType: string): Promise<void> {
    const p = this.path(key)
    await mkdir(dirname(p), { recursive: true })
    await writeFile(p, value)
    await writeFile(`${p}.type`, contentType, 'utf8')
  }
}

/** Netlify Blobs store. Only usable inside a Netlify function or build context. */
export async function createNetlifyStore(name = 'bountybox-judge'): Promise<Store> {
  const { getStore } = await import('@netlify/blobs')
  const blobs = getStore({ name, consistency: 'strong' })
  return {
    async getText(key) {
      assertSafeKey(key)
      return (await blobs.get(key, { type: 'text' })) ?? null
    },
    async getBytes(key) {
      assertSafeKey(key)
      const entry = await blobs.getWithMetadata(key, { type: 'arrayBuffer' })
      if (!entry) return null
      const contentType = typeof entry.metadata.contentType === 'string' ? entry.metadata.contentType : 'application/octet-stream'
      return { bytes: new Uint8Array(entry.data), contentType }
    },
    async setText(key, value, contentType = 'application/json') {
      assertSafeKey(key)
      await blobs.set(key, value, { metadata: { contentType } })
    },
    async setBytes(key, value, contentType) {
      assertSafeKey(key)
      const copy = new Uint8Array(value)
      await blobs.set(key, copy.buffer, { metadata: { contentType } })
    },
  }
}
