import type { Config } from '@netlify/functions'
import { handleApi } from '../../judge/api'
import { createNetlifyStore } from '../../judge/store'

export default async (req: Request): Promise<Response> => handleApi(req, await createNetlifyStore())

export const config: Config = { path: ['/verdicts/*', '/evidence/*'] }
