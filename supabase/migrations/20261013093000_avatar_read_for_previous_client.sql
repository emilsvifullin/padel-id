-- Padel ID 1.1.0 asks the gateway for avatars without a session. While that
-- build is still supported, the gateway may read on its behalf the current
-- photo of a player who is not hidden. Storage itself stays private: without
-- the gateway secret the anonymous role reads nothing, and hidden profiles and
-- photos that are no longer current are refused even to the gateway. A caller
-- with a session keeps the stricter 1.2.0 rules (blocks, live session).
-- Drop this policy when the minimum client build is raised past 1.1.0.
create function private.avatar_gateway_access(p_name text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare presented text; owner uuid;
begin
  if p_name !~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{8,64}\.jpg$' then return false; end if;
  presented := nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-padelid-gateway';
  if presented is null or not private.bff_secret_valid(presented) then return false; end if;
  owner := split_part(p_name, '/', 1)::uuid;
  return exists(select 1 from public.profiles p where p.id = owner
    and p.deleted_at is null and p.discoverable and p.avatar_path = p_name);
exception when others then
  -- A malformed header or name denies instead of failing the Storage request.
  return false;
end $$;
revoke all on function private.avatar_gateway_access(text) from public, anon, authenticated, service_role;
grant execute on function private.avatar_gateway_access(text) to anon;

create policy "avatars: gateway read for the previous client" on storage.objects for select to anon
  using (bucket_id = 'avatars' and private.avatar_gateway_access(name)
    and storage.allow_any_operation(array['object.get_authenticated']));
