"use client"

import { useActionState, useEffect, useId, useState } from "react"
import { LoaderCircleIcon, PlusIcon } from "lucide-react"
import { toast } from "sonner"
import { addAssociate, type FormState } from "@/app/(app)/people/actions"
import { PersonPicker } from "@/components/people/person-picker"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { RELATIONSHIP_SUGGESTIONS } from "@/lib/constants"
import type { PersonPick } from "@/lib/data/people"

export function AddAssociateDialog({ personId, excludeIds }: { personId: string; excludeIds: string[] }) {
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <PlusIcon /> Koppla
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Koppla en kontakt</DialogTitle>
          <DialogDescription>
            Kopplingar mellan personer, oberoende av gemensamma organisationer. Familj, kontakter, rivaler.
          </DialogDescription>
        </DialogHeader>
        <AssociateForm personId={personId} excludeIds={excludeIds} onSaved={() => setOpen(false)} />
      </DialogContent>
    </Dialog>
  )
}

function AssociateForm({
  personId,
  excludeIds,
  onSaved,
}: {
  personId: string
  excludeIds: string[]
  onSaved: () => void
}) {
  const [state, formAction, pending] = useActionState(addAssociate, {} as FormState)
  const [picked, setPicked] = useState<PersonPick | null>(null)
  const listId = useId()

  useEffect(() => {
    if (state.ok) {
      toast.success("Kontakten kopplad")
      onSaved()
    }
  }, [state, onSaved])

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <input type="hidden" name="person_id" value={personId} />
      <input type="hidden" name="associate_id" value={picked?.id ?? ""} />
      <div className="flex flex-col gap-2">
        <Label>Person</Label>
        <PersonPicker value={picked} onChange={setPicked} excludeIds={[personId, ...excludeIds]} />
      </div>
      <div className="flex flex-col gap-2">
        <Label htmlFor="relationship">Relation</Label>
        <Input
          id="relationship"
          name="relationship"
          list={listId}
          placeholder="familj, återkommande kontakt, rival…"
          maxLength={100}
        />
        <datalist id={listId}>
          {RELATIONSHIP_SUGGESTIONS.map((r) => (
            <option key={r} value={r} />
          ))}
        </datalist>
      </div>
      <div className="flex items-center gap-2">
        <Checkbox id="assoc_confirmed" name="is_confirmed" />
        <Label htmlFor="assoc_confirmed">Bekräftad koppling</Label>
      </div>
      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}
      <DialogFooter>
        <Button type="submit" disabled={pending || !picked}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          Koppla
        </Button>
      </DialogFooter>
    </form>
  )
}
