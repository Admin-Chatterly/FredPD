import type { Metadata } from "next"
import Link from "next/link"
import { notFound } from "next/navigation"
import { ArrowLeftIcon } from "lucide-react"
import { CaseDangerZone } from "@/components/cases/case-danger-zone"
import { CaseIdentityCard } from "@/components/cases/case-identity-card"
import {
  CaseOrganizationsSection,
  CasePeopleSection,
} from "@/components/cases/case-links-section"
import { EvidenceSection } from "@/components/evidence/evidence-section"
import { NotesSection } from "@/components/notes/notes-section"
import { Button } from "@/components/ui/button"
import { getCaseDetail } from "@/lib/data/cases"
import { listTagSuggestions } from "@/lib/data/notes"
import { createClient } from "@/lib/supabase/server"

export async function generateMetadata(props: PageProps<"/cases/[id]">): Promise<Metadata> {
  const { id } = await props.params
  const supabase = await createClient()
  const detail = await getCaseDetail(supabase, id)
  return { title: detail ? detail.caseRecord.title : "Hittades inte" }
}

export default async function CasePage(props: PageProps<"/cases/[id]">) {
  const { id } = await props.params
  const supabase = await createClient()
  const [detail, tagSuggestions] = await Promise.all([
    getCaseDetail(supabase, id),
    listTagSuggestions(supabase),
  ])
  if (!detail) notFound()
  const { caseRecord } = detail

  return (
    <div className="flex flex-col gap-4">
      <Button asChild variant="ghost" size="sm" className="w-fit">
        <Link href="/cases">
          <ArrowLeftIcon /> Ärenden
        </Link>
      </Button>

      <CaseIdentityCard
        caseRecord={caseRecord}
        createdBy={detail.createdBy}
        counts={{
          people: detail.people.length,
          organizations: detail.organizations.length,
          notes: detail.notes.length,
        }}
      />

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="flex flex-col gap-4 lg:col-span-2">
          <NotesSection
            target={{ caseId: caseRecord.id }}
            notes={detail.notes}
            tagSuggestions={tagSuggestions}
            emptyText="Inga underrättelser loggade på det här ärendet än."
          />
        </div>
        <div className="flex flex-col gap-4">
          <CasePeopleSection caseId={caseRecord.id} links={detail.people} />
          <CaseOrganizationsSection
            caseId={caseRecord.id}
            links={detail.organizations}
            organizationOptions={detail.organizationOptions}
          />
          <EvidenceSection target={{ caseId: caseRecord.id }} items={detail.evidence} />
          <CaseDangerZone
            caseId={caseRecord.id}
            title={caseRecord.title}
            counts={{
              links: detail.people.length + detail.organizations.length,
              notes: detail.notes.length,
            }}
          />
        </div>
      </div>
    </div>
  )
}
