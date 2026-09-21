-- =============================================================================
-- PD-span intelligence board — initial schema
--
-- Apply once, in full, with the Supabase SQL editor (paste the whole file) or
-- with `supabase db push`.
--
-- Access model: every table is behind Row Level Security and only the
-- `authenticated` role (accounts you create in the Supabase dashboard) can
-- read or write. The anon key sees nothing.
--
-- Vocabularies are enforced with check constraints. Keep them in sync with
-- lib/constants.ts:
--   people.status         unknown | poi | active_investigation | warrant |
--                         cleared | incarcerated | deceased
--   organizations.type    gang | cartel | business | crew | other
--   organizations.status  active | disbanded | dormant
--   notes.source          informant | wiretap | patrol | tip | surveillance | other
--   notes.confidence      low | medium | high
--   cases.status          open | closed | cold
-- =============================================================================

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function public.blank_to_null(v text)
returns text language sql immutable as $$
  select nullif(btrim(v), '')
$$;

create or replace function public.normalize_tags(v text[])
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct t order by t), '{}'::text[])
  from (select lower(btrim(x)) as t from unnest(coalesce(v, '{}'::text[])) as x) s
  where t <> ''
$$;

create or replace function public.normalize_plate(v text)
returns text language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(v, ''), '[^A-Za-z0-9]', '', 'g')), '')
$$;

-- -----------------------------------------------------------------------------
-- Profiles: one row per auth user, holds the officer's callsign for display.
-- created_by columns reference this table so PostgREST can join the callsign.
-- -----------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  callsign text,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, callsign)
  values (
    new.id,
    coalesce(
      public.blank_to_null(new.raw_user_meta_data ->> 'callsign'),
      split_part(coalesce(new.email, ''), '@', 1)
    )
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- People: suspects and persons of interest. Every field except id is optional;
-- a row can be just a description. Blank strings are stored as null so the
-- "Unknown" label is reliable.
-- -----------------------------------------------------------------------------
create table public.people (
  id uuid primary key default gen_random_uuid(),
  name text,
  alias text,
  description text,
  status text not null default 'unknown'
    check (status in ('unknown', 'poi', 'active_investigation', 'warrant', 'cleared', 'incarcerated', 'deceased')),
  photo_path text,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  search_text text generated always as (
    lower(coalesce(name, '') || ' ' || coalesce(alias, '') || ' ' || coalesce(description, ''))
  ) stored
);

create or replace function public.people_before_write()
returns trigger language plpgsql as $$
begin
  new.name := public.blank_to_null(new.name);
  new.alias := public.blank_to_null(new.alias);
  new.description := public.blank_to_null(new.description);
  new.photo_path := public.blank_to_null(new.photo_path);
  return new;
end $$;

create trigger people_before_write before insert or update on public.people
  for each row execute function public.people_before_write();
create trigger people_set_updated_at before update on public.people
  for each row execute function public.set_updated_at();

create index people_status_idx on public.people (status);
create index people_created_at_idx on public.people (created_at desc);
create index people_search_text_trgm_idx on public.people using gin (search_text gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- Organizations: gangs, crews, cartels, businesses.
-- -----------------------------------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  type text check (type in ('gang', 'cartel', 'business', 'crew', 'other')),
  territory text,
  status text not null default 'active' check (status in ('active', 'disbanded', 'dormant')),
  notes text,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  search_text text generated always as (
    lower(coalesce(name, '') || ' ' || coalesce(territory, '') || ' ' || coalesce(notes, ''))
  ) stored
);

create or replace function public.organizations_before_write()
returns trigger language plpgsql as $$
begin
  new.name := btrim(new.name);
  new.territory := public.blank_to_null(new.territory);
  new.notes := public.blank_to_null(new.notes);
  return new;
end $$;

create trigger organizations_before_write before insert or update on public.organizations
  for each row execute function public.organizations_before_write();
create trigger organizations_set_updated_at before update on public.organizations
  for each row execute function public.set_updated_at();

create index organizations_search_text_trgm_idx on public.organizations using gin (search_text gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- Cases: an investigation that groups people and organizations.
-- -----------------------------------------------------------------------------
create table public.cases (
  id uuid primary key default gen_random_uuid(),
  title text not null check (btrim(title) <> ''),
  description text,
  status text not null default 'open' check (status in ('open', 'closed', 'cold')),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.cases_before_write()
returns trigger language plpgsql as $$
begin
  new.title := btrim(new.title);
  new.description := public.blank_to_null(new.description);
  return new;
end $$;

create trigger cases_before_write before insert or update on public.cases
  for each row execute function public.cases_before_write();
create trigger cases_set_updated_at before update on public.cases
  for each row execute function public.set_updated_at();

create index cases_status_idx on public.cases (status);

-- -----------------------------------------------------------------------------
-- Memberships: people <-> organizations, with a role and suspected/confirmed.
-- -----------------------------------------------------------------------------
create table public.memberships (
  person_id uuid not null references public.people (id) on delete cascade,
  organization_id uuid not null references public.organizations (id) on delete cascade,
  role text,
  is_confirmed boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (person_id, organization_id)
);

create index memberships_organization_id_idx on public.memberships (organization_id);

-- -----------------------------------------------------------------------------
-- Notes: the intel log. Attach to a person, an organization, a case, any
-- combination, or nothing at all (general intel). Author comes from the session.
-- -----------------------------------------------------------------------------
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  person_id uuid references public.people (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete cascade,
  case_id uuid references public.cases (id) on delete set null,
  body text not null check (btrim(body) <> ''),
  tags text[] not null default '{}',
  source text check (source in ('informant', 'wiretap', 'patrol', 'tip', 'surveillance', 'other')),
  confidence text not null default 'medium' check (confidence in ('low', 'medium', 'high')),
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.notes_before_write()
returns trigger language plpgsql as $$
begin
  new.body := btrim(new.body);
  new.tags := public.normalize_tags(new.tags);
  return new;
end $$;

create trigger notes_before_write before insert or update on public.notes
  for each row execute function public.notes_before_write();
create trigger notes_set_updated_at before update on public.notes
  for each row execute function public.set_updated_at();

create index notes_person_id_idx on public.notes (person_id);
create index notes_organization_id_idx on public.notes (organization_id);
create index notes_case_id_idx on public.notes (case_id);
create index notes_created_at_idx on public.notes (created_at desc);
create index notes_tags_idx on public.notes using gin (tags);
create index notes_body_trgm_idx on public.notes using gin (lower(body) gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- Associates: undirected person <-> person links. One row per pair, stored with
-- the smaller uuid first; the trigger reorders whatever the client sends.
-- -----------------------------------------------------------------------------
create table public.associates (
  person_id uuid not null references public.people (id) on delete cascade,
  associate_id uuid not null references public.people (id) on delete cascade,
  relationship text,
  is_confirmed boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (person_id, associate_id),
  constraint associates_no_self check (person_id <> associate_id),
  constraint associates_ordered check (person_id < associate_id)
);

create or replace function public.associates_before_write()
returns trigger language plpgsql as $$
declare tmp uuid;
begin
  if new.person_id > new.associate_id then
    tmp := new.person_id;
    new.person_id := new.associate_id;
    new.associate_id := tmp;
  end if;
  new.relationship := public.blank_to_null(new.relationship);
  return new;
end $$;

create trigger associates_before_write before insert or update on public.associates
  for each row execute function public.associates_before_write();

create index associates_associate_id_idx on public.associates (associate_id);

-- -----------------------------------------------------------------------------
-- Vehicles: manually entered, optionally tied to a person. A plate with an
-- unknown driver is a valid row. Plates are stored upper-case, alphanumeric.
-- -----------------------------------------------------------------------------
create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  person_id uuid references public.people (id) on delete set null,
  plate text,
  model text,
  color text,
  notes text,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  search_text text generated always as (
    lower(coalesce(plate, '') || ' ' || coalesce(model, '') || ' ' || coalesce(color, '') || ' ' || coalesce(notes, ''))
  ) stored
);

create or replace function public.vehicles_before_write()
returns trigger language plpgsql as $$
begin
  new.plate := public.normalize_plate(new.plate);
  new.model := public.blank_to_null(new.model);
  new.color := public.blank_to_null(new.color);
  new.notes := public.blank_to_null(new.notes);
  return new;
end $$;

create trigger vehicles_before_write before insert or update on public.vehicles
  for each row execute function public.vehicles_before_write();
create trigger vehicles_set_updated_at before update on public.vehicles
  for each row execute function public.set_updated_at();

create index vehicles_person_id_idx on public.vehicles (person_id);
create index vehicles_plate_idx on public.vehicles (plate);
create index vehicles_search_text_trgm_idx on public.vehicles using gin (search_text gin_trgm_ops);

-- -----------------------------------------------------------------------------
-- Case links: exactly one of person or organization per row.
-- -----------------------------------------------------------------------------
create table public.case_links (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references public.cases (id) on delete cascade,
  person_id uuid references public.people (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete cascade,
  role text,
  created_at timestamptz not null default now(),
  constraint case_links_one_target check ((person_id is null) <> (organization_id is null)),
  constraint case_links_unique unique nulls not distinct (case_id, person_id, organization_id)
);

create index case_links_person_id_idx on public.case_links (person_id);
create index case_links_organization_id_idx on public.case_links (organization_id);

-- -----------------------------------------------------------------------------
-- Evidence: files in the private `intel` storage bucket, attached to a person,
-- an organization, and/or a case. storage_path is the object path in the
-- bucket; the app renders it through short-lived signed URLs.
-- -----------------------------------------------------------------------------
create table public.evidence (
  id uuid primary key default gen_random_uuid(),
  person_id uuid references public.people (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete cascade,
  case_id uuid references public.cases (id) on delete cascade,
  storage_path text not null,
  caption text,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  constraint evidence_has_target check (
    person_id is not null or organization_id is not null or case_id is not null
  )
);

create index evidence_person_id_idx on public.evidence (person_id);
create index evidence_organization_id_idx on public.evidence (organization_id);
create index evidence_case_id_idx on public.evidence (case_id);

-- -----------------------------------------------------------------------------
-- Views for list pages. security_invoker makes the caller's RLS apply.
-- -----------------------------------------------------------------------------
create view public.people_overview with (security_invoker = true) as
select
  p.id,
  p.name,
  p.alias,
  p.description,
  p.status,
  p.photo_path,
  p.created_by,
  p.created_at,
  p.updated_at,
  coalesce(p.name, p.alias, 'Unknown') as display_name,
  coalesce(o.organizations, '[]'::jsonb) as organizations,
  n.last_note_at,
  coalesce(n.note_count, 0) as note_count,
  coalesce(v.plates, '{}'::text[]) as plates
from public.people p
left join lateral (
  select jsonb_agg(
           jsonb_build_object(
             'id', org.id,
             'name', org.name,
             'type', org.type,
             'role', m.role,
             'is_confirmed', m.is_confirmed
           )
           order by org.name
         ) as organizations
  from public.memberships m
  join public.organizations org on org.id = m.organization_id
  where m.person_id = p.id
) o on true
left join lateral (
  select max(created_at) as last_note_at, count(*) as note_count
  from public.notes
  where person_id = p.id
) n on true
left join lateral (
  select array_agg(plate order by plate) as plates
  from public.vehicles
  where person_id = p.id and plate is not null
) v on true;

create view public.organizations_overview with (security_invoker = true) as
select
  org.id,
  org.name,
  org.type,
  org.territory,
  org.status,
  org.notes,
  org.created_by,
  org.created_at,
  org.updated_at,
  coalesce(m.member_count, 0) as member_count,
  coalesce(m.confirmed_member_count, 0) as confirmed_member_count,
  n.last_note_at,
  coalesce(n.note_count, 0) as note_count
from public.organizations org
left join lateral (
  select count(*) as member_count,
         count(*) filter (where is_confirmed) as confirmed_member_count
  from public.memberships
  where organization_id = org.id
) m on true
left join lateral (
  select max(created_at) as last_note_at, count(*) as note_count
  from public.notes
  where organization_id = org.id
) n on true;

create view public.cases_overview with (security_invoker = true) as
select
  c.id,
  c.title,
  c.description,
  c.status,
  c.created_by,
  c.created_at,
  c.updated_at,
  coalesce(l.people_count, 0) as people_count,
  coalesce(l.organization_count, 0) as organization_count,
  n.last_note_at,
  coalesce(n.note_count, 0) as note_count
from public.cases c
left join lateral (
  select count(*) filter (where person_id is not null) as people_count,
         count(*) filter (where organization_id is not null) as organization_count
  from public.case_links
  where case_id = c.id
) l on true
left join lateral (
  select max(created_at) as last_note_at, count(*) as note_count
  from public.notes
  where case_id = c.id
) n on true;

-- -----------------------------------------------------------------------------
-- Distinct tags across all notes, with usage counts (for the tag filter bar).
-- -----------------------------------------------------------------------------
create or replace function public.distinct_tags()
returns table (tag text, uses bigint)
language sql stable as $$
  select t as tag, count(*) as uses
  from public.notes, unnest(tags) as t
  group by t
  order by uses desc, t
$$;

-- -----------------------------------------------------------------------------
-- Global search: one round trip, grouped by kind. Matches are case-insensitive
-- substrings, ranked by trigram word similarity so typos still surface.
-- -----------------------------------------------------------------------------
create or replace function public.search_all(term text, per_type int default 8)
returns table (kind text, id uuid, title text, subtitle text, status text, score real)
language sql stable as $$
  with q as (
    select lower(btrim(coalesce(term, ''))) as t
  )
  select * from (
    (
      select 'person'::text as kind,
             p.id,
             coalesce(p.name, p.alias, 'Unknown') as title,
             concat_ws(' · ', case when p.name is not null then p.alias end, p.description) as subtitle,
             p.status,
             greatest(word_similarity(q.t, p.search_text),
                      case when p.search_text like '%' || q.t || '%' then 0.6 else 0 end)::real as score
      from public.people p, q
      where q.t <> ''
        and (p.search_text like '%' || q.t || '%' or word_similarity(q.t, p.search_text) > 0.45)
      order by score desc, p.updated_at desc
      limit per_type
    )
    union all
    (
      select 'organization'::text,
             o.id,
             o.name,
             concat_ws(' · ', o.type, o.territory),
             o.status,
             greatest(word_similarity(q.t, o.search_text),
                      case when o.search_text like '%' || q.t || '%' then 0.6 else 0 end)::real
      from public.organizations o, q
      where q.t <> ''
        and (o.search_text like '%' || q.t || '%' or word_similarity(q.t, o.search_text) > 0.45)
      order by 6 desc, o.updated_at desc
      limit per_type
    )
    union all
    (
      select 'vehicle'::text,
             v.id,
             coalesce(v.plate, 'No plate'),
             concat_ws(' · ', concat_ws(' ', v.color, v.model),
                       (select coalesce(p.name, p.alias, 'Unknown') from public.people p where p.id = v.person_id)),
             null::text,
             greatest(word_similarity(q.t, v.search_text),
                      case when v.search_text like '%' || q.t || '%' then 0.6 else 0 end)::real
      from public.vehicles v, q
      where q.t <> ''
        and (v.search_text like '%' || q.t || '%' or v.plate = public.normalize_plate(q.t))
      order by 6 desc, v.updated_at desc
      limit per_type
    )
    union all
    (
      select 'note'::text,
             n.id,
             left(n.body, 160),
             array_to_string(n.tags, ', '),
             n.confidence,
             (case when lower(n.body) like '%' || q.t || '%' then 0.6 else 0.5 end)::real
      from public.notes n, q
      where q.t <> ''
        and (lower(n.body) like '%' || q.t || '%'
             or exists (select 1 from unnest(n.tags) tg where tg like '%' || q.t || '%'))
      order by n.created_at desc
      limit per_type
    )
    union all
    (
      select 'case'::text,
             c.id,
             c.title,
             c.description,
             c.status,
             (case when lower(c.title) like '%' || q.t || '%' then 0.7 else 0.5 end)::real
      from public.cases c, q
      where q.t <> ''
        and (lower(c.title) like '%' || q.t || '%' or lower(coalesce(c.description, '')) like '%' || q.t || '%')
      order by c.updated_at desc
      limit per_type
    )
  ) r
  order by score desc, title
$$;

-- -----------------------------------------------------------------------------
-- Merge two people. Everything attached to drop_id moves to keep_id, blanks on
-- the kept record are filled from the dropped one, then drop_id is deleted.
-- Runs in one transaction; returns the kept id.
-- -----------------------------------------------------------------------------
create or replace function public.merge_people(keep_id uuid, drop_id uuid)
returns uuid language plpgsql as $$
declare
  k public.people%rowtype;
  d public.people%rowtype;
begin
  if keep_id is null or drop_id is null or keep_id = drop_id then
    raise exception 'merge_people: keep_id and drop_id must be two different people';
  end if;

  select * into k from public.people where id = keep_id for update;
  if not found then raise exception 'merge_people: keep_id % not found', keep_id; end if;
  select * into d from public.people where id = drop_id for update;
  if not found then raise exception 'merge_people: drop_id % not found', drop_id; end if;

  update public.people set
    name = coalesce(k.name, d.name),
    alias = coalesce(k.alias, d.alias),
    description = case
      when k.description is null then d.description
      when d.description is null then k.description
      else k.description || E'\n\n' || d.description
    end,
    photo_path = coalesce(k.photo_path, d.photo_path),
    status = case when k.status = 'unknown' then d.status else k.status end
  where id = keep_id;

  update public.notes set person_id = keep_id where person_id = drop_id;
  update public.vehicles set person_id = keep_id where person_id = drop_id;
  update public.evidence set person_id = keep_id where person_id = drop_id;

  -- memberships: merge flags where both had the org, then move the rest
  update public.memberships m
  set is_confirmed = m.is_confirmed or dm.is_confirmed,
      role = coalesce(m.role, dm.role)
  from public.memberships dm
  where m.person_id = keep_id
    and dm.person_id = drop_id
    and dm.organization_id = m.organization_id;
  delete from public.memberships
  where person_id = drop_id
    and organization_id in (select organization_id from public.memberships where person_id = keep_id);
  update public.memberships set person_id = keep_id where person_id = drop_id;

  -- case links: drop duplicates, move the rest
  delete from public.case_links cl
  where cl.person_id = drop_id
    and exists (select 1 from public.case_links x where x.person_id = keep_id and x.case_id = cl.case_id);
  update public.case_links set person_id = keep_id where person_id = drop_id;

  -- associates: re-point to keep_id, skipping self-links and merging duplicates
  insert into public.associates (person_id, associate_id, relationship, is_confirmed, created_at)
  select least(keep_id, s.other), greatest(keep_id, s.other), s.relationship, s.is_confirmed, s.created_at
  from (
    select case when a.person_id = drop_id then a.associate_id else a.person_id end as other,
           a.relationship, a.is_confirmed, a.created_at
    from public.associates a
    where a.person_id = drop_id or a.associate_id = drop_id
  ) s
  where s.other <> keep_id
  on conflict (person_id, associate_id) do update
    set is_confirmed = public.associates.is_confirmed or excluded.is_confirmed,
        relationship = coalesce(public.associates.relationship, excluded.relationship);
  delete from public.associates where person_id = drop_id or associate_id = drop_id;

  delete from public.people where id = drop_id;
  return keep_id;
end $$;

-- -----------------------------------------------------------------------------
-- Row Level Security: authenticated users can do everything, anon nothing.
-- -----------------------------------------------------------------------------
alter table public.profiles      enable row level security;
alter table public.people        enable row level security;
alter table public.organizations enable row level security;
alter table public.cases         enable row level security;
alter table public.memberships   enable row level security;
alter table public.notes         enable row level security;
alter table public.associates    enable row level security;
alter table public.vehicles      enable row level security;
alter table public.case_links    enable row level security;
alter table public.evidence      enable row level security;

create policy "profiles: authenticated read" on public.profiles
  for select to authenticated using (true);
create policy "profiles: update own" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "people: authenticated all" on public.people
  for all to authenticated using (true) with check (true);
create policy "organizations: authenticated all" on public.organizations
  for all to authenticated using (true) with check (true);
create policy "cases: authenticated all" on public.cases
  for all to authenticated using (true) with check (true);
create policy "memberships: authenticated all" on public.memberships
  for all to authenticated using (true) with check (true);
create policy "notes: authenticated all" on public.notes
  for all to authenticated using (true) with check (true);
create policy "associates: authenticated all" on public.associates
  for all to authenticated using (true) with check (true);
create policy "vehicles: authenticated all" on public.vehicles
  for all to authenticated using (true) with check (true);
create policy "case_links: authenticated all" on public.case_links
  for all to authenticated using (true) with check (true);
create policy "evidence: authenticated all" on public.evidence
  for all to authenticated using (true) with check (true);

-- Explicit grants (Supabase's default privileges normally cover this) and a
-- belt-and-braces revoke for anon.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profiles, public.people, public.organizations, public.cases,
  public.memberships, public.notes, public.associates, public.vehicles,
  public.case_links, public.evidence
  to authenticated;
grant select on public.people_overview, public.organizations_overview, public.cases_overview to authenticated;
grant execute on function
  public.search_all(text, int), public.merge_people(uuid, uuid), public.distinct_tags()
  to authenticated;

revoke all on
  public.profiles, public.people, public.organizations, public.cases,
  public.memberships, public.notes, public.associates, public.vehicles,
  public.case_links, public.evidence,
  public.people_overview, public.organizations_overview, public.cases_overview
  from anon;
revoke all on function
  public.search_all(text, int), public.merge_people(uuid, uuid), public.distinct_tags()
  from anon, public;

-- -----------------------------------------------------------------------------
-- Storage: one private bucket for photos and evidence. Files are read through
-- signed URLs only.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('intel', 'intel', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do nothing;

create policy "intel: authenticated read" on storage.objects
  for select to authenticated using (bucket_id = 'intel');
create policy "intel: authenticated insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'intel');
create policy "intel: authenticated update" on storage.objects
  for update to authenticated using (bucket_id = 'intel') with check (bucket_id = 'intel');
create policy "intel: authenticated delete" on storage.objects
  for delete to authenticated using (bucket_id = 'intel');

-- -----------------------------------------------------------------------------
-- Backfill profiles for accounts created before this migration ran.
-- -----------------------------------------------------------------------------
insert into public.profiles (id, callsign)
select u.id,
       coalesce(public.blank_to_null(u.raw_user_meta_data ->> 'callsign'),
                split_part(coalesce(u.email, ''), '@', 1))
from auth.users u
on conflict (id) do nothing;
