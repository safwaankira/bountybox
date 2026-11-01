import { useState } from 'react'
import { GateButton } from '@/components/GateButton'
import { TxStatus } from '@/components/TxStatus'
import { LIMITS, MAX_CLAIMS_PER_HUNTER } from '@/bountybox/abi'
import { useMyClaimCount, type Bounty } from '@/bountybox/data'
import { safeHttpUrl } from '@/bountybox/format'
import { useBountyActions } from '@/bountybox/actions'

export function SubmitClaim({ bounty }: { bounty: Bounty }) {
  const { flow, submitClaim } = useBountyActions()
  const used = useMyClaimCount(bounty.id)
  const left = Math.max(0, MAX_CLAIMS_PER_HUNTER - used)
  const [proof, setProof] = useState('')
  const [note, setNote] = useState('')
  const [platform, setPlatform] = useState<'github' | 'x'>('github')
  const [username, setUsername] = useState('')

  const url = safeHttpUrl(proof.trim())
  const name = username.trim().replace(/^@/, '')
  const handlePattern = platform === 'github' ? /^[A-Za-z0-9-]{1,39}$/ : /^[A-Za-z0-9_]{1,15}$/
  const handle = name ? `${platform}:${name}` : ''
  const problem = left === 0
    ? `You have used all ${MAX_CLAIMS_PER_HUNTER} claims on this bounty`
    : !proof.trim()
    ? 'Add a link to your proof'
    : !url
      ? 'Proof must be a link starting with http:// or https://'
      : proof.trim().length > LIMITS.proofURL
        ? 'Link is too long'
        : bounty.requireHandle && !name
          ? 'This bounty requires your GitHub or X handle'
          : name && !handlePattern.test(name)
            ? `That is not a valid ${platform === 'github' ? 'GitHub' : 'X'} username`
            : null

  const submit = async () => {
    if (problem) return
    const receipt = await submitClaim(bounty.id, proof.trim(), note.trim(), handle)
    if (receipt) {
      setProof('')
      setNote('')
      setUsername('')
    }
  }

  return (
    <section className="card space-y-4 p-5">
      <div>
        <h2 className="display text-xl font-semibold">Submit a claim</h2>
        <p className="mt-0.5 text-sm text-pretty" style={{ color: 'var(--muted)' }}>
          {bounty.aiMode
            ? 'Share a link that proves you did it. Two AI models check it against the criteria; if both approve, the whole pot is paid to you automatically.'
            : 'Share a link that proves you did it. The poster chooses the winner and the whole pot goes to them.'}{' '}
          You can submit up to {MAX_CLAIMS_PER_HUNTER} claims per bounty ({left} left).
        </p>
      </div>
      <div>
        <label htmlFor="proof" className="label">
          Proof link
        </label>
        <input
          id="proof"
          type="url"
          inputMode="url"
          className="field mt-1.5"
          placeholder="https://"
          value={proof}
          maxLength={LIMITS.proofURL}
          disabled={flow.busy}
          onChange={(e) => setProof(e.target.value)}
        />
      </div>
      {(bounty.requireHandle || bounty.aiMode) && (
        <div>
          <span className="label">
            Your {bounty.requireHandle ? 'handle (required)' : 'handle (optional)'}
          </span>
          <div className="mt-1.5 flex gap-2">
            <select
              aria-label="Handle platform"
              className="field w-28 shrink-0"
              value={platform}
              disabled={flow.busy}
              onChange={(e) => setPlatform(e.target.value === 'x' ? 'x' : 'github')}
            >
              <option value="github">GitHub</option>
              <option value="x">X</option>
            </select>
            <input
              aria-label="Username"
              className="field"
              placeholder={platform === 'github' ? 'octocat' : 'username'}
              value={username}
              maxLength={39}
              disabled={flow.busy}
              onChange={(e) => setUsername(e.target.value)}
            />
          </div>
          <p className="mt-1 text-xs text-pretty" style={{ color: 'var(--subtle)' }}>
            The judge checks that this matches the author of your pull request or post. It is stored onchain with your claim.
          </p>
        </div>
      )}
      <div>
        <label htmlFor="note" className="label">
          Note (optional)
        </label>
        <textarea
          id="note"
          className="field mt-1.5 min-h-20 resize-y"
          placeholder="Anything the poster should know"
          value={note}
          maxLength={LIMITS.note}
          disabled={flow.busy}
          onChange={(e) => setNote(e.target.value)}
        />
      </div>
      <GateButton
        label="Submit claim"
        busyLabel={flow.state.phase === 'wallet' ? 'Confirm in wallet…' : 'Confirming…'}
        busy={flow.busy}
        disabled={problem !== null}
        onClick={() => void submit()}
      />
      {problem && (proof || left === 0) ? (
        <p className="text-center text-xs" style={{ color: 'var(--subtle)' }}>
          {problem}
        </p>
      ) : null}
      <TxStatus flow={flow.state} successText="Claim submitted." />
    </section>
  )
}
