"use client"

import { useState, useTransition } from "react"
import { CameraIcon, LoaderCircleIcon, Trash2Icon } from "lucide-react"
import { toast } from "sonner"
import { removePersonPhoto, setPersonPhoto } from "@/app/(app)/people/actions"
import { ImageDropzone } from "@/components/image-dropzone"
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
import { STORAGE_BUCKET } from "@/lib/constants"
import { createClient } from "@/lib/supabase/client"
import { extensionFor } from "@/lib/upload"

/** Laddar upp ett foto direkt till lagringen och pekar sedan posten på det. */
export function PhotoDialog({ personId, hasPhoto }: { personId: string; hasPhoto: boolean }) {
  const [open, setOpen] = useState(false)
  const [file, setFile] = useState<File | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [pending, startTransition] = useTransition()
  const [uploading, setUploading] = useState(false)

  async function upload() {
    setError(null)
    if (!file) {
      setError("Klistra in, släpp eller välj en bild först.")
      return
    }

    setUploading(true)
    try {
      const supabase = createClient()
      const path = `people/${personId}/photo/${crypto.randomUUID()}.${extensionFor(file)}`
      const { error: uploadError } = await supabase.storage
        .from(STORAGE_BUCKET)
        .upload(path, file, { contentType: file.type, upsert: false })
      if (uploadError) {
        setError(uploadError.message)
        return
      }
      startTransition(async () => {
        const result = await setPersonPhoto(personId, path)
        if (!result.ok) {
          setError(result.error)
          return
        }
        toast.success("Fotot uppdaterat")
        setFile(null)
        setOpen(false)
      })
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Uppladdningen misslyckades.")
    } finally {
      setUploading(false)
    }
  }

  function remove() {
    startTransition(async () => {
      const result = await removePersonPhoto(personId)
      if (!result.ok) {
        toast.error(result.error)
        return
      }
      toast.success("Fotot borttaget")
      setOpen(false)
    })
  }

  const busy = uploading || pending

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <CameraIcon /> {hasPhoto ? "Byt foto" : "Lägg till foto"}
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{hasPhoto ? "Byt foto" : "Lägg till foto"}</DialogTitle>
          <DialogDescription>
            Klistra in en skärmbild med win+shift+S, eller släpp en fil. Den hamnar i den privata
            lagringen och visas bara via en kortlivad signerad länk.
          </DialogDescription>
        </DialogHeader>

        <ImageDropzone file={file} onFile={setFile} onError={setError} disabled={busy} />

        {error ? (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        ) : null}

        <DialogFooter className="sm:justify-between">
          {hasPhoto ? (
            <Button
              type="button"
              variant="ghost"
              onClick={remove}
              disabled={busy}
              className="text-destructive hover:text-destructive"
            >
              <Trash2Icon /> Ta bort
            </Button>
          ) : (
            <span />
          )}
          <Button type="button" onClick={upload} disabled={busy || !file}>
            {busy ? <LoaderCircleIcon className="animate-spin" /> : <CameraIcon />}
            {uploading ? "Laddar upp…" : "Spara foto"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
