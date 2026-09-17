-- Deleting an organization was destroying every note attached to it, including
-- notes that are mainly about a person and only mention the gang. Intel should
-- outlive the organization: detach the note instead, which is how notes already
-- behave when a case is deleted.
--
-- Memberships and case links still cascade; they are join rows with no meaning
-- once the organization is gone. Evidence still cascades, because an evidence
-- row must always keep at least one target and detaching would strand rows that
-- were attached to the organization alone.
alter table public.notes
  drop constraint notes_organization_id_fkey,
  add constraint notes_organization_id_fkey
    foreign key (organization_id) references public.organizations (id) on delete set null;
