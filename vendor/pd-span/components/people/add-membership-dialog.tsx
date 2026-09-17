"use client"

import { useActionState, useEffect, useId, useState } from "react"
import { LoaderCircleIcon, PlusIcon } from "lucide-react"
import { toast } from "sonner"
import { addMembership } from "@/app/(app)/memberships/actions"
import type { FormState } from "@/lib/action-types"
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { MEMBERSHIP_ROLE_SUGGESTIONS, ORGANIZATION_TYPE_LABELS, type OrganizationType } from "@/lib/constants"
import type { OrganizationOption } from "@/lib/data/people"

type Props = {
  personId: string
  organizations: OrganizationOption[]
  existingIds: string[]
}

export function AddMembershipDialog({ personId, organizations, existingIds }: Props) {
  const [open, setOpen] = useState(false)
  const available = organizations.filter((o) => !existingIds.includes(o.id))

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <PlusIcon /> Lägg till
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Koppla till en organisation</DialogTitle>
          <DialogDescription>
            Misstänkt som standard. Kryssa i bekräftad när medlemskapet är fastställt.
          </DialogDescription>
        </DialogHeader>
        {available.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {organizations.length === 0
              ? "Det finns inga organisationer ännu. Skapa en på Organisationer först."
              : "Personen finns redan i alla registrerade organisationer."}
          </p>
        ) : (
          <MembershipForm personId={personId} organizations={available} onSaved={() => setOpen(false)} />
        )}
      </DialogContent>
    </Dialog>
  )
}

function MembershipForm({
  personId,
  organizations,
  onSaved,
}: {
  personId: string
  organizations: OrganizationOption[]
  onSaved: () => void
}) {
  const [state, formAction, pending] = useActionState(addMembership, {} as FormState)
  const listId = useId()

  useEffect(() => {
    if (state.ok) {
      toast.success("Medlemskapet tillagt")
      onSaved()
    }
  }, [state, onSaved])

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <input type="hidden" name="person_id" value={personId} />
      <div className="flex flex-col gap-2">
        <Label htmlFor="organization_id">Organisation</Label>
        <Select name="organization_id" required>
          <SelectTrigger id="organization_id">
            <SelectValue placeholder="Välj en" />
          </SelectTrigger>
          <SelectContent>
            {organizations.map((o) => (
              <SelectItem key={o.id} value={o.id}>
                {o.name}
                {o.type ? (
                  <span className="text-muted-foreground">
                    {" "}
                    · {ORGANIZATION_TYPE_LABELS[o.type as OrganizationType] ?? o.type}
                  </span>
                ) : null}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="flex flex-col gap-2">
        <Label htmlFor="role">Roll</Label>
        <Input id="role" name="role" list={listId} placeholder="torped, langare, ledare…" maxLength={100} />
        <datalist id={listId}>
          {MEMBERSHIP_ROLE_SUGGESTIONS.map((r) => (
            <option key={r} value={r} />
          ))}
        </datalist>
      </div>
      <div className="flex items-center gap-2">
        <Checkbox id="is_confirmed" name="is_confirmed" />
        <Label htmlFor="is_confirmed">Bekräftad medlem</Label>
      </div>
      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}
      <DialogFooter>
        <Button type="submit" disabled={pending}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          Lägg till medlemskap
        </Button>
      </DialogFooter>
    </form>
  )
}
