/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_BOUNTYBOX_NETWORK?: string
  readonly VITE_BOUNTYBOX_ADDRESS?: string
  readonly VITE_BOUNTYBOX_DEPLOY_BLOCK?: string
  readonly VITE_JUDGE_BASE_URL?: string
  readonly VITE_JUDGE_AGENT_ID?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
