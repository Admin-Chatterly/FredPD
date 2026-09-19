import Link from "next/link"
import { Button } from "@/components/ui/button"

export default function PersonNotFound() {
  return (
    <div className="flex flex-col items-center gap-3 py-24 text-center">
      <h1 className="text-xl font-semibold">Personen finns inte</h1>
      <p className="text-sm text-muted-foreground">
        Posten kan ha tagits bort eller slagits ihop med en annan.
      </p>
      <Button asChild variant="secondary">
        <Link href="/people">Tillbaka till personer</Link>
      </Button>
    </div>
  )
}
