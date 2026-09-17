-- Evidence items can be an uploaded file (storage_path, arriving with uploads)
-- OR an external link (url): Medal.tv clips, YouTube, Streamable, or a direct
-- image URL. Exactly one of the two is set.
alter table public.evidence
  alter column storage_path drop not null,
  add column url text,
  add constraint evidence_file_or_url check ((storage_path is null) <> (url is null)),
  add constraint evidence_url_is_http check (url is null or url ~* '^https?://\S+$');

create index evidence_created_at_idx on public.evidence (created_at desc);
