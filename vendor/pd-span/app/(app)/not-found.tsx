import Link from "next/link"
import { Button } from "@/components/ui/button"

export default function NotFound() {
  return (
    <div className="flex flex-col items-center gap-3 py-24 text-center">
      <h1 className="text-xl font-semibold">Sidan finns inte</h1>
      <p className="text-sm text-muted-foreground">
        Länken kan vara gammal, eller så har posten den pekade på tagits bort eller slagits ihop.
      </p>
      <Button asChild variant="secondary">
        <Link href="/">Tillbaka till översikten</Link>
      </Button>
    </div>
  )
}
