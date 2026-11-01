import type { JudgeConfig } from '../config'
import type { BountyView, ClaimView, Evidence } from '../types'
import { classifyProof } from './classify'
import { fetchGithubPr, type GithubPrFacts } from './github'
import { fetchTxFacts, type TxFacts } from './tx'
import { downloadImages, fetchWeb, type WebFacts } from './web'
import { defaultXFetchers, fetchXPost, type XFetcher, type XPost } from './x'

export type Facts =
  | { kind: 'github-pr'; pr: GithubPrFacts }
  | { kind: 'x-post'; post: XPost | null; urlUsername: string; notes: string[] }
  | { kind: 'onchain-tx'; tx: TxFacts; chainId: number }
  | { kind: 'web'; web: WebFacts | { unreachable: string } }

export interface EvidenceBlob {
  /** Path under evidence/<id>/, for example "img/0". */
  path: string
  bytes: Uint8Array
  contentType: string
}

export interface EvidenceBundle {
  evidence: Evidence
  facts: Facts
  blobs: EvidenceBlob[]
}

export interface BuildEvidenceInput {
  claim: ClaimView
  bounty: BountyView
  config: Pick<JudgeConfig, 'githubToken' | 'xBearerToken'>
  xFetchers?: XFetcher[]
}

const TEXT_LIMIT = 20_000

function emptyEvidence(claim: ClaimView, kind: Evidence['kind']): Evidence {
  return {
    version: 1,
    capturedAt: new Date().toISOString(),
    proofURL: claim.proofURL,
    kind,
    finalURL: claim.proofURL,
    title: '',
    description: '',
    text: '',
    author: null,
    publishedAt: null,
    metadata: {},
    images: [],
    fetchErrors: [],
  }
}

/** Collects everything the judge may look at. Transient failures throw TransientError; permanent ones become facts. */
export async function buildEvidence(input: BuildEvidenceInput): Promise<EvidenceBundle> {
  const { claim, config } = input
  const classified = classifyProof(claim.proofURL)

  if (classified.kind === 'github-pr') {
    const pr = await fetchGithubPr(classified.owner, classified.repo, classified.number, config.githubToken)
    const evidence = emptyEvidence(claim, 'github-pr')
    evidence.finalURL = pr.htmlURL || claim.proofURL
    evidence.title = pr.title
    evidence.description = `${pr.baseRepo} #${classified.number}`
    evidence.author = pr.author ? { platform: 'github', username: pr.author } : null
    evidence.publishedAt = pr.mergedAt
    evidence.text = [pr.body, ...pr.files.map((f) => `--- ${f.filename} (${f.status}, +${f.additions}/-${f.deletions})\n${f.patch}`)].join('\n\n').slice(0, TEXT_LIMIT)
    evidence.metadata = {
      found: pr.found, merged: pr.merged, state: pr.state, mergedAt: pr.mergedAt, createdAt: pr.createdAt, baseRepo: pr.baseRepo,
      baseRef: pr.baseRef, mergedBy: pr.mergedBy, changedFiles: pr.changedFiles, additions: pr.additions, deletions: pr.deletions,
    }
    return { evidence, facts: { kind: 'github-pr', pr }, blobs: [] }
  }

  if (classified.kind === 'x-post') {
    const { post, notes } = await fetchXPost(input.xFetchers ?? defaultXFetchers(config.xBearerToken), classified.id, classified.username)
    const evidence = emptyEvidence(claim, 'x-post')
    evidence.fetchErrors = notes
    if (post) {
      evidence.title = `Post by @${post.authorUsername}`
      evidence.text = post.text.slice(0, TEXT_LIMIT)
      evidence.author = { platform: 'x', username: post.authorUsername }
      evidence.publishedAt = post.createdAt
      evidence.metadata = { source: post.source, authorName: post.authorName, postId: post.id, dateIsApproximate: post.source === 'oembed' }
      const { images, notes: imageNotes } = await downloadImages(post.mediaURLs)
      evidence.fetchErrors.push(...imageNotes)
      return finishImages(evidence, { kind: 'x-post', post, urlUsername: classified.username, notes }, images)
    }
    return { evidence, facts: { kind: 'x-post', post: null, urlUsername: classified.username, notes }, blobs: [] }
  }

  if (classified.kind === 'onchain-tx') {
    const tx = await fetchTxFacts(classified.rpcUrls, classified.hash)
    const evidence = emptyEvidence(claim, 'onchain-tx')
    evidence.title = `Transaction ${classified.hash}`
    evidence.publishedAt = tx.timestamp ? new Date(tx.timestamp * 1000).toISOString() : null
    evidence.metadata = { chainId: classified.chainId, ...tx }
    evidence.text = JSON.stringify(tx, null, 2)
    return { evidence, facts: { kind: 'onchain-tx', tx, chainId: classified.chainId }, blobs: [] }
  }

  const web = await fetchWeb(classified.url)
  const evidence = emptyEvidence(claim, 'web')
  if ('unreachable' in web) {
    evidence.fetchErrors = [web.unreachable]
    return { evidence, facts: { kind: 'web', web }, blobs: [] }
  }
  evidence.finalURL = web.finalURL
  evidence.title = web.title
  evidence.description = web.description
  evidence.text = web.text
  evidence.metadata = { httpStatus: web.status }
  const { images, notes } = await downloadImages(web.imageURLs)
  evidence.fetchErrors = notes
  return finishImages(evidence, { kind: 'web', web }, images)
}

function finishImages(evidence: Evidence, facts: Facts, images: Awaited<ReturnType<typeof downloadImages>>['images']): EvidenceBundle {
  const blobs: EvidenceBlob[] = []
  images.forEach((image, index) => {
    const path = `img/${index}`
    evidence.images.push({ url: image.url, sha256: image.sha256, bytes: image.bytes.byteLength, contentType: image.contentType, storedAs: path })
    blobs.push({ path, bytes: image.bytes, contentType: image.contentType })
  })
  return { evidence, facts, blobs }
}
