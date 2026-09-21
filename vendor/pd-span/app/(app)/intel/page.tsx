import Link from "next/link"
import { IntelToolbar } from "@/components/intel/intel-toolbar"
import { TagBar } from "@/components/intel/tag-bar"
import { NoteComposer } from "@/components/notes/note-composer"
import { NoteList } from "@/components/notes/note-list"
import { SetupHelp } from "@/components/setup-help"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { CONFIDENCES, NOTE_SOURCES } from "@/lib/constants"
import {
  listNoteTargets,
  listNotes,
  listTags,
  NOTE_ATTACHMENTS,
  type NoteAttachment,
} from "@/lib/data/notes"
import type { IntelFilters } from "@/lib/intel"
import { createClient } from "@/lib/supabase/server"

export const metadata = { title: "Underrättelser" }

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? (value[0] ?? "") : (value ?? "")
}

function oneOf<T extends string>(values: readonly T[], value: string): T | "" {
  return (values as readonly string[]).includes(value) ? (value as T) : ""
}

export default async function IntelPage(props: PageProps<"/intel">) {
  const searchParams = await props.searchParams
  const attachmentParam = first(searchParams.attachment)
  const filters: IntelFilters = {
    q: first(searchParams.q),
    tag: first(searchParams.tag).toLowerCase(),
    source: oneOf(NOTE_SOURCES, first(searchParams.source)),
    confidence: oneOf(CONFIDENCES, first(searchParams.confidence)),
    attachment: oneOf(NOTE_ATTACHMENTS, attachmentParam) || "any",
  }

  const supabase = await createClient()
  const [result, tags, targets] = await Promise.all([
    listNotes(supabase, {
      q: filters.q,
      tag: filters.tag || undefined,
      source: filters.source || undefined,
      confidence: filters.confidence || undefined,
      attachment: filters.attachment as NoteAttachment,
    }),
    listTags(supabase),
    listNoteTargets(supabase),
  ])

  const filtered = Boolean(
    filters.q || filters.tag || filters.source || filters.confidence || filters.attachment !== "any"
  )

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Underrättelser</h1>
          {result.ok ? (
            <p className="text-sm text-muted-foreground">
              {result.total} {result.total === 1 ? "uppgift" : "uppgifter"}
              {filtered ? " matchar" : " loggade"}
            </p>
          ) : null}
        </div>
        {filtered ? (
          <Button asChild variant="ghost" size="sm">
            <Link href="/intel">Rensa filter</Link>
          </Button>
        ) : null}
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Logga underrättelse</CardTitle>
        </CardHeader>
        <CardContent>
          <NoteComposer
            tagSuggestions={tags.map((t) => t.tag)}
            targetOptions={targets}
          />
        </CardContent>
      </Card>

      <TagBar tags={tags} filters={filters} />
      <IntelToolbar {...filters} />

      {!result.ok ? (
        <SetupHelp error={result.error} />
      ) : (
        <Card>
          <CardContent>
            <NoteList
              notes={result.notes}
              emptyText={
                filtered
                  ? "Inga underrättelser matchar de filtren."
                  : "Inget loggat än. Allt du hör kan hamna här, även innan du vet vem det handlar om."
              }
            />
          </CardContent>
        </Card>
      )}

      {result.ok && result.total > result.notes.length ? (
        <p className="text-center text-xs text-muted-foreground">
          Visar de {result.notes.length} senaste av {result.total}. Smalna av filtren för att se
          äldre underrättelser.
        </p>
      ) : null}
    </div>
  )
}
