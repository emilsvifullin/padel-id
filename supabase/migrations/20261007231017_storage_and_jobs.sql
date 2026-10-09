-- Avatars storage and scheduled maintenance.

-- Public bucket: avatars are part of public player cards. Object names are
-- `<user id>/<random>.jpg`; only the owner can write into their folder. The
-- iOS client never talks to Storage directly — uploads and downloads go
-- through the Padel ID API gateway.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars: owner can read own objects" on storage.objects;
drop policy if exists "avatars: owner can upload" on storage.objects;
drop policy if exists "avatars: owner can update" on storage.objects;
drop policy if exists "avatars: owner can delete" on storage.objects;

create policy "avatars: owner can read own objects" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: owner can upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: owner can update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatars: owner can delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Hourly expiry of unresolved matches and rate-limit housekeeping.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.unschedule(jobid) from cron.job where jobname = 'padelid-expire-matches';
    perform cron.schedule('padelid-expire-matches', '17 * * * *', 'select private.expire_stale_matches()');
  end if;
end;
$$;
