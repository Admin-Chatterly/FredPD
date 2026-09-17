"use client"

import { useActionState } from "react"
import { LoaderCircleIcon, ZapIcon } from "lucide-react"
import { quickAddPerson, type FormState } from "@/app/(app)/people/actions"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"

const initialState: FormState = {}

/** Ett fält, ett klick: öppnar en akt på någon med bara ett signalement. */
export function QuickAddForm() {
  const [state, formAction, pending] = useActionState(quickAddPerson, initialState)

  return (
    <form action={formAction} className="flex flex-col gap-1">
      <div className="flex gap-2">
        <Input
          name="description"
          required
          maxLength={4000}
          placeholder='Snabbregistrera en okänd: "lång, röd rånarluva, kör en svart Sultan, sedd vid gatuhörnet"'
          aria-label="Signalement"
        />
        <Button type="submit" disabled={pending} variant="secondary">
          {pending ? <LoaderCircleIcon className="animate-spin" /> : <ZapIcon />}
          Öppna akt
        </Button>
      </div>
      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}
    </form>
  )
}
