import Link from "next/link"
import { Trash2Icon } from "lucide-react"
import { deleteNote } from "@/app/(app)/notes/actions"
import { ActionButton } from "@/components/action-button"
import { ConfidenceBadge, TagBadge } from "@/components/badges"
import { RelativeTime } from "@/components/relative-time"
import { Badge } from "@/components/ui/badge"
import { NOTE_SOURCE_LABELS, NOTE_SOURCES, type NoteSource } from "@/lib/constants"
import type { NoteRow } from "@/lib/data/notes"
import { personLabel } from "@/lib/format"

export type NotesTarget = { personId?: string; organizationId?: string; caseId?: string }

function sourceLabel(source: string | null): string | null {
  if (!source) return null
  return (NOTE_SOURCES as readonly string[]).includes(source)
    ? NOTE_SOURCE_LABELS[source as NoteSource]
    : source
}

/**
 * Flödet av uppgifter, nyast först. Varje uppgift länkar till de andra poster
 * den är kopplad till, utom den sida den redan visas på.
 */
export function NoteList({
  notes,
  target = {},
  emptyText = "Inget loggat ännu.",
}: {
  notes: NoteRow[]
  target?: NotesTarget
  emptyText?: string
}) {
  if (notes.length === 0) {
    return <p className="py-4 text-center text-sm text-muted-foreground">{emptyText}</p>
  }

  return (
    <ol className="flex flex-col divide-y divide-border/60">
      {notes.map((note) => {
        const related: { href: string; label: string }[] = []
        if (note.person && note.person.id !== target.personId) {
          related.push({ href: `/people/${note.person.id}`, label: personLabel(note.person) })
        }
        if (note.organization && note.organization.id !== target.organizationId) {
          related.push({
            href: `/organizations/${note.organization.id}`,
            label: note.organization.name,
          })
        }
        if (note.case && note.case.id !== target.caseId) {
          related.push({ href: `/cases/${note.case.id}`, label: note.case.title })
        }
        const unattached = !note.person_id && !note.organization_id && !note.case_id

        return (
          <li key={note.id} className="flex flex-col gap-2 py-3">
            <p className="whitespace-pre-wrap text-sm leading-relaxed">{note.body}</p>
            <div className="flex flex-wrap items-center gap-1.5">
              <ConfidenceBadge confidence={note.confidence} />
              {sourceLabel(note.source) ? (
                <Badge variant="outline">{sourceLabel(note.source)}</Badge>
              ) : null}
              {unattached ? (
                <Badge variant="outline" className="border-dashed border-amber-500/50 text-amber-300">
                  Allmän uppgift
                </Badge>
              ) : null}
              {note.tags.map((t) => (
                <TagBadge key={t} tag={t} />
              ))}
            </div>
            <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
              <span className="flex flex-wrap items-center gap-x-2">
                <span>{note.author?.callsign ?? "okänd kollega"}</span>
                <span>·</span>
                <RelativeTime iso={note.created_at} />
                {related.map((r) => (
                  <span key={r.href} className="flex items-center gap-x-2">
                    <span>·</span>
                    <Link href={r.href} className="hover:underline">
                      {r.label}
                    </Link>
                  </span>
                ))}
              </span>
              <ActionButton
                action={deleteNote.bind(null, note.id)}
                variant="ghost"
                size="xs"
                className="text-muted-foreground hover:text-destructive"
                confirm={{
                  title: "Ta bort uppgiften?",
                  description: "Den försvinner för alla. Det går inte att ångra.",
                  actionLabel: "Ta bort",
                  destructive: true,
                }}
                successMessage="Uppgiften borttagen"
              >
                <Trash2Icon />
                Ta bort
              </ActionButton>
            </div>
          </li>
        )
      })}
    </ol>
  )
}
