"use client"

import { useEffect, useState } from "react"
import { LoaderCircleIcon, NotebookPenIcon } from "lucide-react"
import { getComposerOptions, type ComposerOptions } from "@/app/(app)/notes/actions"
import { NoteComposer } from "@/components/notes/note-composer"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"

/**
 * Uppgifter kommer mitt i passet, sällan medan rätt sida är öppen, så rutan går
 * att nå överallt. Väljarna hämtas först när dialogen öppnas, så sidhuvudet
 * kostar ingenting på sidor som aldrig använder den.
 */
export function LogIntelButton() {
  const [open, setOpen] = useState(false)
  const [options, setOptions] = useState<ComposerOptions | null>(null)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    if (!open || options || failed) return
    let active = true
    getComposerOptions()
      .then((next) => {
        if (active) setOptions(next)
      })
      .catch(() => {
        if (active) setFailed(true)
      })
    return () => {
      active = false
    }
  }, [open, options, failed])

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="secondary" title="Logga uppgift">
          <NotebookPenIcon />
          <span className="hidden sm:inline">Logga uppgift</span>
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>Logga uppgift</DialogTitle>
          <DialogDescription>
            Koppla den till den det gäller, eller till ingen alls om du inte vet ännu.
          </DialogDescription>
        </DialogHeader>
        {failed ? (
          <p role="alert" className="text-sm text-destructive">
            Kunde inte hämta personer och organisationer att koppla till. Ladda om och försök igen.
          </p>
        ) : options ? (
          <NoteComposer
            tagSuggestions={options.tagSuggestions}
            targetOptions={{ organizations: options.organizations, cases: options.cases }}
            onSaved={() => setOpen(false)}
            submitLabel="Logga uppgift"
          />
        ) : (
          <div className="flex items-center justify-center py-8 text-muted-foreground">
            <LoaderCircleIcon className="size-5 animate-spin" />
          </div>
        )}
      </DialogContent>
    </Dialog>
  )
}
