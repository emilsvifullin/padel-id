-- Every API call must come from a live session.
--
-- Access tokens are stateless JWTs that stay valid until they expire (1 hour),
-- even after the user signs out everywhere, resets the password or deletes the
-- account. The API therefore checks that the token's `session_id` still exists
-- in auth.sessions, which makes revocation immediate.

create or replace function private.require_uid()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v uuid := auth.uid();
  v_claims jsonb := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  v_session uuid;
begin
  if v is null then
    perform private.fail('not_authenticated');
  end if;
  begin
    v_session := nullif(v_claims ->> 'session_id', '')::uuid;
  exception when others then
    v_session := null;
  end;
  if v_session is null or not exists (
    select 1 from auth.sessions s where s.id = v_session and s.user_id = v
  ) then
    perform private.fail('session_expired');
  end if;
  return v;
end;
$$;

revoke all on function private.require_uid() from public, anon, authenticated;
