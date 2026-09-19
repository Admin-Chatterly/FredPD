"use client"

import { useEffect, useRef, useState, useTransition } from "react"
import { useRouter } from "next/navigation"
import {
  BriefcaseIcon,
  BuildingIcon,
  CarIcon,
  LoaderCircleIcon,
  NotebookPenIcon,
  SearchIcon,
  UserIcon,
} from "lucide-react"
import { globalSearch, type SearchHit } from "@/app/(app)/search/actions"
import { Button } from "@/components/ui/button"
import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command"
import { SEARCH_KIND_LABELS, groupHits, searchHitHref } from "@/lib/search"
import { truncate } from "@/lib/format"

const KIND_ICONS: Record<string, typeof UserIcon> = {
  person: UserIcon,
  organization: BuildingIcon,
  vehicle: CarIcon,
  note: NotebookPenIcon,
  case: BriefcaseIcon,
}

/**
 * Ett fält över allt: namn, alias, signalement, registreringsnummer,
 * territorium, anteckningstext och taggar. Öppnas med ctrl+K eller cmd+K
 * eftersom den används mitt i passet.
 */
export function GlobalSearch() {
  const router = useRouter()
  const [open, setOpen] = useState(false)
  const [term, setTerm] = useState("")
  const [hits, setHits] = useState<SearchHit[]>([])
  const [pending, startTransition] = useTransition()
  const latest = useRef(0)

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key.toLowerCase() === "k" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        setOpen((previous) => !previous)
      }
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [])

  useEffect(() => {
    if (!open) return
    const requestId = ++latest.current
    const handle = window.setTimeout(() => {
      startTransition(async () => {
        const results = await globalSearch(term)
        // Ignore a slow response that a newer keystroke has overtaken.
        if (requestId === latest.current) setHits(results)
      })
    }, 200)
    return () => window.clearTimeout(handle)
  }, [term, open])

  function go(hit: SearchHit) {
    setOpen(false)
    router.push(searchHitHref(hit, term))
  }

  const groups = groupHits(hits)
  const short = term.trim().length < 2

  return (
    <>
      <Button
        variant="outline"
        size="sm"
        onClick={() => setOpen(true)}
        className="gap-2 text-muted-foreground"
        title="Sök i allt (ctrl+K)"
      >
        <SearchIcon />
        <span className="hidden lg:inline">Sök</span>
        <kbd className="hidden rounded border border-border px-1 font-mono text-[10px] lg:inline">
          ⌘K
        </kbd>
      </Button>

      <CommandDialog
        open={open}
        onOpenChange={setOpen}
        title="Sök"
        description="Sök bland personer, fordon, organisationer, underrättelser och ärenden"
        // Databasen har redan rangordnat och begränsat träffarna; om cmdk
        // filtrerade om dem mot råtexten skulle den dölja träffar den inte ser,
        // som ett registreringsnummer som hittats via sin normaliserade form.
        commandProps={{ shouldFilter: false }}
      >
        <CommandInput
          value={term}
          onValueChange={setTerm}
          placeholder="Namn, alias, signalement, regnr, tagg…"
        />
        <CommandList>
          {short ? (
            <CommandEmpty>Skriv minst två tecken.</CommandEmpty>
          ) : pending && groups.length === 0 ? (
            <div className="flex items-center justify-center py-6 text-muted-foreground">
              <LoaderCircleIcon className="size-4 animate-spin" />
            </div>
          ) : (
            <CommandEmpty>Inget matchar det.</CommandEmpty>
          )}
          {groups.map((group) => {
            const Icon = KIND_ICONS[group.kind] ?? SearchIcon
            return (
              <CommandGroup key={group.kind} heading={SEARCH_KIND_LABELS[group.kind] ?? group.kind}>
                {group.hits.map((hit) => (
                  <CommandItem
                    key={`${hit.kind}:${hit.id}`}
                    value={`${hit.kind}:${hit.id}`}
                    onSelect={() => go(hit)}
                    className="gap-2"
                  >
                    <Icon className="size-4 shrink-0 text-muted-foreground" />
                    <div className="flex min-w-0 flex-col">
                      <span className="truncate">{truncate(hit.title, 70)}</span>
                      {hit.subtitle ? (
                        <span className="truncate text-xs text-muted-foreground">
                          {truncate(hit.subtitle, 80)}
                        </span>
                      ) : null}
                    </div>
                  </CommandItem>
                ))}
              </CommandGroup>
            )
          })}
        </CommandList>
      </CommandDialog>
    </>
  )
}
