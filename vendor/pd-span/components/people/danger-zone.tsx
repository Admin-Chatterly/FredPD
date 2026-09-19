"use client"

import { useState, useTransition } from "react"
import { GitMergeIcon, LoaderCircleIcon, Trash2Icon } from "lucide-react"
import { toast } from "sonner"
import { deletePerson, mergePeople } from "@/app/(app)/people/actions"
import { PersonPicker } from "@/components/people/person-picker"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { Label } from "@/components/ui/label"
import type { PersonPick } from "@/lib/data/people"
import { isUnidentified, personLabel } from "@/lib/format"

type Counts = {
  notes: number
  vehicles: number
  memberships: number
  associates: number
  caseLinks: number
  evidence: number
}

type Person = { id: string; name: string | null; alias: string | null; description: string | null; status: string }

export function DangerZone({ person, counts }: { person: Person; counts: Counts }) {
  return (
    <Card className="border-destructive/30">
      <CardHeader>
        <CardTitle className="text-destructive">Åtgärder på posten</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        <MergeDialog person={person} />
        <DeleteDialog person={person} counts={counts} />
      </CardContent>
    </Card>
  )
}

function MergeDialog({ person }: { person: Person }) {
  const [open, setOpen] = useState(false)
  const [other, setOther] = useState<PersonPick | null>(null)
  const [keep, setKeep] = useState<"this" | "other">(isUnidentified(person) ? "other" : "this")
  const [pending, startTransition] = useTransition()

  const keepRecord = keep === "this" ? person : other
  const dropRecord = keep === "this" ? other : person

  function run() {
    if (!other) return
    const keepId = keep === "this" ? person.id : other.id
    const dropId = keep === "this" ? other.id : person.id
    startTransition(async () => {
      const result = await mergePeople(keepId, dropId)
      if (result && !result.ok) toast.error(result.error)
      else toast.success("Posterna sammanslagna")
    })
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next)
        if (!next) setOther(null)
      }}
    >
      <DialogTrigger asChild>
        <Button variant="outline" className="justify-start">
          <GitMergeIcon /> Slå ihop med en annan post
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Slå ihop två poster</DialogTitle>
          <DialogDescription>
            Använd detta när en okänd visar sig vara någon som redan är registrerad. Uppgifter, fordon,
            medlemskap, kontakter, ärendekopplingar och bevis flyttas till posten du behåller; tomma fält
            på den fylls från den andra, och den andra tas bort.
          </DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <div className="flex flex-col gap-2">
            <Label>Den andra posten</Label>
            <PersonPicker value={other} onChange={setOther} excludeIds={[person.id]} />
          </div>
          {other ? (
            <fieldset className="flex flex-col gap-2">
              <legend className="mb-1 text-sm font-medium">Vilken post ska behållas?</legend>
              <label className="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="keep"
                  checked={keep === "this"}
                  onChange={() => setKeep("this")}
                  className="accent-primary"
                />
                Behåll <strong>{personLabel(person)}</strong> (den här sidan)
              </label>
              <label className="flex cursor-pointer items-center gap-2 text-sm">
                <input
                  type="radio"
                  name="keep"
                  checked={keep === "other"}
                  onChange={() => setKeep("other")}
                  className="accent-primary"
                />
                Behåll <strong>{personLabel(other)}</strong>
              </label>
              {keepRecord && dropRecord ? (
                <p className="text-xs text-muted-foreground">
                  Allt på <strong>{personLabel(dropRecord)}</strong> flyttas till{" "}
                  <strong>{personLabel(keepRecord)}</strong>, sedan tas{" "}
                  <strong>{personLabel(dropRecord)}</strong> bort.
                </p>
              ) : null}
            </fieldset>
          ) : null}
        </div>
        <DialogFooter>
          <Button type="button" onClick={run} disabled={!other || pending}>
            {pending ? <LoaderCircleIcon className="animate-spin" /> : <GitMergeIcon />}
            Slå ihop
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function DeleteDialog({ person, counts }: { person: Person; counts: Counts }) {
  const [pending, startTransition] = useTransition()

  const parts = [
    counts.notes > 0 ? `${counts.notes} ${counts.notes === 1 ? "uppgift" : "uppgifter"}` : null,
    counts.memberships > 0 ? `${counts.memberships} ${counts.memberships === 1 ? "medlemskap" : "medlemskap"}` : null,
    counts.associates > 0 ? `${counts.associates} ${counts.associates === 1 ? "kontaktkoppling" : "kontaktkopplingar"}` : null,
    counts.caseLinks > 0 ? `${counts.caseLinks} ${counts.caseLinks === 1 ? "ärendekoppling" : "ärendekopplingar"}` : null,
    counts.evidence > 0 ? `${counts.evidence} ${counts.evidence === 1 ? "bevis" : "bevis"}` : null,
  ].filter(Boolean)

  function run() {
    startTransition(async () => {
      const result = await deletePerson(person.id)
      if (result && !result.ok) toast.error(result.error)
    })
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button variant="outline" className="justify-start text-destructive hover:text-destructive">
          <Trash2Icon /> Ta bort den här posten
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Ta bort {personLabel(person)}?</AlertDialogTitle>
          <AlertDialogDescription>
            {parts.length > 0
              ? `Det tar även bort ${parts.join(", ")}. `
              : "Inget annat är kopplat till den här posten. "}
            {counts.vehicles > 0
              ? `${counts.vehicles} ${counts.vehicles === 1 ? "fordon blir kvar" : "fordon blir kvar"} utan ägare. `
              : ""}
            Om det är en dubblett, slå ihop i stället så att inget går förlorat.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Avbryt</AlertDialogCancel>
          <AlertDialogAction
            onClick={run}
            disabled={pending}
            className="bg-destructive text-white hover:bg-destructive/90"
          >
            {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
            Ta bort
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
