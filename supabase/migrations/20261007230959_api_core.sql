-- Padel ID public API (part 1): identity, profile, onboarding, reference data.
-- All public functions are SECURITY DEFINER with an empty search_path and
-- explicit authorization checks. Execute privileges are granted at the end of
-- the API migrations.

-- ---------------------------------------------------------------------------
-- JSON building blocks
-- ---------------------------------------------------------------------------

create or replace function private.rating_json(p_player uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'mu', round(r.mu::numeric, 2),
    'sigma', round(private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now())::numeric, 3),
    'reliability', private.reliability(private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now())),
    'provisional', r.ranked_matches < 5
      or private.reliability(private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now())) < 40,
    'ranked_matches', r.ranked_matches,
    'ranked_wins', r.ranked_wins,
    'peak_mu', round(r.peak_mu::numeric, 2),
    'initial_mu', round((r.calibration ->> 'mu')::numeric, 2),
    'last_ranked_at', r.last_ranked_at,
    'idle_days', floor(extract(epoch from (now() - coalesce(r.last_ranked_at, r.created_at))) / 86400.0)::integer,
    'trend_30d', round((r.mu - coalesce((
        select e.mu_after from public.rating_events e
         where e.player_id = r.player_id and e.created_at <= now() - interval '30 days'
         order by e.created_at desc limit 1
      ), (
        select e.mu_before from public.rating_events e
         where e.player_id = r.player_id and e.kind = 'match' and e.created_at > now() - interval '30 days'
         order by e.created_at asc limit 1
      ), r.mu))::numeric, 2)
  )
    from public.player_ratings r
   where r.player_id = p_player
$$;

-- Compact player representation used in lists, pickers and match line-ups.
create or replace function private.player_card(p_player uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select case when p.deleted_at is not null then
    jsonb_build_object(
      'id', p.id,
      'username', null,
      'display_name', 'Удалённый игрок',
      'deleted', true,
      'avatar_path', null,
      'city', null,
      'club', null,
      'preferred_side', null,
      'is_coach', false,
      'level', round(r.mu::numeric, 2),
      'reliability', null
    )
  else
    jsonb_build_object(
      'id', p.id,
      'username', p.username,
      'display_name', p.display_name,
      'deleted', false,
      'avatar_path', p.avatar_path,
      'city', case when c.id is null then null else jsonb_build_object('id', c.id, 'name', c.name) end,
      'club', case when cl.id is null then null else jsonb_build_object('id', cl.id, 'name', cl.name) end,
      'preferred_side', p.preferred_side,
      'is_coach', p.is_coach,
      'level', round(r.mu::numeric, 2),
      'reliability', private.reliability(private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now()))
    )
  end
    from public.profiles p
    left join public.player_ratings r on r.player_id = p.id
    left join public.cities c on c.id = p.city_id
    left join public.clubs cl on cl.id = p.club_id
   where p.id = p_player
$$;

create or replace function private.profile_json(p_player uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select private.player_card(p.id) || case when p.deleted_at is not null then '{}'::jsonb else jsonb_build_object(
      'dominant_hand', p.dominant_hand,
      'playing_since', p.playing_since,
      'bio', p.bio,
      'discoverable', p.discoverable,
      'member_since', p.created_at
    ) end
    from public.profiles p
   where p.id = p_player
$$;

-- Asserts that a player exists, is not deleted and has completed onboarding.
create or replace function private.require_active_player(p_player uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles p
      join public.player_ratings r on r.player_id = p.id
     where p.id = p_player and p.deleted_at is null
  ) then
    perform private.fail('player_not_found', p_player::text);
  end if;
end;
$$;

-- Fixed-window rate limiter backed by private.rate_limits.
create or replace function private.hit_rate_limit(p_bucket text, p_limit integer, p_window_seconds integer)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_hits integer;
begin
  insert into private.rate_limits (bucket, window_start, hits)
  values (p_bucket, v_window, 1)
  on conflict (bucket, window_start) do update set hits = private.rate_limits.hits + 1
  returning hits into v_hits;
  return v_hits <= p_limit;
end;
$$;

create or replace function private.validate_username(p_username text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := lower(btrim(coalesce(p_username, '')));
begin
  if v !~ '^[a-z0-9_]{3,20}$' then
    perform private.fail('username_invalid');
  end if;
  if v in ('admin', 'administrator', 'padelid', 'padel_id', 'support', 'help', 'root', 'system',
           'moderator', 'official', 'staff', 'team', 'null', 'undefined')
     or v like 'deleted%' then
    perform private.fail('username_reserved');
  end if;
  return v;
end;
$$;

create or replace function private.validate_display_name(p_name text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  if char_length(v) < 2 or char_length(v) > 40 then
    perform private.fail('display_name_invalid');
  end if;
  if v !~ '^[[:alpha:]][[:alpha:][:space:].''’-]*$' then
    perform private.fail('display_name_invalid');
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

create or replace function public.me()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  return jsonb_build_object(
    'user_id', v_uid,
    'email', (select u.email from auth.users u where u.id = v_uid),
    'needs_onboarding', not exists (select 1 from public.profiles where id = v_uid and deleted_at is null),
    'is_admin', exists (select 1 from private.admins where user_id = v_uid),
    'profile', private.profile_json(v_uid),
    'rating', private.rating_json(v_uid),
    'dna_self', (select answers from public.dna_self_assessments where player_id = v_uid),
    'coach_status', (select status from public.coach_applications where player_id = v_uid),
    'recovery_key_created_at', (select created_at from private.recovery_keys where user_id = v_uid)
  );
end;
$$;

create or replace function public.check_username(p_username text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v text;
begin
  begin
    v := private.validate_username(p_username);
  exception when sqlstate 'P0001' then
    return jsonb_build_object('username', lower(btrim(coalesce(p_username, ''))), 'valid', false, 'available', false, 'reason', sqlerrm);
  end;
  return jsonb_build_object(
    'username', v,
    'valid', true,
    'available', not exists (select 1 from public.profiles where username = v and id <> v_uid),
    'reason', null
  );
end;
$$;

create or replace function private.validate_dna_self(p_answers jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  k text;
  v jsonb;
begin
  if p_answers is null or private.jtype(p_answers) <> 'object' then
    perform private.fail('invalid_dna_self');
  end if;
  for k, v in select key, value from jsonb_each(p_answers) loop
    if not (k = any (private.dna_dimensions()))
       or private.jtype(v) <> 'number'
       or (v::text)::numeric not in (-2, -1, 0, 1, 2) then
      perform private.fail('invalid_dna_self');
    end if;
  end loop;
  if (select count(*) from jsonb_object_keys(p_answers)) <> 6 then
    perform private.fail('invalid_dna_self');
  end if;
  return p_answers;
end;
$$;

create or replace function public.complete_onboarding(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_username text;
  v_name text;
  v_city integer;
  v_club bigint;
  v_cal jsonb;
  v_since smallint;
begin
  if exists (select 1 from public.profiles where id = v_uid) then
    -- Idempotent: a retried request after a successful onboarding returns the
    -- current state instead of failing.
    return public.me();
  end if;
  if not exists (select 1 from auth.users where id = v_uid) then
    perform private.fail('not_authenticated');
  end if;

  v_username := private.validate_username(p ->> 'username');
  v_name := private.validate_display_name(p ->> 'display_name');

  if private.jtype(p -> 'city_id') <> 'number' then
    perform private.fail('city_required');
  end if;
  v_city := (p ->> 'city_id')::integer;
  if not exists (select 1 from public.cities where id = v_city) then
    perform private.fail('city_not_found');
  end if;

  if p ? 'club_id' and private.jtype(p -> 'club_id') = 'number' then
    v_club := (p ->> 'club_id')::bigint;
    if not exists (select 1 from public.clubs where id = v_club and city_id = v_city) then
      perform private.fail('club_not_found');
    end if;
  end if;

  if coalesce(p ->> 'preferred_side', '') not in ('left', 'right', 'both') then
    perform private.fail('invalid_side');
  end if;
  if coalesce(p ->> 'dominant_hand', '') not in ('left', 'right') then
    perform private.fail('invalid_hand');
  end if;
  if private.jtype(p -> 'playing_since') = 'number' then
    v_since := (p ->> 'playing_since')::smallint;
    if v_since < 1970 or v_since > extract(year from now()) then
      perform private.fail('invalid_playing_since');
    end if;
  end if;

  v_cal := private.calibrate(p -> 'calibration');

  if exists (select 1 from public.profiles where username = v_username) then
    perform private.fail('username_taken');
  end if;

  insert into public.profiles (id, username, display_name, city_id, club_id, preferred_side, dominant_hand, playing_since)
  values (v_uid, v_username, v_name, v_city, v_club, p ->> 'preferred_side', p ->> 'dominant_hand', v_since);

  insert into public.player_ratings (player_id, mu, sigma, peak_mu, calibration)
  values (v_uid, (v_cal ->> 'mu')::double precision, (v_cal ->> 'sigma')::double precision,
          (v_cal ->> 'mu')::double precision, v_cal);

  insert into public.rating_events (player_id, kind, mu_after, sigma_after, details)
  values (v_uid, 'calibration', (v_cal ->> 'mu')::double precision, (v_cal ->> 'sigma')::double precision,
          jsonb_build_object('answers', v_cal -> 'answers'));

  if p ? 'dna_self' and private.jtype(p -> 'dna_self') = 'object' then
    insert into public.dna_self_assessments (player_id, answers)
    values (v_uid, private.validate_dna_self(p -> 'dna_self'));
  end if;

  perform private.recompute_dna(v_uid);
  return public.me();
exception
  when unique_violation then
    perform private.fail('username_taken');
end;
$$;

create or replace function public.update_profile(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  cur public.profiles%rowtype;
  v_username text;
  v_city integer;
  v_club bigint;
begin
  select * into cur from public.profiles where id = v_uid and deleted_at is null for update;
  if not found then
    perform private.fail('onboarding_required');
  end if;
  if p is null or private.jtype(p) <> 'object' then
    perform private.fail('invalid_request');
  end if;

  v_username := cur.username;
  if p ? 'username' then
    v_username := private.validate_username(p ->> 'username');
    if v_username <> cur.username and exists (select 1 from public.profiles where username = v_username) then
      perform private.fail('username_taken');
    end if;
  end if;

  v_city := cur.city_id;
  v_club := cur.club_id;
  if p ? 'city_id' then
    if private.jtype(p -> 'city_id') <> 'number' or not exists (select 1 from public.cities where id = (p ->> 'city_id')::integer) then
      perform private.fail('city_not_found');
    end if;
    v_city := (p ->> 'city_id')::integer;
    if v_city is distinct from cur.city_id then
      v_club := null;
    end if;
  end if;
  if p ? 'club_id' then
    if private.jtype(p -> 'club_id') = 'null' then
      v_club := null;
    elsif private.jtype(p -> 'club_id') <> 'number'
       or not exists (select 1 from public.clubs where id = (p ->> 'club_id')::bigint and city_id = v_city) then
      perform private.fail('club_not_found');
    else
      v_club := (p ->> 'club_id')::bigint;
    end if;
  end if;

  if p ? 'preferred_side' and coalesce(p ->> 'preferred_side', '') not in ('left', 'right', 'both') then
    perform private.fail('invalid_side');
  end if;
  if p ? 'dominant_hand' and coalesce(p ->> 'dominant_hand', '') not in ('left', 'right') then
    perform private.fail('invalid_hand');
  end if;
  if p ? 'playing_since' and private.jtype(p -> 'playing_since') = 'number'
     and ((p ->> 'playing_since')::integer < 1970 or (p ->> 'playing_since')::integer > extract(year from now())) then
    perform private.fail('invalid_playing_since');
  end if;
  if p ? 'bio' and private.jtype(p -> 'bio') = 'string' and char_length(btrim(p ->> 'bio')) > 160 then
    perform private.fail('bio_too_long');
  end if;
  if p ? 'discoverable' and private.jtype(p -> 'discoverable') <> 'boolean' then
    perform private.fail('invalid_request');
  end if;

  update public.profiles set
    username = v_username,
    display_name = case when p ? 'display_name' then private.validate_display_name(p ->> 'display_name') else display_name end,
    city_id = v_city,
    club_id = v_club,
    preferred_side = case when p ? 'preferred_side' then p ->> 'preferred_side' else preferred_side end,
    dominant_hand = case when p ? 'dominant_hand' then p ->> 'dominant_hand' else dominant_hand end,
    playing_since = case when p ? 'playing_since' then
      case when private.jtype(p -> 'playing_since') = 'number' then (p ->> 'playing_since')::smallint else null end
      else playing_since end,
    bio = case when p ? 'bio' then nullif(btrim(coalesce(p ->> 'bio', '')), '') else bio end,
    discoverable = case when p ? 'discoverable' then (p ->> 'discoverable')::boolean else discoverable end
  where id = v_uid;

  return public.me();
exception
  when unique_violation then
    perform private.fail('username_taken');
end;
$$;

create or replace function public.set_avatar(p_path text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if not exists (select 1 from public.profiles where id = v_uid and deleted_at is null) then
    perform private.fail('onboarding_required');
  end if;
  if p_path is not null and (
       p_path !~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{8,64}\.jpg$'
       or split_part(p_path, '/', 1) <> v_uid::text
     ) then
    perform private.fail('invalid_avatar_path');
  end if;
  update public.profiles set avatar_path = p_path where id = v_uid;
  return public.me();
end;
$$;

create or replace function public.set_dna_self(p_answers jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform private.require_active_player(v_uid);
  insert into public.dna_self_assessments (player_id, answers, updated_at)
  values (v_uid, private.validate_dna_self(p_answers), now())
  on conflict (player_id) do update set answers = excluded.answers, updated_at = now();
  perform private.recompute_dna(v_uid);
  return private.dna_json(v_uid);
end;
$$;

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------

create or replace function public.list_cities(p_query text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  q text := private.norm(p_query);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'country_code', c.country_code)
                     order by c.sort_order, c.country_code <> 'RU', c.name)
      from public.cities c
     where q = '' or c.name_norm like '%' || q || '%'
  ), '[]'::jsonb);
end;
$$;

create or replace function public.list_clubs(p_city_id integer, p_query text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  q text := private.norm(p_query);
begin
  return coalesce((
    select jsonb_agg(x.obj order by x.players desc, x.name)
      from (
        select cl.name,
               (select count(*) from public.profiles p where p.club_id = cl.id and p.deleted_at is null) as players,
               jsonb_build_object(
                 'id', cl.id,
                 'name', cl.name,
                 'city_id', cl.city_id,
                 'players_count', (select count(*) from public.profiles p where p.club_id = cl.id and p.deleted_at is null)
               ) as obj
          from public.clubs cl
         where cl.city_id = p_city_id
           and (q = '' or cl.name_norm like '%' || q || '%')
         limit 100
      ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.create_club(p_city_id integer, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_id bigint;
begin
  if not exists (select 1 from public.cities where id = p_city_id) then
    perform private.fail('city_not_found');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 or v_name !~ '[[:alnum:]]' then
    perform private.fail('club_name_invalid');
  end if;

  select id into v_id from public.clubs where city_id = p_city_id and name_norm = private.norm(v_name);
  if v_id is null then
    if not private.hit_rate_limit('create_club:' || v_uid, 10, 86400) then
      perform private.fail('rate_limited');
    end if;
    insert into public.clubs (city_id, name, created_by)
    values (p_city_id, v_name,
            case when exists (select 1 from public.profiles where id = v_uid) then v_uid end)
    on conflict (city_id, name_norm) do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.clubs where city_id = p_city_id and name_norm = private.norm(v_name);
    end if;
  end if;

  return (select jsonb_build_object('id', cl.id, 'name', cl.name, 'city_id', cl.city_id,
                                    'players_count', (select count(*) from public.profiles p where p.club_id = cl.id and p.deleted_at is null))
            from public.clubs cl where cl.id = v_id);
end;
$$;
