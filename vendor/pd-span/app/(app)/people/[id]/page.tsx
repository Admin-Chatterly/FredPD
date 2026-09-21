import type { Metadata } from "next"
import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeftIcon } from "lucide-react"
import { AssociatesSection } from "@/components/people/associates-section"
import { CaseLinksSection } from "@/components/people/case-links-section"
import { DangerZone } from "@/components/people/danger-zone"
import { IdentityCard } from "@/components/people/identity-card"
import { MembershipsSection } from "@/components/people/memberships-section"
import { EvidenceSection } from "@/components/evidence/evidence-section"
import { NotesSection } from "@/components/notes/notes-section"
import { VehiclesSection } from "@/components/people/vehicles-section"
import { Button } from "@/components/ui/button"
import { listTagSuggestions } from "@/lib/data/notes"
import { getPersonDetail } from "@/lib/data/people"
import { personLabel } from "@/lib/format"
import { createClient } from "@/lib/supabase/server"

export async function generateMetadata(props: PageProps<"/people/[id]">): Promise<Metadata> {
  const { id } = await props.params
  const supabase = await createClient()
  const detail = await getPersonDetail(supabase, id)
  return { title: detail ? personLabel(detail.person) : "Hittades inte" }
}

export default async function PersonPage(props: PageProps<"/people/[id]">) {
  const { id } = await props.params
  const supabase = await createClient()
  const [detail, tagSuggestions] = await Promise.all([
    getPersonDetail(supabase, id),
    listTagSuggestions(supabase),
  ])
  if (!detail) notFound()

  const { person } = detail

  return (
    <div className="flex flex-col gap-4">
      <Button asChild variant="ghost" size="sm" className="w-fit">
        <Link href="/people">
          <ArrowLeftIcon /> Personer
        </Link>
      </Button>

      <IdentityCard person={person} createdBy={detail.createdBy} photoUrl={detail.photoUrl} />

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="flex flex-col gap-4 lg:col-span-2">
          <NotesSection
            target={{ personId: person.id }}
            notes={detail.notes}
            tagSuggestions={tagSuggestions}
            emptyText="Inget loggat ännu. Den första uppgiften brukar förklara varför personen finns på tavlan."
          />
        </div>
        <div className="flex flex-col gap-4">
          <MembershipsSection
            personId={person.id}
            memberships={detail.memberships}
            organizationOptions={detail.organizationOptions}
          />
          <AssociatesSection personId={person.id} associates={detail.associates} />
          <VehiclesSection personId={person.id} vehicles={detail.vehicles} />
          <CaseLinksSection caseLinks={detail.caseLinks} />
          <EvidenceSection target={{ personId: person.id }} items={detail.evidence} />
          <DangerZone
            person={person}
            counts={{
              notes: detail.notes.length,
              vehicles: detail.vehicles.length,
              memberships: detail.memberships.length,
              associates: detail.associates.length,
              caseLinks: detail.caseLinks.length,
              evidence: detail.evidence.length,
            }}
          />
        </div>
      </div>
    </div>
  )
}
