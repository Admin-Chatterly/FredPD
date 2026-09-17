"use client"

import { useActionState, useEffect } from "react"
import { LoaderCircleIcon } from "lucide-react"
import { createOrganization, updateOrganization } from "@/app/(app)/organizations/actions"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Textarea } from "@/components/ui/textarea"
import type { FormState } from "@/lib/action-types"
import {
  ORGANIZATION_STATUSES,
  ORGANIZATION_STATUS_LABELS,
  ORGANIZATION_TYPES,
  ORGANIZATION_TYPE_LABELS,
} from "@/lib/constants"

export type OrganizationFields = {
  id: string
  name: string
  type: string | null
  territory: string | null
  status: string
  notes: string | null
}

type Props =
  | { mode: "create" }
  | { mode: "edit"; organization: OrganizationFields; onDone: () => void; onCancel: () => void }

const initialState: FormState = {}

export function OrganizationForm(props: Props) {
  const action = props.mode === "create" ? createOrganization : updateOrganization
  const [state, formAction, pending] = useActionState(action, initialState)
  const onDone = props.mode === "edit" ? props.onDone : undefined
  const organization = props.mode === "edit" ? props.organization : null

  useEffect(() => {
    if (state.ok) onDone?.()
  }, [state, onDone])

  return (
    <form action={formAction} className="flex flex-col gap-4">
      {organization ? <input type="hidden" name="id" value={organization.id} /> : null}

      <div className="flex flex-col gap-2">
        <Label htmlFor="org_name">Namn</Label>
        <Input
          id="org_name"
          name="name"
          required
          maxLength={200}
          defaultValue={organization?.name ?? ""}
          autoFocus
        />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-2">
          <Label htmlFor="org_type">Typ</Label>
          <Select name="type" defaultValue={organization?.type ?? "none"}>
            <SelectTrigger id="org_type">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Okänd</SelectItem>
              {ORGANIZATION_TYPES.map((t) => (
                <SelectItem key={t} value={t}>
                  {ORGANIZATION_TYPE_LABELS[t]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="org_status">Status</Label>
          <Select name="status" defaultValue={organization?.status ?? "active"}>
            <SelectTrigger id="org_status">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {ORGANIZATION_STATUSES.map((s) => (
                <SelectItem key={s} value={s}>
                  {ORGANIZATION_STATUS_LABELS[s]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="org_territory">Territorium</Label>
        <Input
          id="org_territory"
          name="territory"
          maxLength={200}
          defaultValue={organization?.territory ?? ""}
          placeholder="Grove Street, Davis"
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="org_notes">Anteckningar</Label>
        <Textarea
          id="org_notes"
          name="notes"
          rows={3}
          maxLength={4000}
          defaultValue={organization?.notes ?? ""}
          placeholder="Färger, verksamhet, kända bulvanföretag"
        />
      </div>

      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}

      <div className="flex gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          {props.mode === "create" ? "Skapa" : "Spara"}
        </Button>
        {props.mode === "edit" ? (
          <Button type="button" variant="ghost" onClick={props.onCancel} disabled={pending}>
            Avbryt
          </Button>
        ) : null}
      </div>
    </form>
  )
}
