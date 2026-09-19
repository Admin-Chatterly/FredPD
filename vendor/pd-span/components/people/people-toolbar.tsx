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
import { PERSON_STATUSES, PERSON_STATUS_LABELS } from "@/lib/constants"

const SORT_LABELS: Record<string, string> = {
  updated: "Senast ändrade",
  added: "Senast tillagda",
  name: "Namn",
  last_note: "Senaste uppgiften",
}

type Props = { q: string; status: string; sort: string; tag: string }

export function PeopleToolbar({ q, status, sort, tag }: Props) {
  const router = useRouter()
  const [term, setTerm] = useState(q)
  const [pending, startTransition] = useTransition()
  const timer = useRef<number | undefined>(undefined)

  function navigate(next: Partial<Props>) {
    const values = { q: term, status, sort, tag, ...next }
    const params = new URLSearchParams()
    if (values.q.trim()) params.set("q", values.q.trim())
    if (values.status) params.set("status", values.status)
    if (values.sort && values.sort !== "updated") params.set("sort", values.sort)
    // Satt från en tagg någon annanstans i appen; behåll den vid varje ändring.
    if (values.tag) params.set("tag", values.tag)
    const qs = params.toString()
    startTransition(() => router.replace(qs ? `/people?${qs}` : "/people"))
  }

  function onTermChange(value: string) {
    setTerm(value)
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => navigate({ q: value }), 300)
  }

  return (
    <div className="flex flex-col gap-2 sm:flex-row sm:items-center">
      <div className="relative flex-1">
        <SearchIcon className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
        <Input
          value={term}
          onChange={(e) => onTermChange(e.target.value)}
          placeholder="Sök namn, alias, signalement eller regnr"
          className="pl-8 pr-8"
          aria-label="Sök personer"
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
      <Select value={status || "all"} onValueChange={(v) => navigate({ status: v === "all" ? "" : v })}>
        <SelectTrigger className="sm:w-48" aria-label="Filtrera på status">
          <SelectValue placeholder="Alla statusar" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="all">Alla statusar</SelectItem>
          {PERSON_STATUSES.map((s) => (
            <SelectItem key={s} value={s}>
              {PERSON_STATUS_LABELS[s]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Select value={sort} onValueChange={(v) => navigate({ sort: v })}>
        <SelectTrigger className="sm:w-44" aria-label="Sortering">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {Object.entries(SORT_LABELS).map(([value, label]) => (
            <SelectItem key={value} value={value}>
              {label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
