# Deploy BountyBoxV2 to Arc Mainnet (from your own Mac)

Mainnet moves real USDC and transactions cannot be undone. Arc Studio never signs, funds, or deploys on mainnet for you. Everything below runs on your machine with a wallet only you control. Get an independent audit and review every address before you broadcast. The contract has no owner and no upgrade path, so a deployed bug cannot be patched.

This guide deploys **BountyBoxV2** (poster-judged and AI-judged bounties). The v1 contract that may already be on mainnet is a separate contract and is not touched.

Run every command from the project root (the folder with `foundry.toml`). You need Foundry installed (`forge --version`) and `jq` (`brew install jq`).

| | Arc Mainnet |
|---|---|
| Chain ID | `5042` |
| RPC | `https://rpc.mainnet.arc.io` |
| Explorer | `https://explorer.arc.io` |
| USDC (constructor argument, 6 decimals) | `0x3600000000000000000000000000000000000000` |
| Gas token | USDC |

## 0. Decide the three immutable settings

The constructor takes four values and **none of them can ever be changed** after deployment. Decide them first.

| Variable | What it is | Advice |
|---|---|---|
| `AI_JUDGE` | The wallet that pays AI-judged bounties. | The address of the judge's Circle wallet on mainnet (needs a mainnet Circle API key and entity secret, and `JUDGE_ALLOW_MAINNET=true` on the worker). It must be a wallet you control. If the key is ever compromised it cannot be rotated, so see the guardian below. |
| `GUARDIAN` | An independent address that can call `retireJudge()` once: a permanent kill switch for the judge. | Use a **different key from the judge**, ideally a hardware wallet or multisig. It can never move funds or touch poster-judged bounties. It must differ from `AI_JUDGE` and from USDC. |
| `MAX_AI_POT` | Cap on the pot of every AI-judged bounty, in USDC base units (6 decimals). | Optional; defaults to 100 USDC (`100000000`). This bounds the loss per AI bounty if the judge or the models misbehave. Bounties where the poster picks the winner are not capped. |

What the guardian does: after `retireJudge()`, the judge can never pay anything again, and no new AI-judged bounties, contributions or claims are accepted. Existing AI bounties settle through the normal path: after the deadline (plus the 7 day grace period if claims were waiting) every backer takes back their own share. Nobody's funds can be trapped.

```bash
export AI_JUDGE=0xYOUR_JUDGE_WALLET
export GUARDIAN=0xYOUR_GUARDIAN_WALLET
export MAX_AI_POT=100000000        # 100 USDC; leave unset to use the default
```

## 1. Build and test first

```bash
forge build
forge test --no-match-test invariant
```

## 2. Create a NEW deploy-only wallet

```bash
cast wallet new
```

This prints an address and a private key. Save the private key in a password manager and nowhere else. Then import it into an encrypted keystore. The key is typed into a hidden prompt, never put on the command line:

```bash
cast wallet import bountybox-deployer --interactive
```

Paste the private key when asked, then choose a keystore password (also save it). Clear the key from your screen: run `clear`, then close that terminal window. Now note your address:

```bash
cast wallet list
export DEPLOYER=0xYOUR_NEW_ADDRESS
```

Only fund this wallet with what the deploy needs. The deployer has no special powers in the contract.

## 3. Check the network and the wallet balance

```bash
export RPC=https://rpc.mainnet.arc.io
cast chain-id --rpc-url $RPC            # must print 5042
cast balance $DEPLOYER --rpc-url $RPC --ether
```

The balance prints in USDC (gas and USDC are the same funds on Arc, so do not add the two views together). There is no public mainnet faucet: gas USDC comes through your Circle point of contact. A deploy needs well under 1 USDC.

## 4. Estimate gas before broadcasting

```bash
export USDC=0x3600000000000000000000000000000000000000
INIT=$(forge inspect BountyBoxV2 bytecode)
cast estimate --from $DEPLOYER --rpc-url $RPC --create "$INIT" "constructor(address,address,address,uint256)" $USDC $AI_JUDGE $GUARDIAN ${MAX_AI_POT:-100000000}
cast estimate --cost --from $DEPLOYER --rpc-url $RPC --create "$INIT" "constructor(address,address,address,uint256)" $USDC $AI_JUDGE $GUARDIAN ${MAX_AI_POT:-100000000}
cast gas-price --rpc-url $RPC
```

The first line is gas units, the second is the estimated cost in USDC. Then run the script as a simulation. It does NOT send anything because `--broadcast` is missing:

```bash
forge script contracts/script/DeployBountyBoxV2.s.sol:DeployBountyBoxV2 --rpc-url $RPC --account bountybox-deployer
```

Enter your keystore password. Check the output carefully: `Chain id: 5042`, `USDC: 0x3600...0000`, `AI judge`, `Guardian` and `Max AI pot` are exactly what you intended, `Deployer` is your address, and your balance is comfortably above `Estimated amount required` (the label says ETH; on Arc it is USDC). The script refuses to run on a non-Arc chain, if the guardian equals the judge or USDC, or if the cap is below 0.01 USDC. The contract address printed here is only a prediction.

## 5. Deploy

Only when step 4 looks right:

```bash
forge script contracts/script/DeployBountyBoxV2.s.sol:DeployBountyBoxV2 --rpc-url $RPC --account bountybox-deployer --broadcast
```

Do not add `--verify` (Arc has no verified-source flow for this). Do not run it a second time: that would create a second contract. If the run is interrupted, check `broadcast/DeployBountyBoxV2.s.sol/5042/run-latest.json` first. Save the results:

```bash
export BOUNTYBOX=$(jq -r '.transactions[0].contractAddress' broadcast/DeployBountyBoxV2.s.sol/5042/run-latest.json)
export TX=$(jq -r '.transactions[0].hash' broadcast/DeployBountyBoxV2.s.sol/5042/run-latest.json)
echo $BOUNTYBOX $TX
```

## 6. Verify the deployed contract

Code exists, and the constructor arguments are what you intended:

```bash
cast code $BOUNTYBOX --rpc-url $RPC | wc -c                    # more than 3
cast call $BOUNTYBOX "usdc()(address)" --rpc-url $RPC           # 0x3600...0000
cast call $BOUNTYBOX "aiJudge()(address)" --rpc-url $RPC        # your judge wallet
cast call $BOUNTYBOX "guardian()(address)" --rpc-url $RPC       # your guardian wallet
cast call $BOUNTYBOX "maxAIPot()(uint256)" --rpc-url $RPC       # 100000000 unless you chose otherwise
cast call $BOUNTYBOX "judgeRetired()(bool)" --rpc-url $RPC      # false
cast receipt $TX contractAddress --rpc-url $RPC                 # equals $BOUNTYBOX
```

The creation transaction must be exactly your compiled bytecode plus the encoded constructor arguments:

```bash
ARGS=$(cast abi-encode 'constructor(address,address,address,uint256)' $USDC $AI_JUDGE $GUARDIAN ${MAX_AI_POT:-100000000} | cut -c3-)
EXPECTED=$(echo "$(forge inspect BountyBoxV2 bytecode)$ARGS" | tr 'A-F' 'a-f')
ACTUAL=$(cast tx $TX input --rpc-url $RPC | tr 'A-F' 'a-f')
[ "$EXPECTED" = "$ACTUAL" ] && echo MATCH || echo MISMATCH
```

It must print `MATCH`. Then check the rules are what you expect:

```bash
cast call $BOUNTYBOX "GRACE_PERIOD()(uint256)" --rpc-url $RPC          # 604800 (7 days)
cast call $BOUNTYBOX "MAX_DURATION()(uint256)" --rpc-url $RPC          # 7776000 (90 days)
cast call $BOUNTYBOX "MAX_CLAIMS_PER_HUNTER()(uint256)" --rpc-url $RPC # 3
cast call $BOUNTYBOX "MIN_AMOUNT()(uint256)" --rpc-url $RPC            # 10000 (0.01 USDC)
cast call $BOUNTYBOX "bountyCount()(uint256)" --rpc-url $RPC           # 0
```

Open `https://explorer.arc.io/address/$BOUNTYBOX` and confirm the address.

## 7. Point the app and the judge at mainnet

Get the deployment block, then update `.env` (macOS `sed` needs the empty `''` after `-i`):

```bash
BLOCK=$(cast receipt $TX blockNumber --rpc-url $RPC)
sed -i '' "s/^VITE_BOUNTYBOX_NETWORK=.*/VITE_BOUNTYBOX_NETWORK=arc-mainnet/" .env
sed -i '' "s/^VITE_BOUNTYBOX_ADDRESS=.*/VITE_BOUNTYBOX_ADDRESS=$BOUNTYBOX/" .env
sed -i '' "s/^VITE_BOUNTYBOX_DEPLOY_BLOCK=.*/VITE_BOUNTYBOX_DEPLOY_BLOCK=$BLOCK/" .env
```

Restart the dev server (Vite only reads `.env` at startup). The header should show `Arc · real USDC`. The app refuses to start on mainnet if the address or deploy block is missing. The page shows the contract's real "Max AI bounty" and a banner if the judge is ever retired.

For the judge worker (Netlify), set the same three `VITE_BOUNTYBOX_*` values, `JUDGE_ALLOW_MAINNET=true`, `JUDGE_PUBLIC_BASE_URL` (the public site), and the mainnet Circle credentials and `JUDGE_WALLET_ID` of the wallet that equals `AI_JUDGE`. The worker refuses to run if its wallet is not the contract's `aiJudge`, and stops by itself if the judge is retired. Remember the ERC-8004 registration in this project is testnet-only.

To go back to testnet, set `VITE_BOUNTYBOX_NETWORK=arc-testnet` and the testnet contract address and deploy block, then restart.

## 8. If the judge must be switched off

Only the guardian can do this, once, and it can never be undone. Use the guardian's own keystore (hardware wallets: use their own tooling):

```bash
cast send $BOUNTYBOX "retireJudge()" --rpc-url $RPC --account guardian-keystore-name
cast call $BOUNTYBOX "judgeRetired()(bool)" --rpc-url $RPC    # true
```

Afterwards AI-judged bounties can no longer be paid. Backers withdraw their own shares from the bounty page once the deadline (and grace period) has passed. Poster-judged bounties keep working normally.

## 9. First real test

With a small bounty (for example 1 USDC): create a poster-judged one, add a claim from a second wallet, accept it, and confirm the payout on the explorer. Then try a small AI-judged bounty end to end and a short-lived one with no claims that you refund after it expires. Afterwards, move any leftover USDC out of the deploy-only wallet.
