import Link from "next/link"
import { CaseStatusBadge } from "@/components/badges"
import { NewCaseDialog } from "@/components/cases/new-case-dialog"
import { RelativeTime } from "@/components/relative-time"
import { SetupHelp } from "@/components/setup-help"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { listCases } from "@/lib/data/cases"
import { createClient } from "@/lib/supabase/server"

export const metadata = { title: "Ärenden" }

export default async function CasesPage() {
  const supabase = await createClient()
  const result = await listCases(supabase)

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Ärenden</h1>
          {result.ok ? <p className="text-sm text-muted-foreground">{result.cases.length} registrerade</p> : null}
        </div>
        <NewCaseDialog />
      </div>

      {!result.ok ? (
        <SetupHelp error={result.error} />
      ) : result.cases.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border py-16 text-center text-sm text-muted-foreground">
          Inga ärenden än. Öppna ett för att samla personerna och organisationerna i en utredning.
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="min-w-56">Ärende</TableHead>
                <TableHead>Status</TableHead>
                <TableHead>Personer</TableHead>
                <TableHead>Organisationer</TableHead>
                <TableHead className="text-right">Senaste uppgiften</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {result.cases.map((c) => (
                <TableRow key={c.id}>
                  <TableCell>
                    <Link href={`/cases/${c.id}`} className="font-medium hover:underline">
                      {c.title}
                    </Link>
                    {c.description ? (
                      <p className="truncate text-xs text-muted-foreground">{c.description}</p>
                    ) : null}
                  </TableCell>
                  <TableCell>
                    <CaseStatusBadge status={c.status} />
                  </TableCell>
                  <TableCell className="text-sm">{c.peopleCount}</TableCell>
                  <TableCell className="text-sm">{c.organizationCount}</TableCell>
                  <TableCell className="text-right text-sm text-muted-foreground">
                    {c.lastNoteAt ? <RelativeTime iso={c.lastNoteAt} /> : "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  )
}
