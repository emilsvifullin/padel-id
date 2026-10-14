-- Apply only after the protected-avatar API/client is available. Legacy public
-- URLs intentionally stop working; never restore public access for compatibility.
update storage.buckets set public = false where id = 'avatars';

-- Storage must enforce the same live-session and bilateral visibility boundary
-- as the API, because a caller can also address Storage directly. A narrow
-- definer is needed to inspect non-exposed profile/session/social tables.
create function private.avatar_access(p_name text, p_owner_only boolean default false)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare u uuid; owner uuid;
begin
  if p_name !~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{8,64}\.jpg$' then return false; end if;
  u := private.require_uid();
  perform private.require_active_player(u);
  owner := split_part(p_name, '/', 1)::uuid;
  if owner = u then return true; end if;
  if p_owner_only then return false; end if;
  return exists(select 1 from public.profiles p where p.id = owner
    and p.deleted_at is null and p.avatar_path = p_name)
    and private.socially_visible(u, owner);
exception when others then
  -- Revoked/expired sessions and malformed object names deny rather than
  -- leaking profile/session details through the Storage service.
  return false;
end $$;
revoke all on function private.avatar_access(text,boolean) from public,anon,authenticated,service_role;
grant execute on function private.avatar_access(text,boolean) to authenticated;

drop policy "avatars: owner can read own objects" on storage.objects;
drop policy "avatars: owner can upload" on storage.objects;
drop policy "avatars: owner can update" on storage.objects;
drop policy "avatars: owner can delete" on storage.objects;
create policy "avatars: visible player read" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and private.avatar_access(name)
    -- Signed/copy/move URLs would outlive later blocks/session revocation.
    -- Owner writes need SELECT too; actual ownership stays in their policies.
    and storage.allow_any_operation(array['object.get_authenticated',
      'object.get_authenticated_info','object.head_authenticated_info',
      'object.upload','object.upload_update','object.delete','object.delete_many']));
create policy "avatars: owner can upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and private.avatar_access(name,true)
    -- Storage's update permission probe uses an upsert, so INSERT must also
    -- allow the authenticated update operation (never a signed upload).
    and storage.allow_any_operation(array['object.upload','object.upload_update']));
create policy "avatars: owner can update" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and private.avatar_access(name,true)
    and storage.allow_any_operation(array['object.upload','object.upload_update']))
  with check (bucket_id = 'avatars' and private.avatar_access(name,true)
    and storage.allow_any_operation(array['object.upload','object.upload_update']));
create policy "avatars: owner can delete" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and private.avatar_access(name,true)
    and storage.allow_any_operation(array['object.delete','object.delete_many']));
