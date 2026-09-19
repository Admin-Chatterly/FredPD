"use client"

import { useActionState, useEffect } from "react"
import { LoaderCircleIcon } from "lucide-react"
import { createPerson, updatePerson, type FormState } from "@/app/(app)/people/actions"
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
import { PERSON_STATUSES, PERSON_STATUS_LABELS } from "@/lib/constants"

type PersonFields = {
  id: string
  name: string | null
  alias: string | null
  description: string | null
  status: string
}

type Props =
  | { mode: "create" }
  | { mode: "edit"; person: PersonFields; onDone: () => void; onCancel: () => void }

const initialState: FormState = {}

export function PersonForm(props: Props) {
  const action = props.mode === "create" ? createPerson : updatePerson
  const [state, formAction, pending] = useActionState(action, initialState)
  const onDone = props.mode === "edit" ? props.onDone : undefined

  useEffect(() => {
    if (state.ok) onDone?.()
  }, [state, onDone])

  const person = props.mode === "edit" ? props.person : null

  return (
    <form action={formAction} className="flex flex-col gap-4">
      {person ? <input type="hidden" name="id" value={person.id} /> : null}

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-2">
          <Label htmlFor="name">Namn</Label>
          <Input
            id="name"
            name="name"
            defaultValue={person?.name ?? ""}
            placeholder="Lämna tomt om det är okänt"
            maxLength={200}
            autoFocus={props.mode === "create"}
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="alias">Alias / gatunamn</Label>
          <Input id="alias" name="alias" defaultValue={person?.alias ?? ""} maxLength={200} />
        </div>
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="description">Signalement</Label>
        <Textarea
          id="description"
          name="description"
          rows={4}
          maxLength={4000}
          defaultValue={person?.description ?? ""}
          placeholder="Kroppsbyggnad, kläder, kännetecken, fordon, var personen setts…"
        />
      </div>

      <div className="flex flex-col gap-2 sm:max-w-xs">
        <Label htmlFor="status">Status</Label>
        <Select name="status" defaultValue={person?.status ?? "unknown"}>
          <SelectTrigger id="status">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {PERSON_STATUSES.map((s) => (
              <SelectItem key={s} value={s}>
                {PERSON_STATUS_LABELS[s]}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}

      <div className="flex gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          {props.mode === "create" ? "Skapa akt" : "Spara"}
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
