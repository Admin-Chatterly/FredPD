"use client"

import { useEffect, useRef, useState, useTransition } from "react"
import { LoaderCircleIcon, XIcon } from "lucide-react"
import { searchPeopleAction } from "@/app/(app)/people/actions"
import { PersonStatusBadge, UnknownBadge } from "@/components/badges"
import { Button } from "@/components/ui/button"
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import type { PersonPick } from "@/lib/data/people"
import { isUnidentified, personLabel, personSecondary, truncate } from "@/lib/format"

type Props = {
  value: PersonPick | null
  onChange: (person: PersonPick | null) => void
  excludeIds?: string[]
  placeholder?: string
}

/** Sök och välj en person direkt. Träffarna kommer från en server-action. */
export function PersonPicker({ value, onChange, excludeIds = [], placeholder }: Props) {
  const [term, setTerm] = useState("")
  const [results, setResults] = useState<PersonPick[]>([])
  const [pending, startTransition] = useTransition()
  const excludeKey = excludeIds.join(",")
  const latest = useRef(0)

  useEffect(() => {
    const requestId = ++latest.current
    const handle = window.setTimeout(() => {
      startTransition(async () => {
        const rows = await searchPeopleAction(term, excludeKey ? excludeKey.split(",") : [])
        if (requestId === latest.current) setResults(rows)
      })
    }, 200)
    return () => window.clearTimeout(handle)
  }, [term, excludeKey])

  if (value) {
    const secondary = personSecondary(value)
    return (
      <div className="flex items-center justify-between gap-2 rounded-md border border-border px-3 py-2">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium">{personLabel(value)}</span>
            {isUnidentified(value) ? <UnknownBadge /> : null}
            <PersonStatusBadge status={value.status} />
          </div>
          {secondary ? (
            <p className="truncate text-xs text-muted-foreground">{truncate(secondary, 90)}</p>
          ) : null}
        </div>
        <Button type="button" variant="ghost" size="icon-sm" onClick={() => onChange(null)} aria-label="Rensa">
          <XIcon />
        </Button>
      </div>
    )
  }

  return (
    <Command shouldFilter={false} className="rounded-md border border-border">
      <CommandInput
        value={term}
        onValueChange={setTerm}
        placeholder={placeholder ?? "Sök på namn, alias eller signalement"}
      />
      <CommandList className="max-h-56">
        {pending && results.length === 0 ? (
          <div className="flex items-center justify-center py-4 text-muted-foreground">
            <LoaderCircleIcon className="size-4 animate-spin" />
          </div>
        ) : null}
        <CommandEmpty>Ingen hittades.</CommandEmpty>
        <CommandGroup>
          {results.map((p) => {
            const secondary = personSecondary(p)
            return (
              <CommandItem key={p.id} value={p.id} onSelect={() => onChange(p)} className="flex flex-col items-start gap-0.5">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-medium">{personLabel(p)}</span>
                  {isUnidentified(p) ? <UnknownBadge /> : null}
                </div>
                {secondary ? (
                  <span className="text-xs text-muted-foreground">{truncate(secondary, 90)}</span>
                ) : null}
              </CommandItem>
            )
          })}
        </CommandGroup>
      </CommandList>
    </Command>
  )
}
