import { assertNotTransient, guard } from './errors'

export interface GithubPrFacts {
  found: boolean
  merged: boolean
  state: string
  author: string
  title: string
  body: string
  mergedAt: string | null
  createdAt: string | null
  baseRepo: string
  baseRef: string
  htmlURL: string
  changedFiles: number
  additions: number
  deletions: number
  mergedBy: string | null
  files: Array<{ filename: string; status: string; additions: number; deletions: number; patch: string }>
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}
function num(value: unknown): number {
  return typeof value === 'number' ? value : 0
}
function obj(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
}

async function gh(path: string, token: string | null): Promise<{ status: number; json: unknown }> {
  return guard('GitHub API', async () => {
    const res = await fetch(`https://api.github.com${path}`, {
      headers: {
        accept: 'application/vnd.github+json',
        'user-agent': 'BountyBoxJudge/1.0',
        'x-github-api-version': '2022-11-28',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      signal: AbortSignal.timeout(10_000),
    })
    assertNotTransient(res.status, 'GitHub API')
    // 403 with no rate-limit headers left is a rate limit too.
    if (res.status === 403 && res.headers.get('x-ratelimit-remaining') === '0') assertNotTransient(429, 'GitHub API rate limit')
    const json: unknown = res.ok ? await res.json() : null
    return { status: res.status, json }
  })
}

export async function fetchGithubPr(owner: string, repo: string, number: number, token: string | null): Promise<GithubPrFacts> {
  const base = `/repos/${owner}/${repo}/pulls/${number}`
  const pr = await gh(base, token)
  if (pr.status !== 200) {
    return {
      found: false, merged: false, state: 'missing', author: '', title: '', body: '', mergedAt: null, createdAt: null,
      baseRepo: `${owner}/${repo}`, baseRef: '', htmlURL: '', changedFiles: 0, additions: 0, deletions: 0, mergedBy: null, files: [],
    }
  }
  const p = obj(pr.json)
  const files = await gh(`${base}/files?per_page=15`, token)
  const list = Array.isArray(files.json) ? files.json : []
  return {
    found: true,
    merged: p.merged === true,
    state: str(p.state),
    author: str(obj(p.user).login),
    title: str(p.title),
    body: str(p.body).slice(0, 6_000),
    mergedAt: str(p.merged_at) || null,
    createdAt: str(p.created_at) || null,
    baseRepo: str(obj(obj(p.base).repo).full_name) || `${owner}/${repo}`,
    baseRef: str(obj(p.base).ref),
    htmlURL: str(p.html_url),
    changedFiles: num(p.changed_files),
    additions: num(p.additions),
    deletions: num(p.deletions),
    mergedBy: str(obj(p.merged_by).login) || null,
    files: list.slice(0, 15).map((f) => {
      const file = obj(f)
      return {
        filename: str(file.filename),
        status: str(file.status),
        additions: num(file.additions),
        deletions: num(file.deletions),
        patch: str(file.patch).slice(0, 1_500),
      }
    }),
  }
}
