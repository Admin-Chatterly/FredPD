import Link from "next/link"
import { ActiveTagFilter } from "@/components/active-tag-filter"
import { OrganizationStatusBadge, OrganizationTypeBadge } from "@/components/badges"
import { NewOrganizationDialog } from "@/components/organizations/new-organization-dialog"
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
import { listOrganizations } from "@/lib/data/organizations"
import { createClient } from "@/lib/supabase/server"

export const metadata = { title: "Organisationer" }

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? (value[0] ?? "") : (value ?? "")
}

export default async function OrganizationsPage(props: PageProps<"/organizations">) {
  const searchParams = await props.searchParams
  const tag = first(searchParams.tag).toLowerCase()

  const supabase = await createClient()
  const result = await listOrganizations(supabase, { tag: tag || undefined })

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Organisationer</h1>
          {result.ok ? (
            <p className="text-sm text-muted-foreground">
              {result.organizations.length} {tag ? "taggade" : "registrerade"}
            </p>
          ) : null}
        </div>
        <NewOrganizationDialog />
      </div>

      {tag ? <ActiveTagFilter tag={tag} clearHref="/organizations" /> : null}

      {!result.ok ? (
        <SetupHelp error={result.error} />
      ) : result.organizations.length === 0 ? (
        <div className="rounded-lg border border-dashed border-border py-16 text-center text-sm text-muted-foreground">
          {tag
            ? "Ingen organisation har uppgifter med den taggen."
            : "Inga organisationer ännu. Lägg upp de gäng och ligor ni följer, och lägg sedan till medlemmar från endera hållet."}
        </div>
      ) : (
        <div className="overflow-x-auto rounded-lg border border-border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead className="min-w-48">Organisation</TableHead>
                <TableHead>Territorium</TableHead>
                <TableHead>Medlemmar</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Senaste uppgiften</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {result.organizations.map((o) => (
                <TableRow key={o.id}>
                  <TableCell>
                    <div className="flex flex-wrap items-center gap-2">
                      <Link href={`/organizations/${o.id}`} className="font-medium hover:underline">
                        {o.name}
                      </Link>
                      <OrganizationTypeBadge type={o.type} />
                    </div>
                  </TableCell>
                  <TableCell className="text-sm text-muted-foreground">{o.territory ?? "—"}</TableCell>
                  <TableCell className="text-sm">
                    {o.memberCount}
                    {o.memberCount > 0 ? (
                      <span className="text-muted-foreground"> · {o.confirmedMemberCount} bekräftade</span>
                    ) : null}
                  </TableCell>
                  <TableCell>
                    <OrganizationStatusBadge status={o.status} />
                  </TableCell>
                  <TableCell className="text-right text-sm text-muted-foreground">
                    {o.lastNoteAt ? <RelativeTime iso={o.lastNoteAt} /> : "—"}
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
