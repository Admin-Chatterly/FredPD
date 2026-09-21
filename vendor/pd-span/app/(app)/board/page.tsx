import Link from "next/link"
import { BoardGraphView } from "@/components/board/board-graph"
import { BoardLegend } from "@/components/board/board-legend"
import { BoardScopePicker } from "@/components/board/board-scope-picker"
import { SetupHelp } from "@/components/setup-help"
import { Button } from "@/components/ui/button"
import { getBoardGraph, listBoardScopes, type BoardScope } from "@/lib/data/board"
import { isUuid } from "@/lib/data/filters"
import { createClient } from "@/lib/supabase/server"

export const metadata = { title: "Tavlan" }

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? (value[0] ?? "") : (value ?? "")
}

/** `case:<uuid>` or `organization:<uuid>`; anything else falls back to everyone. */
function parseScope(raw: string): BoardScope {
  const [kind, id] = raw.split(":")
  if ((kind === "case" || kind === "organization") && id && isUuid(id)) {
    return { kind, id }
  }
  return { kind: "all" }
}

export default async function BoardPage(props: PageProps<"/board">) {
  const searchParams = await props.searchParams
  const raw = first(searchParams.scope)
  const scope = parseScope(raw)
  const value = scope.kind === "all" ? "all" : `${scope.kind}:${scope.id}`

  const supabase = await createClient()
  const [result, options] = await Promise.all([
    getBoardGraph(supabase, scope),
    listBoardScopes(supabase),
  ])

  const nodeCount = result.ok ? result.graph.people.length + result.graph.organizations.length : 0
  const edgeCount = result.ok ? result.graph.memberships.length + result.graph.associates.length : 0

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Tavlan</h1>
          <p className="text-sm text-muted-foreground">
            {result.ok
              ? `${nodeCount} ${nodeCount === 1 ? "nod" : "noder"}, ${edgeCount} ${edgeCount === 1 ? "koppling" : "kopplingar"}. Klicka på något för att öppna dess akt.`
              : "Grafen kunde inte laddas."}
          </p>
        </div>
        <BoardScopePicker value={value} options={options} />
      </div>

      {!result.ok ? (
        <SetupHelp error={result.error} />
      ) : nodeCount === 0 ? (
        <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-border py-24 text-center">
          <p className="max-w-md text-sm text-muted-foreground">
            {scope.kind === "all"
              ? "Inget att rita upp än. Tavlan ritar personer och organisationer så snart de knyts ihop av medlemskap eller kontakter."
              : "Ingenting är kopplat till det här än. Lägg till medlemmar eller koppla personer till ärendet, så dyker de upp här."}
          </p>
          <Button asChild variant="secondary" size="sm">
            <Link href="/people">Öppna personer</Link>
          </Button>
        </div>
      ) : (
        <>
          <BoardLegend />
          {/* Remounting on a scope change resets the layout to the new graph. */}
          <BoardGraphView key={value} graph={result.graph} />
          {result.graph.truncated ? (
            <p className="text-center text-xs text-muted-foreground">
              Visar de {result.graph.people.length} senast uppdaterade personerna. Välj ett ärende
              eller en organisation för att se en läsbar del.
            </p>
          ) : null}
        </>
      )}
    </div>
  )
}
