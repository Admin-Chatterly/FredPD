import { isUuid, uuidList } from "@/lib/data/filters"
import type { Client } from "@/lib/supabase/types"

/**
 * A graph of everyone on the board is unreadable on a busy server, so the board
 * is scoped: one case, one organization, or deliberately everything.
 */
export type BoardScope =
  | { kind: "all" }
  | { kind: "case"; id: string }
  | { kind: "organization"; id: string }

export type BoardPerson = {
  id: string
  name: string | null
  alias: string | null
  description: string | null
  status: string
}

export type BoardOrganization = {
  id: string
  name: string
  type: string | null
  status: string
}

export type BoardMembership = {
  personId: string
  organizationId: string
  role: string | null
  isConfirmed: boolean
}

export type BoardAssociate = {
  personId: string
  associateId: string
  relationship: string | null
  isConfirmed: boolean
}

export type BoardGraph = {
  people: BoardPerson[]
  organizations: BoardOrganization[]
  memberships: BoardMembership[]
  associates: BoardAssociate[]
  /** True when the cap was hit and the graph is only part of the picture. */
  truncated: boolean
}

export type BoardGraphResult = { ok: true; graph: BoardGraph } | { ok: false; error: string }

const PERSON_CAP = 300
const EMPTY: BoardGraph = {
  people: [],
  organizations: [],
  memberships: [],
  associates: [],
  truncated: false,
}

const PERSON_COLUMNS = "id, name, alias, description, status"
const ORGANIZATION_COLUMNS = "id, name, type, status"

export type BoardScopeOptions = {
  cases: { id: string; title: string; status: string }[]
  organizations: { id: string; name: string }[]
}

export async function listBoardScopes(supabase: Client): Promise<BoardScopeOptions> {
  const [cases, organizations] = await Promise.all([
    supabase
      .from("cases")
      .select("id, title, status")
      .order("status")
      .order("updated_at", { ascending: false })
      .limit(200),
    supabase.from("organizations").select("id, name").order("name").limit(200),
  ])
  return { cases: cases.data ?? [], organizations: organizations.data ?? [] }
}

/**
 * Edges are only drawn between nodes that are on the board, so the graph never
 * points at something the officer cannot see.
 */
async function edgesWithin(
  supabase: Client,
  personIds: string[],
  organizationIds: string[]
): Promise<{ memberships: BoardMembership[]; associates: BoardAssociate[]; error?: string }> {
  if (personIds.length === 0) return { memberships: [], associates: [] }

  const [memberships, associates] = await Promise.all([
    organizationIds.length > 0
      ? supabase
          .from("memberships")
          .select("person_id, organization_id, role, is_confirmed")
          .in("person_id", personIds)
          .in("organization_id", organizationIds)
      : Promise.resolve({ data: [], error: null }),
    supabase
      .from("associates")
      .select("person_id, associate_id, relationship, is_confirmed")
      .in("person_id", personIds)
      .in("associate_id", personIds),
  ])

  const failure = [memberships, associates].find((r) => r.error)
  if (failure?.error) return { memberships: [], associates: [], error: failure.error.message }

  return {
    memberships: (memberships.data ?? []).map((m) => ({
      personId: m.person_id,
      organizationId: m.organization_id,
      role: m.role,
      isConfirmed: m.is_confirmed,
    })),
    associates: (associates.data ?? []).map((a) => ({
      personId: a.person_id,
      associateId: a.associate_id,
      relationship: a.relationship,
      isConfirmed: a.is_confirmed,
    })),
  }
}

export async function getBoardGraph(
  supabase: Client,
  scope: BoardScope
): Promise<BoardGraphResult> {
  let people: BoardPerson[] = []
  let organizations: BoardOrganization[] = []
  let truncated = false

  if (scope.kind === "all") {
    const [peopleResult, organizationsResult] = await Promise.all([
      supabase
        .from("people")
        .select(PERSON_COLUMNS)
        .order("updated_at", { ascending: false })
        .limit(PERSON_CAP + 1),
      supabase.from("organizations").select(ORGANIZATION_COLUMNS).order("name").limit(200),
    ])
    const failure = [peopleResult, organizationsResult].find((r) => r.error)
    if (failure?.error) return { ok: false, error: failure.error.message }

    people = peopleResult.data ?? []
    truncated = people.length > PERSON_CAP
    if (truncated) people = people.slice(0, PERSON_CAP)
    organizations = organizationsResult.data ?? []
  } else if (scope.kind === "case") {
    if (!isUuid(scope.id)) return { ok: true, graph: EMPTY }
    const { data: links, error } = await supabase
      .from("case_links")
      .select("person_id, organization_id")
      .eq("case_id", scope.id)
    if (error) return { ok: false, error: error.message }

    const personIds = uuidList((links ?? []).map((l) => l.person_id))
    const organizationIds = uuidList((links ?? []).map((l) => l.organization_id))
    if (personIds.length === 0 && organizationIds.length === 0) {
      return { ok: true, graph: EMPTY }
    }

    const [peopleResult, organizationsResult] = await Promise.all([
      personIds.length > 0
        ? supabase.from("people").select(PERSON_COLUMNS).in("id", personIds)
        : Promise.resolve({ data: [], error: null }),
      organizationIds.length > 0
        ? supabase.from("organizations").select(ORGANIZATION_COLUMNS).in("id", organizationIds)
        : Promise.resolve({ data: [], error: null }),
    ])
    const failure = [peopleResult, organizationsResult].find((r) => r.error)
    if (failure?.error) return { ok: false, error: failure.error.message }

    people = peopleResult.data ?? []
    organizations = organizationsResult.data ?? []
  } else {
    if (!isUuid(scope.id)) return { ok: true, graph: EMPTY }
    const [organizationResult, membersResult] = await Promise.all([
      supabase.from("organizations").select(ORGANIZATION_COLUMNS).eq("id", scope.id).maybeSingle(),
      supabase.from("memberships").select("person_id").eq("organization_id", scope.id),
    ])
    const failure = [organizationResult, membersResult].find((r) => r.error)
    if (failure?.error) return { ok: false, error: failure.error.message }
    if (!organizationResult.data) return { ok: true, graph: EMPTY }

    organizations = [organizationResult.data]
    const memberIds = uuidList((membersResult.data ?? []).map((m) => m.person_id))
    if (memberIds.length > 0) {
      const { data, error } = await supabase.from("people").select(PERSON_COLUMNS).in("id", memberIds)
      if (error) return { ok: false, error: error.message }
      people = data ?? []
    }
  }

  const edges = await edgesWithin(
    supabase,
    people.map((p) => p.id),
    organizations.map((o) => o.id)
  )
  if (edges.error) return { ok: false, error: edges.error }

  return {
    ok: true,
    graph: {
      people,
      organizations,
      memberships: edges.memberships,
      associates: edges.associates,
      truncated,
    },
  }
}
