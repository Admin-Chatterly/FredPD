import Link from "next/link"
import { Button } from "@/components/ui/button"

export const metadata = { title: "Sidan finns inte" }

/**
 * A URL that matches no route at all resolves its not-found boundary from the
 * root, not from the (app) group, so without this file Next.js renders its own
 * English 404.
 */
export default function RootNotFound() {
  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-3 p-4 text-center">
      <h1 className="text-xl font-semibold">Sidan finns inte</h1>
      <p className="text-sm text-muted-foreground">
        Adressen leder ingenstans. Kontrollera länken, eller gå tillbaka till översikten.
      </p>
      <Button asChild variant="secondary">
        <Link href="/">Tillbaka till översikten</Link>
      </Button>
    </div>
  )
}
