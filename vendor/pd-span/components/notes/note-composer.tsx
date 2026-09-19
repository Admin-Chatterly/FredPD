"use client"

import { useActionState, useEffect, useId, useState } from "react"
import { LoaderCircleIcon, NotebookPenIcon } from "lucide-react"
import { toast } from "sonner"
import { addNote } from "@/app/(app)/notes/actions"
import { PersonPicker } from "@/components/people/person-picker"
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
  CONFIDENCES,
  CONFIDENCE_LABELS,
  NOTE_SOURCES,
  NOTE_SOURCE_LABELS,
} from "@/lib/constants"
import type { NoteTargetOptions } from "@/lib/data/notes"
import type { PersonPick } from "@/lib/data/people"

const initialState: FormState = {}

export type NoteTarget = { personId?: string; organizationId?: string; caseId?: string }

type Props = {
  /** Fasta kopplingar, för en detaljsida där uppgiften hör till just den posten. */
  target?: NoteTarget
  tagSuggestions: string[]
  /**
   * När den finns får man välja kopplingarna själv, och att inte välja någon är
   * giltigt: det är en allmän uppgift.
   */
  targetOptions?: NoteTargetOptions
  onSaved?: () => void
  submitLabel?: string
}

/**
 * Loggar en uppgift på en person, en organisation, ett ärende, valfri
 * kombination, eller ingenting alls. Formuläret monteras om efter varje
 * sparning så att det kommer tillbaka tomt.
 */
export function NoteComposer(props: Props) {
  const [round, setRound] = useState(0)
  return (
    <ComposerForm
      {...props}
      key={round}
      onSaved={() => {
        setRound((r) => r + 1)
        props.onSaved?.()
      }}
    />
  )
}

function ComposerForm({
  target = {},
  tagSuggestions,
  targetOptions,
  onSaved,
  submitLabel = "Logga uppgift",
}: Props) {
  const [state, formAction, pending] = useActionState(addNote, initialState)
  const [person, setPerson] = useState<PersonPick | null>(null)
  const listId = useId()

  useEffect(() => {
    if (state.ok) {
      toast.success("Uppgiften loggad")
      onSaved?.()
    }
  }, [state, onSaved])

  return (
    <form action={formAction} className="flex flex-col gap-3">
      {targetOptions ? (
        <div className="flex flex-col gap-3 rounded-md border border-dashed border-border p-3">
          <p className="text-xs text-muted-foreground">
            Koppla den till det som är känt. Lämna allt tomt för en allmän uppgift du ännu inte
            placerat.
          </p>
          <input type="hidden" name="person_id" value={person?.id ?? ""} />
          <div className="flex flex-col gap-1.5">
            <Label className="text-xs text-muted-foreground">Person</Label>
            <PersonPicker value={person} onChange={setPerson} placeholder="Sök bland registrerade personer" />
          </div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5">
              <Label className="text-xs text-muted-foreground">Organisation</Label>
              <Select name="organization_id" defaultValue="none">
                <SelectTrigger size="sm">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="none">Ingen</SelectItem>
                  {targetOptions.organizations.map((o) => (
                    <SelectItem key={o.id} value={o.id}>
                      {o.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col gap-1.5">
              <Label className="text-xs text-muted-foreground">Ärende</Label>
              <Select name="case_id" defaultValue="none">
                <SelectTrigger size="sm">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="none">Inget</SelectItem>
                  {targetOptions.cases.map((c) => (
                    <SelectItem key={c.id} value={c.id}>
                      {c.title}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          </div>
        </div>
      ) : (
        <>
          {target.personId ? <input type="hidden" name="person_id" value={target.personId} /> : null}
          {target.organizationId ? (
            <input type="hidden" name="organization_id" value={target.organizationId} />
          ) : null}
          {target.caseId ? <input type="hidden" name="case_id" value={target.caseId} /> : null}
        </>
      )}

      <Textarea
        name="body"
        required
        rows={3}
        maxLength={10000}
        placeholder="Vad såg, hörde eller fick du veta? Var konkret: tid, plats, registreringsnummer, vilka fler som var där."
        aria-label="Uppgift"
        autoFocus={Boolean(targetOptions)}
      />

      <div className="grid gap-3 sm:grid-cols-3">
        <div className="flex flex-col gap-1.5">
          <Label className="text-xs text-muted-foreground">Källa</Label>
          <Select name="source" defaultValue="none">
            <SelectTrigger size="sm">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="none">Ej angiven</SelectItem>
              {NOTE_SOURCES.map((s) => (
                <SelectItem key={s} value={s}>
                  {NOTE_SOURCE_LABELS[s]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label className="text-xs text-muted-foreground">Tillförlitlighet</Label>
          <Select name="confidence" defaultValue="medium">
            <SelectTrigger size="sm">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {CONFIDENCES.map((c) => (
                <SelectItem key={c} value={c}>
                  {CONFIDENCE_LABELS[c]}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="flex flex-col gap-1.5">
          <Label className="text-xs text-muted-foreground">Taggar</Label>
          <Input name="tags" list={listId} placeholder="narkotika, vapen, tips" className="h-8" />
          <datalist id={listId}>
            {tagSuggestions.map((t) => (
              <option key={t} value={t} />
            ))}
          </datalist>
        </div>
      </div>

      <div className="flex items-center justify-between gap-3">
        {state.error ? (
          <p role="alert" className="text-sm text-destructive">
            {state.error}
          </p>
        ) : (
          <span />
        )}
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : <NotebookPenIcon />}
          {submitLabel}
        </Button>
      </div>
    </form>
  )
}
