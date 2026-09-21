"use client"

import { useActionState, useEffect, useId, useState } from "react"
import { LoaderCircleIcon, PlusIcon } from "lucide-react"
import { toast } from "sonner"
import { addCaseLink } from "@/app/(app)/cases/actions"
import { PersonPicker } from "@/components/people/person-picker"
import { Button } from "@/components/ui/button"
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
import type { FormState } from "@/lib/action-types"
import { CASE_ROLE_SUGGESTIONS } from "@/lib/constants"
import type { PersonPick } from "@/lib/data/people"

type OrganizationOption = { id: string; name: string }

/**
 * One dialog for both halves of a case link: the database allows exactly one of
 * a person or an organization per row, so the two never share a form.
 */
export function AddCaseLinkDialog({
  caseId,
  kind,
  organizations = [],
  linkedIds,
}: {
  caseId: string
  kind: "person" | "organization"
  organizations?: OrganizationOption[]
  linkedIds: string[]
}) {
  const [open, setOpen] = useState(false)
  const available = organizations.filter((o) => !linkedIds.includes(o.id))

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <PlusIcon /> Koppla
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {kind === "person" ? "Koppla en person till ärendet" : "Koppla en organisation till ärendet"}
          </DialogTitle>
          <DialogDescription>
            Rollen är hur de figurerar i just den här utredningen, inte deras rang på gatan.
          </DialogDescription>
        </DialogHeader>
        {kind === "organization" && available.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {organizations.length === 0
              ? "Det finns inga organisationer än. Skapa en på sidan Organisationer först."
              : "Alla organisationer i registret är redan kopplade till ärendet."}
          </p>
        ) : (
          <LinkForm
            caseId={caseId}
            kind={kind}
            organizations={available}
            linkedIds={linkedIds}
            onSaved={() => setOpen(false)}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}

function LinkForm({
  caseId,
  kind,
  organizations,
  linkedIds,
  onSaved,
}: {
  caseId: string
  kind: "person" | "organization"
  organizations: OrganizationOption[]
  linkedIds: string[]
  onSaved: () => void
}) {
  const [state, formAction, pending] = useActionState(addCaseLink, {} as FormState)
  const [person, setPerson] = useState<PersonPick | null>(null)
  const listId = useId()

  useEffect(() => {
    if (state.ok) {
      toast.success("Kopplad till ärendet")
      onSaved()
    }
  }, [state, onSaved])

  return (
    <form action={formAction} className="flex flex-col gap-4">
      <input type="hidden" name="case_id" value={caseId} />
      {kind === "person" ? (
        <>
          <input type="hidden" name="person_id" value={person?.id ?? ""} />
          <div className="flex flex-col gap-2">
            <Label>Person</Label>
            <PersonPicker value={person} onChange={setPerson} excludeIds={linkedIds} />
          </div>
        </>
      ) : (
        <div className="flex flex-col gap-2">
          <Label htmlFor="case_org">Organisation</Label>
          <Select name="organization_id" required>
            <SelectTrigger id="case_org">
              <SelectValue placeholder="Välj en" />
            </SelectTrigger>
            <SelectContent>
              {organizations.map((o) => (
                <SelectItem key={o.id} value={o.id}>
                  {o.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      )}

      <div className="flex flex-col gap-2">
        <Label htmlFor="case_role">Roll i ärendet</Label>
        <Input
          id="case_role"
          name="role"
          list={listId}
          maxLength={100}
          placeholder="misstänkt, vittne, oidentifierad…"
        />
        <datalist id={listId}>
          {CASE_ROLE_SUGGESTIONS.map((r) => (
            <option key={r} value={r} />
          ))}
        </datalist>
      </div>

      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}

      <DialogFooter>
        <Button type="submit" disabled={pending || (kind === "person" && !person)}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          Koppla
        </Button>
      </DialogFooter>
    </form>
  )
}
