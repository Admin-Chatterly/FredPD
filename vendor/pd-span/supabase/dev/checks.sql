-- Assertions run after the migration and seed on a local Postgres.
-- Each block raises on failure; psql runs with ON_ERROR_STOP.

-- Blank strings become null; search_text is derived.
do $$
declare pid uuid; r public.people%rowtype;
begin
  insert into public.people (name, alias, description) values ('   ', '  Ghost ', '') returning id into pid;
  select * into r from public.people where id = pid;
  assert r.name is null, 'blank name should be null';
  assert r.alias = 'Ghost', 'alias should be trimmed';
  assert r.description is null, 'blank description should be null';
  assert r.search_text = ' ghost ', format('unexpected search_text %L', r.search_text);
  assert r.status = 'unknown', 'default status';
  delete from public.people where id = pid;
end $$;

-- Status vocabulary is enforced.
do $$
begin
  begin
    insert into public.people (status) values ('bogus');
    raise exception 'bogus status should have failed';
  exception when check_violation then null;
  end;
end $$;

-- Associates are stored ordered regardless of input; self-links are rejected;
-- the reverse pair collides with the existing one.
do $$
declare r record;
begin
  select * into r from public.associates
  where person_id = 'b0000000-0000-4000-8000-000000000002'
    and associate_id = 'b0000000-0000-4000-8000-000000000004';
  assert found, 'reversed seed pair should have been reordered';
  assert r.relationship = 'seen together';
  begin
    insert into public.associates (person_id, associate_id)
    values ('b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001');
    raise exception 'self-link should have failed';
  exception when check_violation then null;
  end;
  begin
    insert into public.associates (person_id, associate_id)
    values ('b0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-000000000002');
    raise exception 'duplicate reversed pair should have failed';
  exception when unique_violation then null;
  end;
end $$;

-- Plates and tags are normalized.
do $$
declare vid uuid; nid uuid; r record;
begin
  insert into public.vehicles (plate, model) values (' ab-12 cd ', '  ') returning id into vid;
  select * into r from public.vehicles where id = vid;
  assert r.plate = 'AB12CD', format('plate %L', r.plate);
  assert r.model is null, 'blank model should be null';
  delete from public.vehicles where id = vid;

  insert into public.notes (body, tags) values ('  x  ', array[' Drugs', 'drugs', '', 'Weapons']) returning id into nid;
  select * into r from public.notes where id = nid;
  assert r.body = 'x';
  assert r.tags = array['drugs', 'weapons'], format('tags %L', r.tags);
  delete from public.notes where id = nid;
end $$;

-- updated_at moves on update.
do $$
declare before_ts timestamptz; after_ts timestamptz;
begin
  select updated_at into before_ts from public.people where id = 'b0000000-0000-4000-8000-000000000002';
  perform pg_sleep(0.01);
  update public.people set alias = 'Dee' where id = 'b0000000-0000-4000-8000-000000000002';
  select updated_at into after_ts from public.people where id = 'b0000000-0000-4000-8000-000000000002';
  assert after_ts > before_ts, 'updated_at should advance';
end $$;

-- Case links: exactly one target, no duplicates.
do $$
begin
  begin
    insert into public.case_links (case_id) values ('d0000000-0000-4000-8000-000000000001');
    raise exception 'link with no target should have failed';
  exception when check_violation then null;
  end;
  begin
    insert into public.case_links (case_id, person_id, organization_id)
    values ('d0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');
    raise exception 'link with two targets should have failed';
  exception when check_violation then null;
  end;
  begin
    insert into public.case_links (case_id, person_id)
    values ('d0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001');
    raise exception 'duplicate person link should have failed';
  exception when unique_violation then null;
  end;
  begin
    insert into public.case_links (case_id, organization_id)
    values ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001');
    raise exception 'duplicate organization link should have failed';
  exception when unique_violation then null;
  end;
end $$;

-- Evidence: a link or a file, never both or neither; links must be http(s).
do $$
declare eid uuid;
begin
  insert into public.evidence (person_id, url, caption)
  values ('b0000000-0000-4000-8000-000000000001', 'https://medal.tv/games/gta-v/clips/abc123/xyz?invite=cr-1', 'Clip')
  returning id into eid;
  delete from public.evidence where id = eid;
  begin
    insert into public.evidence (person_id) values ('b0000000-0000-4000-8000-000000000001');
    raise exception 'evidence with neither file nor url should fail';
  exception when check_violation then null;
  end;
  begin
    insert into public.evidence (person_id, storage_path, url)
    values ('b0000000-0000-4000-8000-000000000001', 'x', 'https://example.com/a.png');
    raise exception 'evidence with both file and url should fail';
  exception when check_violation then null;
  end;
  begin
    insert into public.evidence (person_id, url) values ('b0000000-0000-4000-8000-000000000001', 'javascript:alert(1)');
    raise exception 'non-http url should fail';
  exception when check_violation then null;
  end;
end $$;

-- Deleting an organization keeps the intel and drops only the join rows.
do $$
declare oid uuid; pid uuid; nid_shared uuid; nid_org uuid; n int;
begin
  insert into public.organizations (name) values ('Doomed Crew') returning id into oid;
  insert into public.people (description) values ('member of the doomed crew') returning id into pid;
  insert into public.memberships (person_id, organization_id) values (pid, oid);
  insert into public.case_links (case_id, organization_id)
    values ('d0000000-0000-4000-8000-000000000001', oid);
  insert into public.notes (person_id, organization_id, body)
    values (pid, oid, 'about the person, mentions the crew') returning id into nid_shared;
  insert into public.notes (organization_id, body)
    values (oid, 'about the crew only') returning id into nid_org;

  delete from public.organizations where id = oid;

  select count(*) into n from public.notes where id in (nid_shared, nid_org);
  assert n = 2, format('both notes should survive, found %s', n);
  select count(*) into n from public.notes where id = nid_shared and person_id = pid and organization_id is null;
  assert n = 1, 'shared note keeps its person and loses the organization';
  select count(*) into n from public.memberships where organization_id = oid;
  assert n = 0, 'membership removed';
  select count(*) into n from public.case_links where organization_id = oid;
  assert n = 0, 'case link removed';

  delete from public.notes where id in (nid_shared, nid_org);
  delete from public.people where id = pid;
end $$;

-- Overview views.
do $$
declare r record;
begin
  select * into r from public.people_overview where id = 'b0000000-0000-4000-8000-000000000001';
  assert r.display_name = 'Marcus Reyes';
  assert r.note_count = 1, format('note_count %s', r.note_count);
  assert r.plates = array['BIGMIKE1'], format('plates %L', r.plates);
  assert jsonb_array_length(r.organizations) = 1;
  assert r.organizations -> 0 ->> 'name' = 'Grove Street Families';
  assert (r.organizations -> 0 ->> 'is_confirmed')::boolean, 'membership flag';

  select * into r from public.people_overview where id = 'b0000000-0000-4000-8000-000000000005';
  assert r.display_name = 'Okänd';
  assert r.organizations -> 0 ->> 'name' = 'Vagos';
  assert r.last_note_at is null;

  select * into r from public.organizations_overview where id = 'a0000000-0000-4000-8000-000000000001';
  assert r.member_count = 3 and r.confirmed_member_count = 2, 'member counts';
  assert r.note_count = 1;

  select * into r from public.cases_overview where id = 'd0000000-0000-4000-8000-000000000001';
  assert r.people_count = 3 and r.organization_count = 2, 'case link counts';
  assert r.note_count = 2;
end $$;

-- Search.
do $$
declare n int;
begin
  select count(*) into n from public.search_all('sultan') where kind = 'person' and id = 'b0000000-0000-4000-8000-000000000004';
  assert n = 1, 'description match for Red Mask';
  select count(*) into n from public.search_all('sultan') where kind = 'vehicle';
  assert n = 1, 'vehicle model match';
  select count(*) into n from public.search_all('46eek') where kind = 'vehicle';
  assert n = 1, 'partial plate match';
  select count(*) into n from public.search_all('46-eek 572') where kind = 'vehicle';
  assert n = 1, 'plate with punctuation should still match';
  select count(*) into n from public.search_all('big mike') where kind = 'person' and id = 'b0000000-0000-4000-8000-000000000001';
  assert n = 1, 'alias match';
  select count(*) into n from public.search_all('recruiting') where kind = 'note';
  assert n = 1, 'tag match';
  select count(*) into n from public.search_all('green light') where kind = 'case';
  assert n = 1, 'case title match';
  select count(*) into n from public.search_all('grove') where kind = 'organization';
  assert n = 1, 'organization match';

  -- Results that have no page of their own carry the record they belong to.
  select count(*) into n from public.search_all('46eek')
   where kind = 'vehicle' and parent_kind = 'person' and parent_id = 'b0000000-0000-4000-8000-000000000004';
  assert n = 1, 'a vehicle result points at its owner';
  select count(*) into n from public.search_all('xr3nch')
   where kind = 'vehicle' and parent_kind is null and parent_id is null;
  assert n = 1, 'a vehicle with no owner has no parent';
  select count(*) into n from public.search_all('recruiting')
   where kind = 'note' and parent_kind = 'organization';
  assert n = 1, 'a note on an organization points at it';
  select count(*) into n from public.search_all('weapons drop')
   where kind = 'note' and parent_kind is null;
  assert n = 1, 'general intel has no parent';
  select count(*) into n from public.search_all('sultans')
   where kind = 'note' and parent_kind = 'person';
  assert n = 1, 'a note on a person prefers the person';
  select count(*) into n from public.search_all('   ');
  assert n = 0, 'blank search returns nothing';
  select count(*) into n from public.distinct_tags();
  assert n >= 6, 'distinct tags';
end $$;

-- Merge: Red Mask turns out to be Dante Cole.
do $$
declare r record; n int;
begin
  perform public.merge_people('b0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000004');

  select * into r from public.people where id = 'b0000000-0000-4000-8000-000000000004';
  assert not found, 'dropped person should be gone';

  select * into r from public.people where id = 'b0000000-0000-4000-8000-000000000002';
  assert r.name = 'Dante Cole' and r.alias = 'Dee', 'kept identity wins';
  assert r.description like 'Tall guy%', 'description filled from dropped record';
  assert r.status = 'poi', 'kept status wins when not unknown';

  select count(*) into n from public.notes where person_id = 'b0000000-0000-4000-8000-000000000002';
  assert n = 1, 'note moved';
  select count(*) into n from public.vehicles where person_id = 'b0000000-0000-4000-8000-000000000002';
  assert n = 1, 'vehicle moved';

  select * into r from public.memberships
  where person_id = 'b0000000-0000-4000-8000-000000000002' and organization_id = 'a0000000-0000-4000-8000-000000000001';
  assert found and r.role = 'enforcer' and r.is_confirmed, 'membership merged, kept role wins';
  select count(*) into n from public.memberships where person_id = 'b0000000-0000-4000-8000-000000000002';
  assert n = 1, 'no duplicate membership';

  -- (2,4 'seen together') collapsed into a self-link and was dropped; (1,2) untouched.
  -- Dante had no case link of his own, so Red Mask's link simply moves over.
  select count(*) into n from public.associates where person_id = 'b0000000-0000-4000-8000-000000000002' or associate_id = 'b0000000-0000-4000-8000-000000000002';
  assert n = 1, format('associate rows after merge: %s', n);

  select count(*) into n from public.case_links where person_id = 'b0000000-0000-4000-8000-000000000002';
  assert n = 1, 'case link moved (deduped)';
  select count(*) into n from public.case_links where case_id = 'd0000000-0000-4000-8000-000000000001';
  assert n = 5, format('case links after merge: %s', n);

  begin
    perform public.merge_people('b0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000002');
    raise exception 'merging a person into itself should fail';
  exception when raise_exception then null;
  end;
end $$;

-- Merge where an associate link has to be re-pointed and deduplicated:
-- link 6-5, then merge 5 into 1 (1-6 already exists as 'cousin', unconfirmed flag merges).
do $$
declare r record; n int;
begin
  insert into public.associates (person_id, associate_id, relationship, is_confirmed)
  values ('b0000000-0000-4000-8000-000000000006', 'b0000000-0000-4000-8000-000000000005', 'cellmate', false);
  perform public.merge_people('b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000005');
  select * into r from public.associates
  where person_id = 'b0000000-0000-4000-8000-000000000001' and associate_id = 'b0000000-0000-4000-8000-000000000006';
  assert found and r.relationship = 'cousin' and r.is_confirmed, 'existing link kept and merged';
  select count(*) into n from public.associates where person_id = 'b0000000-0000-4000-8000-000000000005' or associate_id = 'b0000000-0000-4000-8000-000000000005';
  assert n = 0, 'no dangling links';
  select count(*) into n from public.memberships where person_id = 'b0000000-0000-4000-8000-000000000001';
  assert n = 2, 'Vagos membership moved over';
end $$;

-- Profiles: created by trigger on signup, and backfill-safe.
do $$
declare uid uuid; r record;
begin
  insert into auth.users (email, raw_user_meta_data) values ('officer.jones@example.com', '{"callsign": "Unit 12"}') returning id into uid;
  select * into r from public.profiles where id = uid;
  assert found and r.callsign = 'Unit 12', 'profile from metadata';
  insert into auth.users (email) values ('smith@example.com') returning id into uid;
  select * into r from public.profiles where id = uid;
  assert found and r.callsign = 'smith', 'callsign falls back to email local part';
end $$;

-- RLS: anon sees nothing, authenticated can write and is recorded as author.
do $$
declare uid uuid; pid uuid; r record; n int;
begin
  select id into uid from auth.users where email = 'smith@example.com';
  perform set_config('request.jwt.claim.sub', uid::text, true);

  set local role anon;
  begin
    select count(*) into n from public.people;
    raise exception 'anon should not read people';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.search_all('x');
    raise exception 'anon should not execute search_all';
  exception when insufficient_privilege then null;
  end;

  set local role authenticated;
  select count(*) into n from public.people;
  assert n > 0, 'authenticated reads people';
  insert into public.people (description) values ('created via rls check') returning id into pid;
  select * into r from public.people where id = pid;
  assert r.created_by = uid, 'created_by defaults to the session user';
  insert into public.notes (person_id, body) values (pid, 'note by smith');
  select * into r from public.notes where person_id = pid;
  assert r.created_by = uid, 'note author defaults to the session user';
  select count(*) into n from public.people_overview where id = pid;
  assert n = 1, 'authenticated reads the view';
  perform public.merge_people(pid, 'b0000000-0000-4000-8000-000000000006');
  delete from public.people where id = pid;

  reset role;
end $$;

select 'checks passed' as result;
