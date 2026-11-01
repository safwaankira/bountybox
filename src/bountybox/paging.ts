import { useInfiniteQuery } from '@tanstack/react-query'
import { usePublicClient } from 'wagmi'
import type { Address, PublicClient } from 'viem'
import { bountyBoxAbi } from './abi'
import { BOUNTYBOX_ADDRESS, CHAIN_ID } from './config'
import type { Claim, Contributor } from './data'

/**
 * Claims and backers are read one page at a time. A bounty can attract thousands of either, and a single
 * "read everything" call would eventually exceed what an RPC will return. The contract caps a page at 100.
 */
export const PAGE_SIZE = 20
const POLL_MS = 15_000

interface Page<T> {
  items: T[]
  total: number
}

type RawClaim = { hunter: Address; proofURL: string; note: string; handle: string; timestamp: bigint }

function toClaim(c: RawClaim, id: number): Claim {
  return { id, hunter: c.hunter, proofURL: c.proofURL, note: c.note, handle: c.handle, timestamp: Number(c.timestamp) }
}

async function readClaimsPage(client: PublicClient, bountyId: bigint, offset: number): Promise<Page<Claim>> {
  try {
    const [page, total] = await client.readContract({
      address: BOUNTYBOX_ADDRESS,
      abi: bountyBoxAbi,
      functionName: 'getClaimsPage',
      args: [bountyId, BigInt(offset), BigInt(PAGE_SIZE)],
    })
    return { items: page.map((c, i) => toClaim(c, offset + i)), total: Number(total) }
  } catch {
    // Contracts deployed before the paged views existed: read the full list once and slice it.
    const all = await client.readContract({ address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'getClaims', args: [bountyId] })
    return { items: all.slice(offset, offset + PAGE_SIZE).map((c, i) => toClaim(c, offset + i)), total: all.length }
  }
}

async function readContributorsPage(client: PublicClient, bountyId: bigint, offset: number): Promise<Page<Contributor>> {
  try {
    const [addresses, shares, total] = await client.readContract({
      address: BOUNTYBOX_ADDRESS,
      abi: bountyBoxAbi,
      functionName: 'getContributorsPage',
      args: [bountyId, BigInt(offset), BigInt(PAGE_SIZE)],
    })
    return { items: addresses.map((address, i) => ({ address, share: shares[i] ?? 0n })), total: Number(total) }
  } catch {
    const [addresses, shares] = await client.readContract({ address: BOUNTYBOX_ADDRESS, abi: bountyBoxAbi, functionName: 'getContributors', args: [bountyId] })
    return { items: addresses.slice(offset, offset + PAGE_SIZE).map((address, i) => ({ address, share: shares[offset + i] ?? 0n })), total: addresses.length }
  }
}

function usePaged<T>(key: string, bountyId: bigint, read: (client: PublicClient, id: bigint, offset: number) => Promise<Page<T>>) {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const query = useInfiniteQuery({
    queryKey: [key, CHAIN_ID, BOUNTYBOX_ADDRESS, bountyId.toString()],
    enabled: Boolean(client),
    initialPageParam: 0,
    refetchInterval: POLL_MS,
    queryFn: ({ pageParam }) => {
      if (!client) throw new Error('No RPC client')
      return read(client, bountyId, pageParam)
    },
    getNextPageParam: (last, all) => {
      const loaded = all.reduce((n, page) => n + page.items.length, 0)
      return last.items.length > 0 && loaded < last.total ? loaded : undefined
    },
  })
  const pages = query.data?.pages ?? []
  const items = pages.flatMap((p) => p.items)
  const total = pages.length > 0 ? (pages[pages.length - 1]?.total ?? items.length) : 0
  return {
    items,
    total: Math.max(total, items.length),
    hasMore: Boolean(query.hasNextPage),
    loadMore: () => void query.fetchNextPage(),
    isLoading: query.isLoading,
    isLoadingMore: query.isFetchingNextPage,
    isError: query.isError,
  }
}

export function usePagedClaims(bountyId: bigint) {
  return usePaged('claims-page', bountyId, readClaimsPage)
}

export function usePagedContributors(bountyId: bigint) {
  return usePaged('contributors-page', bountyId, readContributorsPage)
}
