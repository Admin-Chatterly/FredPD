-- Fictional seed data for local checks and demos. Everything here is invented
-- for a FiveM roleplay setting. Optional in production: run it only if you want
-- example rows to click around, and delete them afterwards.

insert into public.organizations (id, name, type, territory, status, notes) values
  ('a0000000-0000-4000-8000-000000000001', 'Grove Street Families', 'gang', 'Grove Street, Davis', 'active', 'Green colours. Street-level narcotics and a chop-shop pipeline.'),
  ('a0000000-0000-4000-8000-000000000002', 'Vagos', 'gang', 'Rancho / Jamestown', 'active', 'Yellow colours. Suspected weapons pipeline from Sandy Shores.'),
  ('a0000000-0000-4000-8000-000000000003', 'Los Santos Customs (Burton)', 'business', 'Burton', 'active', 'Possible front for re-plating stolen vehicles.');

insert into public.people (id, name, alias, description, status) values
  ('b0000000-0000-4000-8000-000000000001', 'Marcus Reyes', 'Big Mike', 'Heavy build, gold chain, never alone.', 'active_investigation'),
  ('b0000000-0000-4000-8000-000000000002', 'Dante Cole', 'D', null, 'poi'),
  ('b0000000-0000-4000-8000-000000000003', 'Elena Vasquez', null, 'Front desk at LS Customs Burton.', 'poi'),
  ('b0000000-0000-4000-8000-000000000004', null, 'Red Mask', 'Tall guy, red ski mask, drives a black Sultan. Seen at the Grove Street corner store twice.', 'unknown'),
  ('b0000000-0000-4000-8000-000000000005', null, null, 'Short, shaved head, yellow bandana. Passenger in the green Sultan on 3rd.', 'unknown'),
  ('b0000000-0000-4000-8000-000000000006', 'Tyrone Banks', 'T-Bone', 'Currently in Bolingbroke.', 'incarcerated');

insert into public.memberships (person_id, organization_id, role, is_confirmed) values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'leader', true),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000001', 'enforcer', true),
  ('b0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000001', null, false),
  ('b0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000002', null, false),
  ('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003', 'employee', true);

insert into public.associates (person_id, associate_id, relationship, is_confirmed) values
  ('b0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'frequent contact', true),
  ('b0000000-0000-4000-8000-000000000004', 'b0000000-0000-4000-8000-000000000002', 'seen together', false),
  ('b0000000-0000-4000-8000-000000000006', 'b0000000-0000-4000-8000-000000000001', 'cousin', true);

insert into public.vehicles (id, person_id, plate, model, color, notes) values
  ('c0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000004', '46EEK572', 'Karin Sultan', 'black', 'Tinted windows.'),
  ('c0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000001', 'BIGMIKE1', 'Declasse Tornado', 'green', null),
  ('c0000000-0000-4000-8000-000000000003', null, 'XR3NCH', 'Bravado Buffalo', 'white', 'Seen leaving LS Customs after closing. Driver unknown.');

insert into public.cases (id, title, description, status) values
  ('d0000000-0000-4000-8000-000000000001', 'Operation Green Light', 'Chop-shop pipeline between Grove Street and LS Customs Burton.', 'open');

insert into public.case_links (case_id, person_id, organization_id, role) values
  ('d0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001', null, 'suspect'),
  ('d0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000003', null, 'suspect'),
  ('d0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000004', null, 'unidentified'),
  ('d0000000-0000-4000-8000-000000000001', null, 'a0000000-0000-4000-8000-000000000001', null),
  ('d0000000-0000-4000-8000-000000000001', null, 'a0000000-0000-4000-8000-000000000003', null);

insert into public.notes (person_id, organization_id, case_id, body, tags, source, confidence) values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'd0000000-0000-4000-8000-000000000001',
   'Informant says Big Mike moves the Sultans through Burton on Tuesday nights.', '{chop-shop,vehicles}', 'informant', 'medium'),
  ('b0000000-0000-4000-8000-000000000004', null, null,
   'Red Mask spotted again at the corner store, 23:10. Left in the black Sultan, partial plate 46EEK.', '{sighting}', 'patrol', 'high'),
  (null, 'a0000000-0000-4000-8000-000000000002', null,
   'Two new faces in yellow at the Rancho gas station. Possibly recruiting.', '{recruiting}', 'surveillance', 'low'),
  (null, null, null,
   'Anonymous tip: weapons drop near the Sandy Shores airfield this weekend.', '{weapons,tip}', 'tip', 'low'),
  ('b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003', 'd0000000-0000-4000-8000-000000000001',
   'Elena re-plated a white Buffalo without paperwork. Camera footage requested.', '{chop-shop,evidence}', 'surveillance', 'high');
