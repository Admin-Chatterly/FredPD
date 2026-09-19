-- The app is Swedish, but two fallback labels were still generated in the
-- database: the display name of a person with neither a name nor an alias, and
-- the title of a vehicle with no plate. They reach the officer through the
-- people list's sort order and through global search, so they are translated
-- here rather than patched over in the app.
--
-- Nothing else changes: same columns, same types, same order, so the view is
-- replaced in place and the function keeps the signature migration 0004 gave it.

create or replace view public.people_overview with (security_invoker = true) as
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
  coalesce(p.name, p.alias, 'Okänd') as display_name,
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

create or replace function public.search_all(term text, per_type int default 8)
returns table (
  kind text,
  id uuid,
  title text,
  subtitle text,
  status text,
  score real,
  parent_kind text,
  parent_id uuid
)
language sql stable as $$
  with q as (
    select lower(btrim(coalesce(term, ''))) as t
  )
  select * from (
    (
      select 'person'::text as kind,
             p.id,
             coalesce(p.name, p.alias, 'Okänd') as title,
             concat_ws(' · ', case when p.name is not null then p.alias end, p.description) as subtitle,
             p.status,
             greatest(word_similarity(q.t, p.search_text),
                      case when p.search_text like '%' || q.t || '%' then 0.6 else 0 end)::real as score,
             null::text as parent_kind,
             null::uuid as parent_id
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
                      case when o.search_text like '%' || q.t || '%' then 0.6 else 0 end)::real,
             null::text,
             null::uuid
      from public.organizations o, q
      where q.t <> ''
        and (o.search_text like '%' || q.t || '%' or word_similarity(q.t, o.search_text) > 0.45)
      order by 6 desc, o.updated_at desc
      limit per_type
    )
    union all
    (
      -- A vehicle opens its owner's file when the owner is known.
      select 'vehicle'::text,
             v.id,
             coalesce(v.plate, 'Ingen regskylt'),
             concat_ws(' · ', concat_ws(' ', v.color, v.model),
                       (select coalesce(p.name, p.alias, 'Okänd') from public.people p where p.id = v.person_id)),
             null::text,
             greatest(word_similarity(q.t, v.search_text),
                      case when v.search_text like '%' || q.t || '%' then 0.6 else 0 end)::real,
             case when v.person_id is not null then 'person' end::text,
             v.person_id
      from public.vehicles v, q
      where q.t <> ''
        and (v.search_text like '%' || q.t || '%' or v.plate = public.normalize_plate(q.t))
      order by 6 desc, v.updated_at desc
      limit per_type
    )
    union all
    (
      -- A note opens whatever it is attached to, preferring the person. General
      -- intel is attached to nothing and keeps both columns null.
      select 'note'::text,
             n.id,
             left(n.body, 160),
             array_to_string(n.tags, ', '),
             n.confidence,
             (case when lower(n.body) like '%' || q.t || '%' then 0.6 else 0.5 end)::real,
             case
               when n.person_id is not null then 'person'
               when n.organization_id is not null then 'organization'
               when n.case_id is not null then 'case'
             end::text,
             coalesce(n.person_id, n.organization_id, n.case_id)
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
             (case when lower(c.title) like '%' || q.t || '%' then 0.7 else 0.5 end)::real,
             null::text,
             null::uuid
      from public.cases c, q
      where q.t <> ''
        and (lower(c.title) like '%' || q.t || '%' or lower(coalesce(c.description, '')) like '%' || q.t || '%')
      order by c.updated_at desc
      limit per_type
    )
  ) r
  order by score desc, title
$$;

grant execute on function public.search_all(text, int) to authenticated;
revoke all on function public.search_all(text, int) from anon, public;
