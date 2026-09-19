import Link from "next/link"
import { PlusIcon } from "lucide-react"
import { ActiveTagFilter } from "@/components/active-tag-filter"
import { PeopleTable } from "@/components/people/people-table"
import { PeopleToolbar } from "@/components/people/people-toolbar"
import { QuickAddForm } from "@/components/people/quick-add-form"
import { SetupHelp } from "@/components/setup-help"
import { Button } from "@/components/ui/button"
import { PERSON_STATUSES } from "@/lib/constants"
import { listPeople, PEOPLE_SORTS, type PeopleSort } from "@/lib/data/people"
import { createClient } from "@/lib/supabase/server"

export const metadata = { title: "Personer" }

function first(value: string | string[] | undefined): string {
  return Array.isArray(value) ? (value[0] ?? "") : (value ?? "")
}

export default async function PeoplePage(props: PageProps<"/people">) {
  const searchParams = await props.searchParams
  const q = first(searchParams.q)
  const statusParam = first(searchParams.status)
  const status = (PERSON_STATUSES as readonly string[]).includes(statusParam) ? statusParam : ""
  const sortParam = first(searchParams.sort)
  const sort: PeopleSort = (PEOPLE_SORTS as readonly string[]).includes(sortParam)
    ? (sortParam as PeopleSort)
    : "updated"

  const tag = first(searchParams.tag).toLowerCase()

  const supabase = await createClient()
  const result = await listPeople(supabase, {
    q,
    status: status || undefined,
    sort,
    tag: tag || undefined,
  })
  const filtered = Boolean(q || status || tag)

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Personer</h1>
          {result.ok ? (
            <p className="text-sm text-muted-foreground">
              {result.total} registrerade{filtered ? ", filtrerat" : ""}
            </p>
          ) : null}
        </div>
        <Button asChild>
          <Link href="/people/new">
            <PlusIcon /> Ny person
          </Link>
        </Button>
      </div>

      <QuickAddForm />
      <PeopleToolbar q={q} status={status} sort={sort} tag={tag} />
      {tag ? <ActiveTagFilter tag={tag} clearHref="/people" /> : null}

      {result.ok ? (
        <PeopleTable people={result.people} filtered={filtered} />
      ) : (
        <SetupHelp error={result.error} />
      )}
    </div>
  )
}
