import type { Metadata } from "next"
import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeftIcon } from "lucide-react"
import { CaseStatusBadge } from "@/components/badges"
import { EvidenceSection } from "@/components/evidence/evidence-section"
import { NotesSection } from "@/components/notes/notes-section"
import { OrganizationDangerZone } from "@/components/organizations/organization-danger-zone"
import { OrganizationIdentityCard } from "@/components/organizations/organization-identity-card"
import { RosterSection } from "@/components/organizations/roster-section"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { getOrganizationDetail } from "@/lib/data/organizations"
import { listTagSuggestions } from "@/lib/data/notes"
import { createClient } from "@/lib/supabase/server"

export async function generateMetadata(props: PageProps<"/organizations/[id]">): Promise<Metadata> {
  const { id } = await props.params
  const supabase = await createClient()
  const detail = await getOrganizationDetail(supabase, id)
  return { title: detail ? detail.organization.name : "Hittades inte" }
}

export default async function OrganizationPage(props: PageProps<"/organizations/[id]">) {
  const { id } = await props.params
  const supabase = await createClient()
  const [detail, tagSuggestions] = await Promise.all([
    getOrganizationDetail(supabase, id),
    listTagSuggestions(supabase),
  ])
  if (!detail) notFound()
  const { organization } = detail

  return (
    <div className="flex flex-col gap-4">
      <Button asChild variant="ghost" size="sm" className="w-fit">
        <Link href="/organizations">
          <ArrowLeftIcon /> Organisationer
        </Link>
      </Button>

      <OrganizationIdentityCard organization={organization} createdBy={detail.createdBy} />

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="flex flex-col gap-4 lg:col-span-2">
          <NotesSection
            target={{ organizationId: organization.id }}
            notes={detail.notes}
            tagSuggestions={tagSuggestions}
            emptyText="Inga underrättelser loggade på den här organisationen än."
          />
        </div>
        <div className="flex flex-col gap-4">
          <RosterSection organizationId={organization.id} members={detail.members} />

          <Card>
            <CardHeader>
              <CardTitle>Ärenden</CardTitle>
            </CardHeader>
            <CardContent>
              {detail.caseLinks.length === 0 ? (
                <p className="text-sm text-muted-foreground">Inte kopplad till något ärende.</p>
              ) : (
                <ul className="flex flex-col divide-y divide-border/60">
                  {detail.caseLinks.map((l) => (
                    <li key={l.id} className="flex items-center justify-between gap-2 py-2">
                      <Link href={`/cases/${l.case.id}`} className="font-medium hover:underline">
                        {l.case.title}
                      </Link>
                      <CaseStatusBadge status={l.case.status} />
                    </li>
                  ))}
                </ul>
              )}
            </CardContent>
          </Card>

          <EvidenceSection target={{ organizationId: organization.id }} items={detail.evidence} />

          <OrganizationDangerZone
            organizationId={organization.id}
            name={organization.name}
            counts={{
              members: detail.members.length,
              notes: detail.notes.length,
              caseLinks: detail.caseLinks.length,
              evidence: detail.evidence.length,
            }}
          />
        </div>
      </div>
    </div>
  )
}
