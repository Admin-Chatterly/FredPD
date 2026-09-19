"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { ClipboardPasteIcon, ImageIcon, XIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { ACCEPTED_IMAGE_TYPES, formatBytes, validateImage } from "@/lib/upload"
import { cn } from "@/lib/utils"

/**
 * Skärmbilder är hur de här uppgifterna faktiskt kommer in, så ingen ska behöva
 * spara ner en fil först. Tar emot inklistring från urklipp, en släppt fil eller
 * filväljaren.
 */
export function ImageDropzone({
  file,
  onFile,
  onError,
  disabled = false,
}: {
  file: File | null
  onFile: (file: File | null) => void
  onError: (message: string | null) => void
  disabled?: boolean
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [dragging, setDragging] = useState(false)

  const preview = useMemo(() => (file ? URL.createObjectURL(file) : null), [file])

  useEffect(() => {
    // An object URL is held by the browser until it is revoked, so each one is
    // released when the selection changes or the dialog closes.
    if (!preview) return
    return () => URL.revokeObjectURL(preview)
  }, [preview])

  const accept = useCallback(
    (candidate: File | null | undefined) => {
      if (!candidate) return
      const problem = validateImage(candidate)
      if (problem) {
        onError(problem)
        return
      }
      onError(null)
      onFile(candidate)
    },
    [onFile, onError]
  )

  useEffect(() => {
    if (disabled) return
    function onPaste(event: ClipboardEvent) {
      const image = Array.from(event.clipboardData?.files ?? []).find((f) =>
        f.type.startsWith("image/")
      )
      if (!image) return
      event.preventDefault()
      accept(image)
    }
    // The listener lives on the document because a paste lands wherever focus
    // happens to be, which is rarely the dropzone itself.
    document.addEventListener("paste", onPaste)
    return () => document.removeEventListener("paste", onPaste)
  }, [accept, disabled])

  return (
    <div className="flex flex-col gap-2">
      <div
        onDragOver={(e) => {
          if (disabled) return
          e.preventDefault()
          setDragging(true)
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={(e) => {
          if (disabled) return
          e.preventDefault()
          setDragging(false)
          accept(Array.from(e.dataTransfer.files).find((f) => f.type.startsWith("image/")))
        }}
        className={cn(
          "relative flex min-h-32 flex-col items-center justify-center gap-2 rounded-md border-2 border-dashed border-border p-4 text-center transition-colors",
          dragging && "border-primary bg-primary/10",
          disabled && "opacity-60"
        )}
      >
        {preview ? (
          <>
            {/* A local object URL for the file being uploaded. */}
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={preview} alt="" className="max-h-40 rounded object-contain" />
            <p className="text-xs text-muted-foreground">
              {file?.name} · {file ? formatBytes(file.size) : ""}
            </p>
            <Button
              type="button"
              variant="ghost"
              size="xs"
              onClick={() => {
                onFile(null)
                onError(null)
                if (inputRef.current) inputRef.current.value = ""
              }}
              disabled={disabled}
            >
              <XIcon /> Välj en annan
            </Button>
          </>
        ) : (
          <>
            <ImageIcon className="size-6 text-muted-foreground" />
            <p className="text-sm">
              <span className="inline-flex items-center gap-1 font-medium">
                <ClipboardPasteIcon className="size-3.5" /> Klistra in en skärmbild
              </span>{" "}
              <span className="text-muted-foreground">
                med ctrl+V, släpp en bild här, eller
              </span>
            </p>
            <Button
              type="button"
              variant="secondary"
              size="sm"
              onClick={() => inputRef.current?.click()}
              disabled={disabled}
            >
              Välj en fil
            </Button>
            <p className="text-xs text-muted-foreground">JPEG, PNG, WebP eller GIF, upp till 10 MB</p>
          </>
        )}

        <input
          ref={inputRef}
          type="file"
          accept={ACCEPTED_IMAGE_TYPES.join(",")}
          className="sr-only"
          disabled={disabled}
          onChange={(e) => accept(e.target.files?.[0])}
        />
      </div>
    </div>
  )
}
