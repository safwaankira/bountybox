import { useState } from 'react'
import { Bot, CheckCircle2, ExternalLink, Hourglass, Trophy, XCircle } from 'lucide-react'
import { useAccount } from 'wagmi'
import { GateButton } from '@/components/GateButton'
import { TxStatus } from '@/components/TxStatus'
import type { Bounty, Claim, JudgedInfo } from '@/bountybox/data'
import { fmtDate, fmtUsdc, safeHttpUrl, shortAddress, shortHash } from '@/bountybox/format'
import { useBountyActions } from '@/bountybox/actions'
import { CHAIN_ID } from '@/bountybox/config'
import { evidencePath, isLocalUrl, safeHref, useVerdictDoc, verdictPath, type JudgeClaimStatus } from '@/bountybox/judge'
import { CopyButton, AddressText } from '@/components/CopyButton'
import { buildTxExplorerUrl } from '@/onchain-facts'

interface ClaimsListProps {
  bounty: Bounty
  claims: Claim[]
  acceptable: boolean
  /** Judge status per claim id (AI bounties). */
  statuses?: Record<string, JudgeClaimStatus>
  judgeUnreachable?: boolean
  /** Onchain proof of the judge's approval, for AI bounties that have paid out. */
  judged?: JudgedInfo
}

function JudgeStatus({
  bounty,
  claimId,
  status,
  judged,
  unreachable,
  bountyClosed,
}: {
  bounty: Bounty
  claimId: number
  status?: JudgeClaimStatus
  judged?: JudgedInfo
  unreachable: boolean
  bountyClosed: boolean
}) {
  // The chain is the source of truth: the winning claim of an AI bounty was approved by the judge,
  // whether or not the published verdict file can be reached.
  const isWinner = Boolean(judged) && judged?.claimId === claimId
  const wantsDoc = isWinner || status?.state === 'rejected'
  const doc = useVerdictDoc(bounty.id, claimId, wantsDoc)
  const published = doc.data ?? null

  let label = 'Pending AI review'
  let color = 'var(--accent)'
  let Icon = Hourglass
  let note: string | undefined
  let reasons: string[] = []

  if (isWinner) {
    label = 'Approved and paid'
    color = 'var(--success)'
    Icon = CheckCircle2
    reasons = published?.outcome === 'approved' ? published.reasons : (status?.reasons ?? [])
    if (!published && !doc.isLoading) note = 'The judge approved this claim onchain. Its written reasons are not reachable right now.'
  } else if (status?.state === 'rejected') {
    if (published?.outcome === 'rejected') {
      label = 'Rejected'
      color = 'var(--danger)'
      Icon = XCircle
      reasons = published.reasons
    } else if (!doc.isLoading) {
      // A rejection only counts once its verdict is published.
      note = 'The judge has not published its verdict for this claim yet.'
    }
  } else if (status?.state === 'approved') {
    label = 'Approved, payout pending'
    color = 'var(--success)'
    Icon = CheckCircle2
    reasons = status.reasons ?? []
  } else if (status?.state === 'accepted') {
    label = 'Approved and paid'
    color = 'var(--success)'
    Icon = CheckCircle2
    reasons = status.reasons ?? []
  } else if (status?.state === 'error') {
    label = 'Pending AI review (retrying)'
  } else if (status?.state === 'closed') {
    // The judge itself recorded that it did not review this claim before the bounty closed.
    label = 'Not reviewed (bounty closed)'
    color = 'var(--subtle)'
    Icon = Bot
  } else if (!status && bountyClosed) {
    // No status record is reachable: that is not the same as "never reviewed".
    label = 'No published verdict'
    color = 'var(--subtle)'
    Icon = Bot
    note = unreachable ? 'The judge service could not be reached, so the review outcome for this claim is unknown.' : undefined
  } else if (!status && unreachable) {
    label = 'Judge status unavailable'
    color = 'var(--subtle)'
  }

  // Links: prefer the same-origin copy of the verdict; fall back to the onchain URI unless it points at localhost.
  const onchainURI = judged && isWinner && !isLocalUrl(judged.verdictURI) ? safeHref(judged.verdictURI) : undefined
  const verdictLink = published || status?.verdictURL ? verdictPath(bounty.id, claimId) : onchainURI
  const evidenceLink = published?.evidenceId ? evidencePath(published.evidenceId) : safeHref(isLocalUrl(status?.evidenceURL) ? undefined : status?.evidenceURL)
  const txHash = (isWinner ? judged?.txHash : undefined) ?? status?.txHash
  const tx = txHash ? buildTxExplorerUrl(CHAIN_ID, txHash) : undefined
  const hash = (isWinner ? judged?.verdictHash : undefined) ?? status?.verdictHash

  return (
    <div className="mt-3 rounded-xl border p-3 text-sm" style={{ borderColor: 'var(--border)', background: 'rgba(255,255,255,0.03)' }}>
      <div className="flex items-center gap-2 font-semibold" style={{ color }}>
        <Icon className="size-4" aria-hidden /> {label}
      </div>
      {note && (
        <p className="mt-1.5 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
          {note}
        </p>
      )}
      {reasons.length > 0 && (
        <ul className="mt-2 list-disc space-y-1 pl-5 text-xs text-pretty" style={{ color: 'var(--muted)' }}>
          {reasons.map((reason, i) => (
            <li key={i}>{reason}</li>
          ))}
        </ul>
      )}
      {hash && (
        <p className="mt-2 flex flex-wrap items-center gap-1.5 text-xs" style={{ color: 'var(--muted)' }}>
          Verdict hash <span className="mono" title={hash}>{shortHash(hash)}</span>
          <CopyButton value={hash} label="verdict hash" />
        </p>
      )}
      {(verdictLink || evidenceLink || tx) && (
        <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
          {verdictLink && (
            <a href={verdictLink} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 underline-offset-2 hover:underline" style={{ color: 'var(--accent)' }}>
              Verdict JSON <ExternalLink className="size-3" aria-hidden />
            </a>
          )}
          {evidenceLink && (
            <a href={evidenceLink} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 underline-offset-2 hover:underline" style={{ color: 'var(--accent)' }}>
              Evidence snapshot <ExternalLink className="size-3" aria-hidden />
            </a>
          )}
          {tx && txHash && (
            <span className="inline-flex items-center gap-1">
              <a href={tx} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 underline-offset-2 hover:underline" style={{ color: 'var(--accent)' }}>
                Payout transaction <ExternalLink className="size-3" aria-hidden />
              </a>
              <CopyButton value={txHash} label="transaction hash" />
            </span>
          )}
        </div>
      )}
    </div>
  )
}

export function ClaimsList({ bounty, claims, acceptable, statuses = {}, judgeUnreachable = false, judged }: ClaimsListProps) {
  const { address } = useAccount()
  const { flow, acceptClaim } = useBountyActions()
  const [armed, setArmed] = useState<number | null>(null)
  const isPoster = address?.toLowerCase() === bounty.poster.toLowerCase() && !bounty.aiMode

  const accept = async (claim: Claim) => {
    const receipt = await acceptClaim(bounty.id, BigInt(claim.id))
    if (receipt) setArmed(null)
  }

  return (
    <section className="card p-5">
      <h2 className="display text-xl font-semibold">
        Claims <span className="tabular-nums" style={{ color: 'var(--subtle)' }}>{claims.length}</span>
      </h2>

      {claims.length === 0 ? (
        <p className="mt-3 text-sm" style={{ color: 'var(--muted)' }}>
          No claims yet. Be the first hunter to submit proof.
        </p>
      ) : (
        <ul className="mt-4 space-y-3">
          {claims.map((claim) => {
            const winner = bounty.hasAccepted && bounty.winningClaimId !== null && BigInt(claim.id) === bounty.winningClaimId
            const link = safeHttpUrl(claim.proofURL)
            const isMine = address?.toLowerCase() === claim.hunter.toLowerCase()
            return (
              <li
                key={claim.id}
                className="inner p-3.5"
                style={winner ? { borderColor: 'rgba(141,216,159,0.5)', background: 'rgba(141,216,159,0.08)' } : undefined}
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2 text-sm">
                    <span className="font-medium"><AddressText address={claim.hunter} label="hunter address" /></span>
                    {isMine && <span className="tag">You</span>}
                    {winner && (
                      <span className="tag" style={{ color: 'var(--success)', borderColor: 'rgba(141,216,159,0.4)' }}>
                        <Trophy className="size-3" aria-hidden /> Winner
                      </span>
                    )}
                  </div>
                  <span className="text-xs tabular-nums" style={{ color: 'var(--subtle)' }}>
                    #{claim.id} · {fmtDate(claim.timestamp)}
                  </span>
                </div>

                {link ? (
                  <a
                    href={link}
                    target="_blank"
                    rel="noopener noreferrer nofollow"
                    className="mt-2 flex items-center gap-1.5 break-all text-sm underline-offset-2 hover:underline"
                    style={{ color: 'var(--accent)' }}
                  >
                    <ExternalLink className="size-3.5 shrink-0" aria-hidden /> {claim.proofURL}
                  </a>
                ) : (
                  <p className="mt-2 break-all text-sm" style={{ color: 'var(--muted)' }}>
                    {claim.proofURL}
                  </p>
                )}
                {claim.handle && (
                  <p className="mt-2 text-xs" style={{ color: 'var(--muted)' }}>
                    Linked handle: <span className="mono">{claim.handle}</span>
                  </p>
                )}
                {claim.note && (
                  <p className="mt-2 whitespace-pre-wrap text-sm text-pretty" style={{ color: 'var(--muted)' }}>
                    {claim.note}
                  </p>
                )}

                {bounty.aiMode && (
                  <JudgeStatus
                    bounty={bounty}
                    claimId={claim.id}
                    status={statuses[String(claim.id)]}
                    judged={judged}
                    unreachable={judgeUnreachable}
                    bountyClosed={bounty.hasAccepted || !acceptable}
                  />
                )}

                {isPoster && acceptable && (
                  <div className="mt-3">
                    {armed === claim.id ? (
                      <div className="flex flex-col gap-2 sm:flex-row">
                        <GateButton
                          label={`Pay ${fmtUsdc(bounty.pot)} USDC to ${shortAddress(claim.hunter)}`}
                          busyLabel={flow.state.phase === 'wallet' ? 'Confirm in wallet…' : 'Confirming…'}
                          busy={flow.busy}
                          onClick={() => void accept(claim)}
                        />
                        <button type="button" className="btn btn-ghost sm:w-28" disabled={flow.busy} onClick={() => setArmed(null)}>
                          Cancel
                        </button>
                      </div>
                    ) : (
                      <button type="button" className="btn btn-primary w-full sm:w-auto" disabled={flow.busy} onClick={() => setArmed(claim.id)}>
                        Accept this claim
                      </button>
                    )}
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      )}

      {bounty.aiMode && claims.length > 0 && (
        <p className="mt-3 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
          This bounty is AI-judged. Nobody can accept a claim by hand, including the poster. The judge checks each claim
          roughly every 5 minutes and publishes its reasons, evidence and verdict hash.
        </p>
      )}
      {isPoster && acceptable && claims.length > 0 && (
        <p className="mt-3 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
          Accepting sends the full pot to that hunter and closes the bounty. It cannot be undone.
        </p>
      )}
      <TxStatus flow={flow.state} successText="Claim accepted. The pot has been paid out." />
    </section>
  )
}
