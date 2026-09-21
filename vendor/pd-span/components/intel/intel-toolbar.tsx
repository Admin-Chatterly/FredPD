"use client"

import { useRef, useState, useTransition } from "react"
import { useRouter } from "next/navigation"
import { LoaderCircleIcon, SearchIcon, XIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  CONFIDENCES,
  CONFIDENCE_LABELS,
  NOTE_SOURCES,
  NOTE_SOURCE_LABELS,
} from "@/lib/constants"
import { NOTE_ATTACHMENTS, NOTE_ATTACHMENT_LABELS } from "@/lib/data/notes"
import { intelHref, type IntelFilters } from "@/lib/intel"

export function IntelToolbar(filters: IntelFilters) {
  const router = useRouter()
  const [term, setTerm] = useState(filters.q)
  const [pending, startTransition] = useTransition()
  const timer = useRef<number | undefined>(undefined)

  function navigate(next: Partial<IntelFilters>) {
    const merged = { ...filters, q: term, ...next }
    startTransition(() => router.replace(intelHref(merged)))
  }

  function onTermChange(value: string) {
    setTerm(value)
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => navigate({ q: value }), 300)
  }

  return (
    <div className="flex flex-col gap-2 lg:flex-row lg:items-center">
      <div className="relative flex-1">
        <SearchIcon className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          value={term}
          onChange={(e) => onTermChange(e.target.value)}
          placeholder="Sök i underrättelseloggen"
          className="pl-8 pr-8"
          aria-label="Sök uppgifter"
        />
        {pending ? (
          <LoaderCircleIcon className="absolute top-1/2 right-2.5 size-4 -translate-y-1/2 animate-spin text-muted-foreground" />
        ) : term ? (
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="absolute top-1/2 right-0.5 size-8 -translate-y-1/2"
            onClick={() => onTermChange("")}
            aria-label="Rensa sökningen"
          >
            <XIcon />
          </Button>
        ) : null}
      </div>

      <Select
        value={filters.source || "all"}
        onValueChange={(v) => navigate({ source: v === "all" ? "" : v })}
      >
        <SelectTrigger className="lg:w-44" aria-label="Filtrera på källa">
          <SelectValue placeholder="Alla källor" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">Alla källor</SelectItem>
          {NOTE_SOURCES.map((s) => (
            <SelectItem key={s} value={s}>
              {NOTE_SOURCE_LABELS[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select
        value={filters.confidence || "all"}
        onValueChange={(v) => navigate({ confidence: v === "all" ? "" : v })}
      >
        <SelectTrigger className="lg:w-44" aria-label="Filtrera på tillförlitlighet">
          <SelectValue placeholder="All tillförlitlighet" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">All tillförlitlighet</SelectItem>
          {CONFIDENCES.map((c) => (
            <SelectItem key={c} value={c}>
              {CONFIDENCE_LABELS[c]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>

      <Select
        value={filters.attachment || "any"}
        onValueChange={(v) => navigate({ attachment: v })}
      >
        <SelectTrigger className="lg:w-52" aria-label="Filtrera på bilaga">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {NOTE_ATTACHMENTS.map((a) => (
            <SelectItem key={a} value={a}>
              {NOTE_ATTACHMENT_LABELS[a]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
