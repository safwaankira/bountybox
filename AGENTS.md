# BountyBox

> Built with Arc Studio - money-powered apps in minutes

This is the **project memory** - what Arc Studio remembers about building this app. It helps future agents (or humans) understand and extend the project.

---

## What This App Does

Poidh-style USDC bounties on Arc. Posters escrow USDC, anyone can add to the pot, hunters submit proof, the poster accepts one claim and the full pot is paid to that hunter. Expired unpaid bounties let each contributor withdraw their own share.

## Deployments

- **Active: Arc Mainnet (5042)** BountyBox `0xeAD85E5EEE0E8553f3EE0a1DB81D1373d3D31CB1`, deploy block 28603084, deploy tx `0xed969b10e62f5af806800acd6c5444b733f1cc03aeea9ef2eeaa614f012b3860`. Deployed and verified by the user from their own wallet (creation input matches compiled bytecode, usdc() = `0x3600000000000000000000000000000000000000`). Arc Studio did not deploy or transact on mainnet. Never deploy, sign or fund on mainnet from Arc Studio.
- Testnet (still selectable): Arc Testnet (5042002) v3 `0x189aa6d6f5543055749ad70a3aa1280ec770d918`, deploy block 69572702. Superseded testnet versions `0xd4cf1b08dda63ad0f07b6a0e2ce746bd945494ae` and `0x7e67a1384240cf9f653a811810e3194544c56a52` must not be used.
- Network, address and deploy block come from `.env` (`VITE_BOUNTYBOX_NETWORK`, `VITE_BOUNTYBOX_ADDRESS`, `VITE_BOUNTYBOX_DEPLOY_BLOCK`) through `src/bountybox/config.ts`. A comment at the bottom of `.env` lists the testnet values. These are baked in at build time, so a host (Vercel, Netlify) needs the same three variables set.
- Hosting: SPA path routing; `public/_redirects` (Netlify) and `vercel.json` (Vercel) rewrite all paths to `index.html`. `bun run build` outputs `dist/`.
- Frontend mirrors contract constants in `src/bountybox/abi.ts` (MIN_AMOUNT, GRACE_PERIOD, MAX_DURATION, MAX_CLAIMS_PER_HUNTER). Keep them in sync if the contract changes. Frontend decides winners only via `hasAccepted`.

## Transaction waiting (do not revert to viem waitForTransactionReceipt)

- viem's waitForTransactionReceipt swallows block-watcher errors, so a 429 or flaky RPC looks like a 3 minute timeout (seen on Arc mainnet). `src/bountybox/receipt.ts` polls `eth_getTransactionReceipt` directly across all chain RPCs plus the wallet, backs off on 429, 4 minute timeout. `src/bountybox/rpc.ts` gives wagmi a fallback transport over every RPC in the chain definition.
- `src/bountybox/tx.ts` runs steps (skip check, send, wait, then an onchain state check if no receipt), `src/bountybox/actions.ts` defines each write with its own state check. The approve step is skipped when a fresh allowance read already covers the amount.
- `bun run test:rpc <txHash>` verifies this read-only against the active network.

## Design decisions

- Contributions and claims close strictly at expiry. Settlement time = expiry + 7 days if any claim exists, else expiry. acceptClaim works strictly before settlement time, refund only at or after it, so they never overlap.
- A junk claim can delay refunds by at most 7 days (accepted tradeoff). Max 3 claims per address per bounty. Poster cannot submit claims.
- Expiry capped at 90 days from creation. Minimum deposit 0.01 USDC.
- Status is Open, Paid, Refunded. Refunded is set only when the last contributor withdraws (pot == 0); until then an expired bounty stays Open and each remaining contributor can refund their own share. `hasAccepted` says whether a claim was accepted (winningClaimId is meaningless otherwise).
- Payout is pushed atomically; a USDC-blocklisted hunter makes accept revert, poster can accept another claim.
- 117 Foundry tests in `contracts/test/BountyBox.t.sol` and `BountyBoxHardening.t.sol`, `BountyBoxPartialRefund.t.sol` (invariants take several minutes).

## Tech Stack

- Frontend: React 18, Vite, TypeScript, Tailwind CSS
- Web3: wagmi v2, viem v2, ConnectKit
- Contracts: Solidity 0.8.28 + Foundry. Sources in `contracts/`, unit tests in `contracts/test/*.t.sol`. Build with `bun run contracts:build` (`forge build`), test with `bun run contracts:test` (`forge test`).
- Wallet: injected (MetaMask, etc.)
- Chain: Arc Testnet (Chain ID: 5042002, imported from `viem/chains`)
- Token: USDC (6 decimals) (Address: 0x3600000000000000000000000000000000000000, Chain: Arc Testnet)
- Toasts: Sonner

## Key Files

- `src/App.tsx` - Route switch (Home, Create, Bounty page)
- `src/bountybox/` - config, ABI, data hooks, tx flow hooks, formatters
- `src/pages/`, `src/router.tsx` - pages and tiny history router
- `contracts/BountyBox.sol`, `contracts/test/BountyBox.t.sol` - contract and Foundry tests
- `src/components/` - UI components
- `src/config.ts` - wagmi config (chains, connectors, transports)

## To Run

```bash
bun install
bun run dev
```


## BountyBoxV2 hardening (guardian, AI pot cap)
- BountyBoxV2 constructor is now `(usdc, aiJudge, guardian, maxAIPot)`. All four are immutable. `retireJudge()` (guardian only, one-way) blocks judgeAccept and new AI bounties/contributions/claims; settlement and refunds are unchanged.
- Deploy script: `contracts/script/DeployBountyBoxV2.s.sol` reads AI_JUDGE, GUARDIAN, MAX_AI_POT (default 100 USDC). Steps in DEPLOY_MAINNET.md.
- The testnet contract in `.env` (0xeAD8...1CB1, block 70021492) was deployed BEFORE this change (2-argument constructor). The UI reads `maxAIPot`/`judgeRetired` and hides them when the contract does not have them. Redeploy to see the cap and the retired banner.
- Judge worker rejects a claim whose normalized proof URL repeats an earlier claim's ("duplicate of claim #N"), and stops when the contract reports the judge retired.
