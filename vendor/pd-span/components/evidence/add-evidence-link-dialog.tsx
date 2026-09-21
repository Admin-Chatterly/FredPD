"use client"

import { useActionState, useEffect, useState } from "react"
import { LinkIcon, LoaderCircleIcon } from "lucide-react"
import { toast } from "sonner"
import { addEvidenceLink } from "@/app/(app)/evidence/actions"
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
import type { FormState } from "@/lib/action-types"
import type { EvidenceTarget } from "@/lib/data/evidence"

export function AddEvidenceLinkDialog({ target }: { target: EvidenceTarget }) {
  const [open, setOpen] = useState(false)

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <LinkIcon /> Lägg till länk
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Bifoga en länk som bevis</DialogTitle>
          <DialogDescription>
            Klipp från Medal.tv samt videor från YouTube och Streamable spelas upp direkt här.
            Direktlänkar till bilder visar bilden. Allt annat sparas som en länk.
          </DialogDescription>
        </DialogHeader>
        <LinkForm target={target} onSaved={() => setOpen(false)} />
      </DialogContent>
    </Dialog>
  )
}

function LinkForm({ target, onSaved }: { target: EvidenceTarget; onSaved: () => void }) {
  const [state, formAction, pending] = useActionState(addEvidenceLink, {} as FormState)

  useEffect(() => {
    if (state.ok) {
      toast.success("Beviset tillagt")
      onSaved()
    }
  }, [state, onSaved])

  return (
    <form action={formAction} className="flex flex-col gap-4">
      {target.personId ? <input type="hidden" name="person_id" value={target.personId} /> : null}
      {target.organizationId ? (
        <input type="hidden" name="organization_id" value={target.organizationId} />
      ) : null}
      {target.caseId ? <input type="hidden" name="case_id" value={target.caseId} /> : null}
      <div className="flex flex-col gap-2">
        <Label htmlFor="evidence_url">Länk</Label>
        <Input
          id="evidence_url"
          name="url"
          type="url"
          required
          inputMode="url"
          placeholder="https://medal.tv/games/gta-v/clips/…"
          autoFocus
        />
      </div>
      <div className="flex flex-col gap-2">
        <Label htmlFor="evidence_caption">Bildtext</Label>
        <Input
          id="evidence_caption"
          name="caption"
          maxLength={500}
          placeholder="Vad det visar, när, var"
        />
      </div>
      {state.error ? (
        <p role="alert" className="text-sm text-destructive">
          {state.error}
        </p>
      ) : null}
      <DialogFooter>
        <Button type="submit" disabled={pending}>
          {pending ? <LoaderCircleIcon className="animate-spin" /> : null}
          Bifoga
        </Button>
      </DialogFooter>
    </form>
  )
}
