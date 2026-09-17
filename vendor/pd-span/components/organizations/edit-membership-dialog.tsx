"use client"

import { useActionState, useEffect, useId, useState } from "react"
import { LoaderCircleIcon, PencilIcon } from "lucide-react"
import { toast } from "sonner"
import { updateMembership } from "@/app/(app)/memberships/actions"
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
import type { FormState } from "@/lib/action-types"
import { MEMBERSHIP_ROLE_SUGGESTIONS } from "@/lib/constants"

export function EditMembershipDialog({
  organizationId,
  personId,
  personLabel,
  role,
  isConfirmed,
}: {
  organizationId: string
  personId: string
  personLabel: string
  role: string | null
  isConfirmed: boolean
}) {
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="ghost" size="icon-sm" title={`Ändra medlemskapet för ${personLabel}`}>
          <PencilIcon />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{personLabel} i den här organisationen</DialogTitle>
          <DialogDescription>
            Ändringen syns även på personens egen sida.
          </DialogDescription>
        </DialogHeader>
        <MembershipForm
          organizationId={organizationId}
          personId={personId}
          role={role}
          isConfirmed={isConfirmed}
          onSaved={() => setOpen(false)}
        />
      </DialogContent>
    </Dialog>
  )
}

function MembershipForm({
  organizationId,
  personId,
  role,
  isConfirmed,
  onSaved,
}: {
  organizationId: string
  personId: string
  role: string | null
  isConfirmed: boolean
  onSaved: () => void
}) {
  const [state, formAction, pending] = useActionState(updateMembership, {} as FormState)
  const listId = useId()

  useEffect(() => {
    if (state.ok) {
      toast.success("Medlemskapet uppdaterat")
      onSaved()
    }
  }, [state, onSaved])

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <input type="hidden" name="organization_id" value={organizationId} />
      <input type="hidden" name="person_id" value={personId} />

      <div className="flex flex-col gap-2">
        <Label htmlFor="edit_role">Roll</Label>
        <Input
          id="edit_role"
          name="role"
          list={listId}
          defaultValue={role ?? ""}
          placeholder="torped, langare, ledare…"
          maxLength={100}
          autoFocus
        />
        <datalist id={listId}>
          {MEMBERSHIP_ROLE_SUGGESTIONS.map((r) => (
            <option key={r} value={r} />
          ))}
        </datalist>
      </div>

      <div className="flex items-center gap-2">
        <Checkbox id="edit_confirmed" name="is_confirmed" defaultChecked={isConfirmed} />
        <Label htmlFor="edit_confirmed">Bekräftad medlem</Label>
      </div>

      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}

      <DialogFooter>
        <Button type="submit" disabled={pending}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          Spara
        </Button>
      </DialogFooter>
    </form>
  )
}
