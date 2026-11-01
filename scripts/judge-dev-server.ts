/**
 * Serves /verdicts and /evidence from ./.judge-data on port 3001, the same API the Netlify function serves.
 * The Vite dev server proxies those paths here, so the preview shows real judge output.
 *   bun run judge:dev
 */
import { createServer } from 'node:http'
import { handleApi } from '../judge/api'
import { FsStore } from '../judge/store'

const store = new FsStore('.judge-data')
const port = Number(process.env.JUDGE_DEV_PORT ?? '3001')

createServer((req, res) => {
  const url = `http://localhost:${port}${req.url ?? '/'}`
  handleApi(new Request(url, { method: req.method }), store)
    .then(async (response) => {
      res.writeHead(response.status, Object.fromEntries(response.headers))
      res.end(Buffer.from(await response.arrayBuffer()))
    })
    .catch(() => {
      res.writeHead(500).end()
    })
}).listen(port, '127.0.0.1', () => console.log(`[judge] dev API on http://127.0.0.1:${port}`))
