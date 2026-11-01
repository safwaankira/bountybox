import { Loader2 } from 'lucide-react'

/** "Showing 20 of 340" with a button that fetches the next page. Renders nothing when everything is already shown. */
export function LoadMore({
  shown,
  total,
  hasMore,
  loading,
  onLoadMore,
  noun,
}: {
  shown: number
  total: number
  hasMore: boolean
  loading: boolean
  onLoadMore: () => void
  noun: string
}) {
  if (!hasMore && shown >= total) return null
  return (
    <div className="mt-4 flex flex-col items-center gap-2">
      <p className="text-xs tabular-nums" style={{ color: 'var(--muted)' }}>
        Showing {shown} of {total} {noun}
      </p>
      <button type="button" className="btn btn-ghost" disabled={loading || !hasMore} onClick={onLoadMore}>
        {loading ? <Loader2 className="size-4 animate-spin" aria-hidden /> : null}
        {loading ? 'Loading…' : `Load more ${noun}`}
      </button>
    </div>
  )
}
