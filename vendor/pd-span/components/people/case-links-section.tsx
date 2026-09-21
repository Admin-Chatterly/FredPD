import Link from "next/link"
import { CaseStatusBadge } from "@/components/badges"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import type { CaseLinkRow } from "@/lib/data/people"

export function CaseLinksSection({ caseLinks }: { caseLinks: CaseLinkRow[] }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Ärenden</CardTitle>
      </CardHeader>
      <CardContent>
        {caseLinks.length === 0 ? (
          <p className="text-sm text-muted-foreground">Inte kopplad till något ärende.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-border/60">
            {caseLinks.map((l) => (
              <li key={l.id} className="flex items-center justify-between gap-2 py-2">
                <div className="flex min-w-0 flex-col">
                  <Link href={`/cases/${l.case.id}`} className="font-medium hover:underline">
                    {l.case.title}
                  </Link>
                  {l.role ? <span className="text-xs text-muted-foreground">{l.role}</span> : null}
                </div>
                <CaseStatusBadge status={l.case.status} />
              </li>
            ))}
          </ul>
        )}
      </CardContent>
    </Card>
  )
}
