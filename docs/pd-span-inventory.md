# PD-Span inventory

Required by spec **10.5**. Source imported at `vendor/pd-span/`
(`PD-span` @ `1a63203`, 208 files). No code was changed.

| Field | Value |
| --- | --- |
| Date | 2026-09-17 |
| Spec sections | 10 (integration), 0 and 11 (security review) |
| Blocks | M0 (this inventory), M5 (intelligence module) |
| Recommendation | **Option 1, with a caveat** — port the data model, rewrite the UI. See §9. |
| PD-Span status | **Live, with real intelligence in it** (confirmed 2026-09-17). |
| Outcome | **Built.** Option 1 taken in its reframed form: the data model is ported to MariaDB as the `intel` module (the `fpd_intel_*` tables in migration 0001). The existing data is **not** migrated — §8 is retained as a record, not a plan. |

## 1. The headline finding

**PD-Span is not a FiveM resource.** It is a standalone Next.js web
application on Supabase, deployed to Vercel. It has no `fxmanifest.lua`, no Lua,
no exports, no events, no callbacks and no in-game presence of any kind. The
only occurrences of the string "FiveM" in the whole tree are prose in
`README.md` and `seed.sql`.

This matters because spec 10.3 ranks the integration options on an assumption
that turns out to be false:

> 1. **Merge PD-Span into the monorepo as the `intel` module** (preferred if
>    PD-Span is a FiveM resource you own).

It is not one, so "merge" cannot mean dropping a resource into
`resources/[fredpd]/`. What is portable is the **data model and the SQL**, not
the application. Section 9 re-ranks the options on what is actually there.

## 2. Manifest and dependencies

There is no manifest. The equivalent is `package.json`:

| Layer | Choice |
| --- | --- |
| Framework | Next.js 16.3.4 (App Router, Server Actions), React 19.2.8 |
| Data | Supabase — Postgres, Auth, Storage (`@supabase/ssr`, `@supabase/supabase-js`) |
| UI | Tailwind 4, shadcn/ui on `radix-ui`, `lucide-react`, `sonner`, `cmdk` |
| Graph | `@xyflow/react` + `d3-force` (the `/board` link chart) |
| Validation | `zod` 4 |
| Hosting | Vercel (`vercel.json`), Node/pnpm |

Runtime configuration is two environment variables:
`NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`.

**Overlap with FredPD:** Tailwind 4, Lucide and zod are already in our stack.
**Conflict:** React vs Svelte 5 (ADR-002), and Supabase/Postgres vs MariaDB
(spec 3.3). Neither the UI layer nor the database layer transfers as-is.

## 3. Database

Postgres, 10 tables, 3 views, 6 functions, across 5 migrations (707 lines in
`0001_init.sql` plus four follow-ups).

### Tables, mapped to FredPD entities

| PD-Span | Rows are | Maps to (FredPD) | Notes on the mapping |
| --- | --- | --- | --- |
| `people` | Suspects and persons of interest | **Person record** (7.3) | Every field but `id` is optional — a row can be nothing but a physical description. FredPD's master name index assumes more identity than that; see §7. |
| `organizations` | Gangs, cartels, businesses, crews | **Organisation profile** (10.6 S) | No FredPD equivalent exists yet; this is new surface for M5. |
| `memberships` | Person ↔ organisation, with role and confirmed flag | **Link-analysis edge** (10.6 S) | Composite PK, both directions managed. |
| `associates` | Person ↔ person, undirected | **Link-analysis edge** (10.6 S) | Enforces one row per pair with `check (person_id < associate_id)` — a neat trick worth keeping. |
| `notes` | The intel log | **Intelligence report** (10.6 M) | The closest thing to FredPD's graded report, but **ungraded**; see §7. |
| `vehicles` | Plates and models, optionally tied to a person | **Vehicle record** (7.4) | Plates stored upper-cased by a trigger. FredPD's vehicle record is richer and authoritative. |
| `cases` / `case_links` | An investigation and who is in it | **Case** (7.8) | `case_links` points at exactly one of person/organisation, enforced by a check constraint. |
| `evidence` | An uploaded image or an external link | **Evidence / attachment** (8, 7.x) | See §6 — this is *intelligence attachment*, not chain-of-custody evidence. |
| `profiles` | One row per login, holding a callsign | **Personnel** (7.22) | Replaced wholesale by FredPD's roster. |

### Views and functions

| Object | What it does | Worth keeping? |
| --- | --- | --- |
| `people_overview`, `organizations_overview`, `cases_overview` | Back the list pages | Design input only — rewrite as FredPD queries |
| `search_all(term, per_type)` | One search across people, aliases, descriptions, plates, territories, note bodies and tags, grouped by type | **Yes — the logic.** This is the most valuable single artefact in the repo |
| `merge_people(keep, drop)` | Merges a duplicate person into another, moving every reference | **Yes — the logic.** Directly relevant to reconciling intel identities against the master name index |
| `distinct_tags()` | Powers the tag filter | Trivial to reproduce |
| `normalize_plate`, `normalize_tags`, `blank_to_null` | Write-time normalisation triggers | Good practice; reproduce in FredPD services |

Postgres-specific features in use that **do not exist in MariaDB** and must be
reworked, not translated: `gen_random_uuid()` (pgcrypto), `pg_trgm` fuzzy
search, `text[]` array columns for tags, generated `search_text` columns,
`nulls not distinct` unique constraints, and row-level security itself.

## 4. Exports, events and callbacks

**None.** There is no integration surface at all — no resource exports, no
events, no callbacks, no HTTP API.

The application's own boundary is **Next.js Server Actions**: eight
`actions.ts` files (people, organizations, cases, notes, memberships, evidence,
search, login). Each action calls `requireUser()` itself and then talks to
Supabase. That is a convention repeated ~41 times, not a chokepoint — there is
no equivalent of FredPD's `route()`.

## 5. UI technology

Next.js App Router with React Server Components; ~90 components under
`components/`, shadcn/ui primitives over Radix. Notable screens: `/people`,
`/organizations`, `/cases`, `/intel` (the log with tag filtering), `/board`
(force-directed link chart), and a Ctrl+K global search.

The interface is **hardcoded Swedish** throughout, with no locale layer of any
kind — user-facing strings sit inline in components and even in library code
(`lib/upload.ts` returns `"Den filtypen tas inte emot…"`). Porting means
extracting every string into locale keys (invariant 6), which is unavoidable
work regardless of which option is chosen.

None of this transfers directly: FredPD's NUI is Svelte 5 (ADR-002) inside CEF,
and spec 6 rejects much of the shadcn look. The **screen designs and
interaction patterns** are worth keeping; the code is not.

## 6. Permission logic to replace

This is the largest gap, and it is not close.

PD-Span's model is **binary**: anyone holding a Supabase account can read and
write everything. Every table carries the same policy shape —

```sql
create policy "people: authenticated all" on public.people
  for all to authenticated using (true) with check (true);
```

— and the storage bucket is the same. There are no roles, no ranks, no
clearance levels, no compartments, no classification, no per-record grants and
no ownership checks. `profiles.callsign` is the only per-user datum, and it is
decoration. Access control is entirely "do you have an account", with sign-ups
disabled in the Supabase dashboard so accounts are created by hand.

Everything above must be replaced by FredPD's model:

| PD-Span | FredPD replacement |
| --- | --- |
| Supabase Auth email/password | Discord identity + bound character (4.1) |
| "authenticated" = full access | Discord-role-derived permissions (4.3), invariant 2 |
| No classification | Classifications, compartments, grants, restricted stubs, break-glass (7.x, 11) |
| No source protection | `sources` compartment, pseudonymised IDs, controller-only true identity (10.6) |
| RLS policies in Postgres | Server-side access checks in `service.lua`, on every read (invariant 4) |
| `requireUser()` per action | `route()` wrapper: session → permission → context → rate limit → schema → audit (invariant 3) |

For an intelligence system this is the critical delta. Intelligence is exactly
the data that needs compartments — a source register where every officer can
read every source's true identity is the failure mode spec 10.6 is written to
prevent.

## 7. Security review against sections 0 and 11

Judged as what it is — a small trusted-team tool — PD-Span is competently
built. Judged against FredPD's invariants, which is the question here:

| # | Invariant | Verdict |
| --- | --- | --- |
| 1 | Server-authoritative | **Pass.** `created_by` defaults to `auth.uid()` *in the database*, timestamps come from `now()`, plates and tags are normalised by triggers. Authorship cannot be forged from the client. |
| 2 | Discord is the only permission source | **Fail.** Supabase accounts, unrelated to Discord. Replaced entirely (§6). |
| 3 | One gateway for client calls | **Fail.** No chokepoint: 41 Server Actions each repeat `requireUser()`. No central rate limiting, schema validation or audit. Miss one and the check is simply absent. |
| 4 | Access checked server-side on every read | **Technically pass, substantively fail.** RLS does run on every read, but it answers "true" for everyone. No record-level access exists. |
| 5 | No record broadcasts | **N/A** — no FiveM eventing. |
| 6 | No hardcoded user-facing text | **Fail.** Hardcoded Swedish throughout, no locale layer (§5). |
| 7 | No secrets on clients | **Pass.** Only the anon key reaches the browser, which is its design; RLS is the control. |
| 8 | Parameterised SQL, append-only migrations | **Pass.** PostgREST parameterises; migrations are numbered and additive. |
| 9 | Media only through the gateway | **Partial.** Strong parts: the `intel` bucket is private, reads go through short-lived signed URLs, and `isSafeStoragePath()` constrains paths. Gaps: the browser uploads **straight to Storage** with no server in between, so images are **never re-encoded** — EXIF, including GPS, is preserved and served back. FredPD must re-encode on intake. |
| 10 | Rich text as editor JSON | **Pass by absence** — note bodies are plain text; no HTML is rendered. |
| 11 | Append-only audit log | **Fail, and this is the serious one.** There is no audit log at all. Nothing records who read a person, ran a search or opened a note. Spec 11 requires reads of restricted records to be audited; PD-Span cannot answer "who looked at this?" for any record. |
| 12 | UI per section 6 | **Fail** by construction — different framework, different visual language. |
| 13 | Performance budgets | **Unassessed.** Built for a handful of officers on Vercel; `search_all` does seven `union all` branches with `ilike`/trigram matching per query. Needs measurement against spec 12 before any of it is ported. |

Two more observations worth carrying into M5:

- **Deletion semantics are deliberate and good.** Deleting an organisation
  detaches its notes rather than deleting them (`0003_keep_notes_when_organization_deleted.sql`).
  Intelligence outliving the record it hung on is the correct behaviour and
  FredPD should preserve it.
- **Unknown-identity records are a first-class feature.** A `people` row can be
  a description with no name, and a tip can be logged attached to nothing at
  all. FredPD's master name index (7.3) assumes a known person, so this needs a
  deliberate answer rather than being lost in the port (§8).

## 8. Data migration plan (not being carried out)

> **Decided 2026-09-17: the existing data is not migrated.** The `intel` module
> starts empty and the register is rebuilt in game. Nothing below is scheduled;
> it is kept because it is the analysis that would be needed if that is ever
> revisited, and because the reasoning about identity reconciliation is worth
> having written down before somebody proposes a quick import.
>
> Practically, this removed the riskiest work in the port. It also means the
> schema carries no `span_uuid` columns: keying an import on the old ids would
> be an `ALTER`, not a redesign.

**PD-Span is live and holds real intelligence.** That would have made this
section the riskiest part of the work. Three consequences follow, and they
are the reason the steps below are ordered the way they are:

1. **There is no acceptable data-loss window.** The migration must be
   re-runnable and idempotent, so it can be rehearsed against a copy as often as
   needed and re-run after a correction without duplicating anything.
2. **The system stays in use while the port is built.** Officers keep logging
   intelligence into PD-Span until cutover, so the migration must be able to run
   twice: a bulk pass, and a delta pass at cutover for everything logged since.
   The `fpd_span_id_map` table in step 2 is what makes the second pass possible.
3. **Wrong is worse than late.** A mis-merged person attributes one person's
   intelligence to another, and a mis-classified source register exposes an
   informant. Both are worse outcomes than the migration taking another week.
   Step 3 is reviewed by a person, not automated.

Cross-engine (Postgres → MariaDB) and cross-model, so this is an ETL, not a
dump and restore. Volumes are small; correctness of identity is the hard part.

1. **Export** each table as JSON from Supabase, in dependency order:
   `profiles → people → organizations → cases → memberships → associates →
   vehicles → notes → case_links → evidence`.
2. **Map identities.** PD-Span uses UUIDs; FredPD uses its own record numbers.
   Keep a mapping table (`fpd_span_id_map`: `span_uuid`, `entity_type`,
   `fpd_id`) — it is what `migrateIds()` in the 10.4 contract needs, and it
   makes the migration re-runnable and auditable.
3. **Reconcile persons against the master name index.** This is the real work.
   Each `people` row is one of:
   - a match for an existing FredPD person → link, do not create;
   - a new identified person → create;
   - **an unidentified person** (description only) → create as an intelligence
     subject that is *not* a master name record, and can be merged into one
     later. PD-Span's own `merge_people()` is the model for that merge.
   Do this with review, not automatically: a wrong merge attributes one
   person's intelligence to another.
4. **Grade the intelligence.** `notes` have `source` (informant, wiretap,
   patrol, tip, surveillance, other) and `confidence` (low/medium/high). FredPD
   requires A–F source reliability and 1–6 information credibility (10.6).
   There is no honest automatic mapping between the two. Import the originals
   verbatim into a `legacy_` field, set the graded fields to "not evaluated",
   and let analysts grade on review. Do not invent gradings.
5. **Classify on import.** Every imported record needs a classification and,
   where relevant, a compartment. Default to the most restrictive that keeps it
   usable, and put anything sourced from `informant` or `surveillance` into the
   `sources` compartment pending review.
6. **Media.** Copy the `intel` bucket to FredPD's media store **through the
   gateway**, re-encoding each image to strip EXIF (§7, invariant 9). External
   evidence links carry over as URLs.
7. **Authorship.** `created_by` points at Supabase user IDs. Map them to FredPD
   officers via `profiles.callsign`; where no match exists, attribute to a
   system "legacy import" officer rather than to whoever is running the import.
8. **Verify** with counts per table, a sample diff, and a check that every
   `notes` row still resolves to its subject.
9. **Rehearse against a copy, twice**, before touching anything real: once from
   an empty FredPD schema, and once as a delta on top of the first run, which is
   exactly the shape cutover takes. Keep PD-Span readable (option 2's temporary
   read-only bridge) until the rehearsal has been signed off.

**Retire PD-Span deliberately, not by switching it off.** Once cutover is done,
its Supabase project should be made read-only rather than deleted, and kept for
at least one retention period: it is the only copy of the original data if a
reconciliation decision in step 3 turns out to be wrong.

## 9. Recommendation

**Option 1, reframed: port the data model into the monorepo as the `intel`
module, and rewrite the UI.** Treat PD-Span as a working prototype whose schema
and SQL are the deliverable, not its code.

Why not the others:

- **Option 2 (keep it running, integrate through the bridge).** The 10.4
  contract is Lua calling a FiveM resource. PD-Span is a Vercel-hosted web app,
  so the "bridge" would be HTTP from the gateway to Next.js, and the server
  would run two auth systems, two databases and two deployments permanently.
  That is the direct opposite of 10.2's "one sign-on and one permission system",
  and it leaves the source register under the flat model described in §6. Viable
  only as a temporary read-only bridge while the port runs.
- **Option 3 (database-level).** Would mean a live link between MariaDB and
  Postgres, with the weakest access control of the three, applied to the data
  that most needs compartments. Spec 10.3 already calls it a last resort; the
  cross-engine split makes it worse than it looks there.

The caveat on option 1: "merge" is a **rewrite of the presentation layer and a
re-platform of the storage layer**, not a code move. What genuinely carries over
is the entity model, the relationship design (the ordered-pair trick, the
one-target check constraint, notes surviving their parent), the `search_all`
and `merge_people` logic, and the screen designs.

### Effort

Spec 17.1 budgets M5 at 30–50 h, "depends on PD-Span". On this evidence:

| Work | Estimate |
| --- | --- |
| Schema port to MariaDB, with classification and compartment columns added | 6–10 h |
| `intel` module: services, repos, routes, access checks, audit | 10–14 h |
| Search: reproduce `search_all` semantics on MariaDB FULLTEXT | 4–6 h |
| NUI rewrite in Svelte — list, record, intel log, composer | 12–18 h |
| Link chart (`/board`) in the NUI | 4–6 h |
| Graded reports, source register, surveillance logs (new, not ported — 10.6) | 10–14 h |
| Data migration and reconciliation tooling (§8) | 6–10 h |
| Localisation: extract every string, complete `en` and `sv` | 4–6 h |
| **Total** | **56–84 h** |

That is **above the spec's 30–50 h**, and the gap is honest rather than
padding: the M5 budget was written for integrating a FiveM resource, and this is
a re-platform plus the graded-intelligence and source-register features that
PD-Span never had. Roughly 20 h of the total is new capability rather than
porting.

### Suggested sequencing

1. Port the schema and the `intel` module server-side first, behind the existing
   permission model — data and access control before pixels.
2. Run the migration into staging early, so identity reconciliation (§8.3) has
   time to surface problems.
3. Build the NUI screens against the mock bridge, which works without a game
   server.
4. Add graded reports, the source register and surveillance logs last; they are
   new features with no prototype behind them.

## 10. Open questions for Rami

1. ~~Is PD-Span live with real data?~~ **Answered: yes.** §8 is rewritten
   around that, and it is why the migration is rehearsed rather than run.
2. ~~How much data, and how far back?~~ **Moot:** the data is not migrated.
3. ~~Who grades the imported intelligence?~~ **Moot** for the same reason. The
   graded fields (A–F reliability, 1–6 credibility) exist on `fpd_intel_notes`
   and stay NULL until an analyst uses them; nothing arrives pre-graded.
4. **Do unidentified persons stay separate from the master name index?** §7's
   last point, and still open. The schema takes the cautious side for now:
   `fpd_intel_persons.master_person_id` is where an intelligence subject gets
   tied to a confirmed person record once M2 builds one, and it is NULL until
   somebody decides it should not be.
5. **When does PD-Span get switched off?** It is now a second system holding
   intelligence that FredPD does not know about. Leaving it running
   indefinitely is the outcome nobody chooses but everybody ends up with.
