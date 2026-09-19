"use client"

import { useActionState, useEffect } from "react"
import { LoaderCircleIcon } from "lucide-react"
import { createCase, updateCase } from "@/app/(app)/cases/actions"
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
import { CASE_STATUSES, CASE_STATUS_LABELS } from "@/lib/constants"

export type CaseFields = {
  id: string
  title: string
  description: string | null
  status: string
}

type Props =
  | { mode: "create" }
  | { mode: "edit"; caseRecord: CaseFields; onDone: () => void; onCancel: () => void }

export function CaseForm(props: Props) {
  const action = props.mode === "create" ? createCase : updateCase
  const [state, formAction, pending] = useActionState(action, {} as FormState)
  const onDone = props.mode === "edit" ? props.onDone : undefined

  useEffect(() => {
    if (state.ok) onDone?.()
  }, [state, onDone])

  const record = props.mode === "edit" ? props.caseRecord : null

  return (
    <form action={formAction} className="flex flex-col gap-4">
      {record ? <input type="hidden" name="id" value={record.id} /> : null}

      <div className="flex flex-col gap-2">
        <Label htmlFor="case_title">Titel</Label>
        <Input
          id="case_title"
          name="title"
          required
          maxLength={200}
          defaultValue={record?.title ?? ""}
          placeholder="Operation Grönt ljus"
          autoFocus
        />
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="case_description">Beskrivning</Label>
        <Textarea
          id="case_description"
          name="description"
          rows={3}
          maxLength={4000}
          defaultValue={record?.description ?? ""}
          placeholder="Vad utreds, och vad krävs för att avsluta ärendet."
        />
      </div>

      <div className="flex flex-col gap-2 sm:max-w-xs">
        <Label htmlFor="case_status">Status</Label>
        <Select name="status" defaultValue={record?.status ?? "open"}>
          <SelectTrigger id="case_status">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {CASE_STATUSES.map((s) => (
              <SelectItem key={s} value={s}>
                {CASE_STATUS_LABELS[s]}
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
          {props.mode === "create" ? "Öppna ärende" : "Spara"}
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
