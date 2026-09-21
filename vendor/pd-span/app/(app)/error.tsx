"use client"

import { useEffect } from "react"
import Link from "next/link"
import { TriangleAlertIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"

/**
 * Anything a page throws lands here: a failed query, a missing migration, a
 * dropped connection. Better a page that says so and offers a way out than the
 * unstyled default.
 */
export default function AppError({
  error,
  reset,
}: {
  error: Error & { digest?: string }
  reset: () => void
}) {
  useEffect(() => {
    console.error(error)
  }, [error])

  return (
    <div className="flex flex-1 items-center justify-center py-16">
      <Card className="w-full max-w-lg border-destructive/40">
        <CardHeader>
          <div className="flex items-center gap-2 text-destructive">
            <TriangleAlertIcon className="size-5" />
            <CardTitle>Något gick fel</CardTitle>
          </div>
          <CardDescription>
            Sidan kunde inte läsas in. Om databasen just satts upp, kontrollera att varje fil i{" "}
            <code className="font-mono text-xs">supabase/migrations/</code> har körts.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <pre className="overflow-x-auto rounded-md bg-muted p-3 font-mono text-xs text-muted-foreground">
            {/* A server error can carry raw database text, which is of no use to
                an officer and needlessly detailed. The digest is what identifies
                it in the logs; the message itself is kept for development. */}
            {process.env.NODE_ENV === "production" ? "Servern rapporterade ett fel." : error.message}
            {error.digest ? `\n\nReferens: ${error.digest}` : ""}
          </pre>
          <div className="flex gap-2">
            <Button onClick={reset}>Försök igen</Button>
            <Button asChild variant="secondary">
              <Link href="/">Översikt</Link>
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
