# BountyBox

Bounties paid in USDC on Arc. Anyone can post a bounty and fund an escrow, other people can add to the pot, and hunters submit proof. The winner receives the whole pot, chosen either by the poster or by an AI judge. If a bounty expires unpaid, each backer withdraws their own share.

## Rules

- A bounty's deadline can be at most 90 days after it is created.
- Contributions and new claims close at the deadline.
- If claims are waiting at the deadline, the poster gets a 7 day grace period to accept one. Refunds stay closed during that time and open right after it.
- If there are no claims at the deadline, refunds open immediately.
- Each address can submit at most 3 claims per bounty, and the poster cannot claim their own bounty.
- The minimum deposit or contribution is 0.01 USDC.
- When posting, you choose who picks the winner: you, or the AI judge (two independent models must agree). This choice cannot be changed afterwards. On an AI-judged bounty nobody can accept a claim by hand, including the poster.
- AI-judged bounties need written acceptance criteria and can require hunters to link a matching GitHub or X handle. Work must be dated after the bounty was posted.
- The AI judge can only pay a claim to the hunter who submitted it. It cannot refund, withdraw or redirect funds, and if it never acts every backer still gets their share back after the deadline and grace period.
- AI-judged bounties have a maximum pot, fixed in the contract when it is deployed (100 USDC by default), shown on the posting and bounty pages. Bounties where the poster picks the winner are not capped.
- A separate guardian address can permanently retire the AI judge as an emergency switch. After that the judge can pay nothing, AI-judged bounties accept no new money or claims, and every backer gets their own share back after the deadline (and grace period). The guardian cannot move funds, and poster-judged bounties are unaffected. The app shows a banner when this happens.
- On AI-judged bounties, "hunter must link their X or GitHub handle" is on by default. It stops copycats, because only a proof written by the linked handle can win.
- If two claims on an AI-judged bounty submit the same proof link (however it is spelled, and x.com and twitter.com count as the same), only the earliest claim is considered; later copies are rejected as duplicates.
- **Per-bounty cap:** the AI pot cap applies to each AI-judged bounty on its own. It is not a total across bounties, so many capped bounties can add up.
- **Grace period:** a single claim submitted before the deadline, even a junk one, adds the 7 day grace period before refunds open.
- **Never send USDC straight to the contract.** Money sent that way is not credited to any bounty and can never be recovered by anyone. Always add money through the app (Post a bounty or Add to the pot).
- **Blocklisted contributors:** if USDC has blocklisted a backer's address, that backer's own share cannot be refunded to them (the transfer is refused and cannot be redirected). Every other backer can still refund their own share.
- A bounty is Open, Paid out (a claim was accepted), or Refunded (every backer has withdrawn their share). Until the last backer withdraws, an expired bounty stays Open but closed to new claims and money, and each remaining backer can still take back their own share.

Built with [Arc Studio](https://studio.arc.io)

## AI judge

Each AI-judged claim is checked by automatic verifiers first (GitHub pull request merged and by whom, X post author and date, onchain transaction, linked handle), then scored against the criteria by two independent models. A claim is approved only if both approve with at least 80% confidence. Every verdict, with its reasons and an evidence snapshot, is published, and an approved claim is paid by the judge wallet with the verdict hash recorded onchain. The bounty page shows each claim as Pending AI review, Approved or Rejected with the reasons and links, and the judge's wallet and ERC-8004 agent identity.

The judge runs as a Netlify scheduled function every 5 minutes. Claims are read a page at a time and worked through in bounded batches that resume where the last run stopped, so claim spam cannot stall a run. Locally you can run one pass with `bun run judge:once`, or the public verdict service with `bun run judge:dev`.

## Tech stack

- React, Vite, TypeScript, Tailwind CSS
- wagmi, viem, ConnectKit (injected wallets)
- Solidity 0.8.28 with Foundry and OpenZeppelin
- Netlify Functions and Blobs for the AI judge; Circle developer-controlled wallets for the judge wallet

## Development

Prerequisites: [Bun](https://bun.sh) and [Foundry](https://book.getfoundry.sh).

```bash
bun install
bun run dev
```

Other commands:

```bash
bun run contracts:build   # compile the contract
bun run contracts:test    # run the Foundry tests (includes a dry run of the deploy script)
bun run build             # production build into dist/
bun run check             # lint and typecheck
bun run test:rpc <txHash> # read-only check of RPC failover and receipt waiting (sends nothing)
bun run test:judge        # offline self-test of the AI judge worker (no network, no keys)
bun run judge:setup       # create the judge's Circle wallet (add --test for e2e test wallets)
bun run judge:register    # register the judge as an ERC-8004 agent (testnet)
bun run judge:once        # run one judge pass locally
bun run judge:dev         # serve verdicts and evidence locally on port 3001
bun run judge:e2e         # testnet end-to-end run with Circle test wallets
```

### Environment variables

The network and contract are configured in one place (`src/bountybox/config.ts`), driven by these variables:

- `VITE_BOUNTYBOX_NETWORK`: which configured network to use (currently `arc-testnet`).
- `VITE_BOUNTYBOX_ADDRESS`: address of the deployed BountyBox contract on that network.
- `VITE_BOUNTYBOX_DEPLOY_BLOCK`: block the contract was deployed at (where event lookups start).
- `VITE_JUDGE_AGENT_ID`: optional, the judge's ERC-8004 agent id, shown on the bounty and posting pages.
- `VITE_JUDGE_BASE_URL`: optional, origin of the judge's verdict service when it is not the same site.

AI judge worker (set these in Netlify's environment settings; never commit them):

- `JUDGE_PUBLIC_BASE_URL`: the public site origin. It is written into the verdict links stored onchain, so it must never be localhost; in production the judge refuses to run without it (or Netlify's own `URL`).
- `GROQ_API_KEY` (free) or `OPENAI_API_KEY`: first scoring model. `OPENAI_MODEL`, `OPENAI_BASE_URL`, `OPENAI_VISION` are optional.
- `GEMINI_API_KEY` and optional `GEMINI_MODEL`: second scoring model.
- `CIRCLE_API_KEY`, `CIRCLE_ENTITY_SECRET`, `JUDGE_WALLET_ID`: the judge's Circle wallet that signs payouts.
- `JUDGE_TRIGGER_SECRET`: shared secret between the scheduled function and the worker.
- `GITHUB_TOKEN`, `X_BEARER_TOKEN`: optional, for higher GitHub limits and the official X API.
- `JUDGE_ALLOW_MAINNET`, `JUDGE_RPC_URL`, `JUDGE_MAX_CLAIMS_PER_TICK`, `JUDGE_TICK_BUDGET_MS`, `JUDGE_CLAIM_PAGE_SIZE`, `JUDGE_MAX_SCAN_PER_BOUNTY`, `JUDGE_MAX_SCAN_PER_TICK`: optional tuning.
- `RPC_PROXY_BASE_URL`, `RPC_PROXY_TOKEN`, `RPC_PROXY_CHAINS`: optional outside Arc Studio, used only by deploy scripts.

Both `arc-testnet` and `arc-mainnet` are available; the one in `VITE_BOUNTYBOX_NETWORK` is used, together with the contract address and deploy block you set for it. Mainnet uses real USDC. See `DEPLOY_MAINNET.md` for the step-by-step deploy from your own wallet (mainnet uses real USDC; review and audit first).

## Hosting

The app is a static site (`bun run build` creates `dist/`). Set the three `VITE_BOUNTYBOX_*` variables in your host's environment settings before building, because they are compiled into the site. Netlify and Vercel are pre-configured to send every path to `index.html` so links like `/bounty/3` work on reload.
