-- Padel ID public API (part 4): coaches, administration, account security and
-- service-only operations; privileges for the whole API surface.

-- ---------------------------------------------------------------------------
-- Coaches
-- ---------------------------------------------------------------------------

create or replace function private.coach_application_json(p_player uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'player', private.player_card(a.player_id),
    'status', a.status,
    'experience_years', a.experience_years,
    'certification', a.certification,
    'about', a.about,
    'club', (select jsonb_build_object('id', cl.id, 'name', cl.name) from public.clubs cl where cl.id = a.club_id),
    'submitted_at', a.submitted_at,
    'reviewed_at', a.reviewed_at,
    'review_note', a.review_note
  )
    from public.coach_applications a
   where a.player_id = p_player
$$;

create or replace function public.coach_application()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  return private.coach_application_json(v_uid);
end;
$$;

create or replace function public.submit_coach_application(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_years integer;
  v_about text := btrim(coalesce(p ->> 'about', ''));
  v_cert text := nullif(btrim(coalesce(p ->> 'certification', '')), '');
  v_club bigint;
  v_current text;
begin
  perform private.require_active_player(v_uid);
  if private.jtype(p -> 'experience_years') <> 'number' then
    perform private.fail('invalid_coach_application');
  end if;
  v_years := (p ->> 'experience_years')::integer;
  if v_years < 0 or v_years > 60 or char_length(v_about) < 20 or char_length(v_about) > 500
     or char_length(v_cert) > 120 then
    perform private.fail('invalid_coach_application');
  end if;
  if private.jtype(p -> 'club_id') = 'number' then
    v_club := (p ->> 'club_id')::bigint;
    if not exists (select 1 from public.clubs where id = v_club) then
      perform private.fail('club_not_found');
    end if;
  end if;

  select status into v_current from public.coach_applications where player_id = v_uid for update;
  if v_current = 'revoked' then
    perform private.fail('coach_revoked');
  end if;

  insert into public.coach_applications (player_id, status, experience_years, certification, about, club_id, submitted_at)
  values (v_uid, 'pending', v_years, v_cert, v_about, v_club, now())
  on conflict (player_id) do update set
    status = case when public.coach_applications.status = 'approved' then 'approved' else 'pending' end,
    experience_years = excluded.experience_years,
    certification = excluded.certification,
    about = excluded.about,
    club_id = excluded.club_id,
    submitted_at = case when public.coach_applications.status = 'approved' then public.coach_applications.submitted_at else now() end,
    reviewed_at = case when public.coach_applications.status = 'approved' then public.coach_applications.reviewed_at end,
    review_note = case when public.coach_applications.status = 'approved' then public.coach_applications.review_note end;

  return private.coach_application_json(v_uid);
end;
$$;

create or replace function public.submit_coach_assessment(p_player uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_scores jsonb := p -> 'scores';
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  k text;
  v jsonb;
  v_mu double precision;
begin
  if not exists (select 1 from public.coach_applications where player_id = v_uid and status = 'approved') then
    perform private.fail('not_a_coach');
  end if;
  if p_player = v_uid then
    perform private.fail('cannot_assess_self');
  end if;
  perform private.require_active_player(p_player);

  if v_scores is null or private.jtype(v_scores) <> 'object'
     or (select count(*) from jsonb_object_keys(v_scores)) <> 6 then
    perform private.fail('invalid_assessment');
  end if;
  for k, v in select key, value from jsonb_each(v_scores) loop
    if not (k = any (private.dna_dimensions())) or private.jtype(v) <> 'number'
       or (v::text)::numeric < 0 or (v::text)::numeric > 7 or ((v::text)::numeric * 2) % 1 <> 0 then
      perform private.fail('invalid_assessment');
    end if;
  end loop;
  if char_length(v_note) > 500 then
    perform private.fail('invalid_assessment');
  end if;

  if exists (select 1 from public.coach_assessments
              where coach_id = v_uid and player_id = p_player and created_at > now() - interval '24 hours') then
    perform private.fail('assessment_too_soon');
  end if;

  select mu into v_mu from public.player_ratings where player_id = p_player;
  insert into public.coach_assessments (coach_id, player_id, scores, player_mu_at, note)
  values (v_uid, p_player, v_scores, v_mu, v_note);

  perform private.recompute_dna(p_player);
  return public.player_profile(p_player);
end;
$$;

create or replace function private.require_admin()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if not exists (select 1 from private.admins where user_id = v_uid) then
    perform private.fail('forbidden');
  end if;
  return v_uid;
end;
$$;

create or replace function public.admin_coach_applications(p_status text default 'pending')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_admin();
begin
  if p_status not in ('pending', 'approved', 'rejected', 'revoked') then
    perform private.fail('invalid_request');
  end if;
  return coalesce((
    select jsonb_agg(private.coach_application_json(a.player_id) order by a.submitted_at)
      from public.coach_applications a
      join public.profiles p on p.id = a.player_id and p.deleted_at is null
     where a.status = p_status
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_review_coach(p_player uuid, p_decision text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_admin();
  v_current text;
  v_affected uuid;
begin
  if p_decision not in ('approved', 'rejected', 'revoked') then
    perform private.fail('invalid_request');
  end if;
  if char_length(p_note) > 300 then
    perform private.fail('invalid_request');
  end if;
  select status into v_current from public.coach_applications where player_id = p_player for update;
  if v_current is null then
    perform private.fail('application_not_found');
  end if;
  if p_decision = 'revoked' and v_current <> 'approved' then
    perform private.fail('invalid_request');
  end if;

  update public.coach_applications
     set status = p_decision, reviewed_at = now(), reviewed_by = v_uid, review_note = nullif(btrim(coalesce(p_note, '')), '')
   where player_id = p_player;
  update public.profiles set is_coach = (p_decision = 'approved') where id = p_player;

  -- Coach status changes the weight of this coach's assessments.
  for v_affected in select distinct player_id from public.coach_assessments where coach_id = p_player loop
    perform private.recompute_dna(v_affected);
  end loop;

  return private.coach_application_json(p_player);
end;
$$;

-- ---------------------------------------------------------------------------
-- Account security
-- ---------------------------------------------------------------------------

-- Generates a recovery key (20 Crockford base32 symbols ≈ 100 bits), stores its
-- SHA-256 and returns the plain key exactly once.
create or replace function private.issue_recovery_key(p_user uuid)
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  bytes bytea := extensions.gen_random_bytes(20);
  raw text := '';
  v_key text;
begin
  for i in 0..19 loop
    raw := raw || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  end loop;
  v_key := substr(raw, 1, 5) || '-' || substr(raw, 6, 5) || '-' || substr(raw, 11, 5) || '-' || substr(raw, 16, 5);
  insert into private.recovery_keys (user_id, key_hash, created_at)
  values (p_user, extensions.digest(raw, 'sha256'), now())
  on conflict (user_id) do update set key_hash = excluded.key_hash, created_at = now();
  return v_key;
end;
$$;

create or replace function private.normalize_recovery_key(p_key text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(upper(regexp_replace(coalesce(p_key, ''), '[^0-9A-Za-z]', '', 'g')), 'OIL', '011')
$$;

create or replace function private.check_password(p_user uuid, p_password text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
     where u.id = p_user
       and u.encrypted_password is not null
       and u.encrypted_password = extensions.crypt(coalesce(p_password, ''), u.encrypted_password)
  )
$$;

-- Verifies the caller's password (used before sensitive account changes).
create or replace function public.verify_my_password(p_password text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if not private.hit_rate_limit('verify_password:' || v_uid, 10, 900) then
    perform private.fail('rate_limited');
  end if;
  return private.check_password(v_uid, p_password);
end;
$$;

create or replace function public.regenerate_recovery_key(p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if not private.hit_rate_limit('verify_password:' || v_uid, 10, 900) then
    perform private.fail('rate_limited');
  end if;
  if not private.check_password(v_uid, p_password) then
    perform private.fail('invalid_password');
  end if;
  return jsonb_build_object('recovery_key', private.issue_recovery_key(v_uid));
end;
$$;

-- ---------------------------------------------------------------------------
-- Service-only operations (called by the privileged account service with the
-- service role; never exposed to end users).
-- ---------------------------------------------------------------------------

create or replace function private.bff_secret_valid(p_secret text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from private.bff_secret
     where secret_hash = extensions.digest(coalesce(p_secret, ''), 'sha256')
       and char_length(coalesce(p_secret, '')) >= 32
  )
$$;

create or replace function public.svc_bff_secret_valid(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.bff_secret_valid(p_secret)
$$;

-- Rate limiting for the public API gateway; requires the gateway secret.
create or replace function public.bff_rate_limit(p_secret text, p_bucket text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.bff_secret_valid(p_secret) then
    perform private.fail('forbidden');
  end if;
  if p_bucket is null or char_length(p_bucket) > 200 or p_limit < 1 or p_window_seconds not between 1 and 86400 then
    perform private.fail('invalid_request');
  end if;
  return private.hit_rate_limit('bff:' || p_bucket, p_limit, p_window_seconds);
end;
$$;

create or replace function public.svc_issue_recovery_key(p_user uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from auth.users where id = p_user) then
    perform private.fail('user_not_found');
  end if;
  return private.issue_recovery_key(p_user);
end;
$$;

-- Returns the user id when the recovery key matches the account, else null.
create or replace function public.svc_check_recovery_key(p_email text, p_key text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid;
  v_hash bytea;
begin
  select u.id into v_user from auth.users u where lower(u.email) = lower(btrim(coalesce(p_email, '')));
  select key_hash into v_hash from private.recovery_keys where user_id = v_user;
  if v_user is null or v_hash is null
     or v_hash <> extensions.digest(private.normalize_recovery_key(p_key), 'sha256') then
    return null;
  end if;
  return v_user;
end;
$$;

create or replace function public.svc_check_password(p_user uuid, p_password text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.check_password(p_user, p_password)
$$;

create or replace function public.svc_revoke_sessions(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from auth.sessions where user_id = p_user;
end;
$$;

-- Removes personal data while keeping match history consistent for the other
-- participants (the player becomes "Удалённый игрок").
create or replace function public.svc_anonymize_account(p_user uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_affected uuid;
  v_affected_ids uuid[];
begin
  select coalesce(array_agg(distinct player_id), '{}') into v_affected_ids
    from public.coach_assessments where coach_id = p_user;

  update public.matches m
     set status = 'cancelled', closed_at = now()
   where m.status in ('pending', 'disputed')
     and exists (select 1 from public.match_players mp where mp.match_id = m.id and mp.player_id = p_user);

  delete from public.coach_assessments where coach_id = p_user or player_id = p_user;
  delete from public.coach_applications where player_id = p_user;
  delete from public.match_feedback where ratee_id = p_user;
  delete from public.dna_self_assessments where player_id = p_user;
  delete from public.player_dna_history where player_id = p_user;
  delete from public.player_dna where player_id = p_user;
  delete from private.recovery_keys where user_id = p_user;
  delete from private.admins where user_id = p_user;

  update public.profiles
     set username = 'deleted_' || substr(md5(p_user::text), 1, 10),
         display_name = 'Удалённый игрок',
         city_id = null,
         club_id = null,
         bio = null,
         avatar_path = null,
         playing_since = null,
         discoverable = false,
         is_coach = false,
         deleted_at = coalesce(deleted_at, now())
   where id = p_user;

  update public.clubs set created_by = null where created_by = p_user;

  foreach v_affected in array v_affected_ids loop
    perform private.recompute_dna(v_affected);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

do $$
declare
  f record;
begin
  -- Nothing in the private schema is callable by API roles.
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'private'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;

  -- Public API functions: authenticated users only, except service and gateway functions.
  for f in
    select p.oid::regprocedure as sig, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f.sig);
    if f.proname like 'svc\_%' then
      execute format('grant execute on function %s to service_role', f.sig);
    elsif f.proname = 'bff_rate_limit' then
      execute format('grant execute on function %s to anon, service_role', f.sig);
    else
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end;
$$;

-- Functions created later must not become callable by API roles implicitly.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;
