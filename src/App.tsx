import { Header } from '@/components/Header'
import { BountyPage } from '@/pages/BountyPage'
import { Create } from '@/pages/Create'
import { Home } from '@/pages/Home'
import { usePath } from '@/router'

function parseBountyId(path: string): bigint | null {
  const match = /^\/bounty\/(\d+)\/?$/.exec(path)
  if (!match?.[1]) return null
  return BigInt(match[1])
}

export default function App() {
  const path = usePath()
  const bountyId = parseBountyId(path)

  return (
    <div className="min-h-dvh">
      <Header />
      <main className="mx-auto max-w-3xl px-4 pb-8 pt-6">
        {path === '/new' ? <Create /> : bountyId !== null ? <BountyPage key={bountyId.toString()} id={bountyId} /> : <Home />}
      </main>
    </div>
  )
}
