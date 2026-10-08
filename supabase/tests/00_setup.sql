-- Test helpers for the Padel ID database suite. Loaded into a disposable test
-- database only (local PostgreSQL or the Supabase CLI stack in CI).

drop schema if exists tests cascade;
create schema tests;
grant usage on schema tests to anon, authenticated, service_role;
alter default privileges in schema tests grant execute on functions to anon, authenticated, service_role;

create function tests.new_user(p_email text, p_password text default 'Correct-Horse-7')
returns uuid
language plpgsql
as $$
declare
  v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, encrypted_password)
  values (v, p_email, extensions.crypt(p_password, extensions.gen_salt('bf')));
  return v;
end;
$$;

create function tests.act_as(p_uid uuid)
returns void
language plpgsql
as $$
declare
  v_session uuid;
begin
  execute 'reset role';
  select id into v_session from auth.sessions where user_id = p_uid order by created_at limit 1;
  if v_session is null then
    v_session := gen_random_uuid();
    insert into auth.sessions (id, user_id) values (v_session, p_uid);
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'session_id', v_session)::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
end;
$$;

create function tests.act_as_anon()
returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
end;
$$;

create function tests.act_as_service()
returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role service_role';
end;
$$;

create function tests.as_admin()
returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

create function tests.assert(p_cond boolean, p_msg text)
returns void
language plpgsql
as $$
begin
  if p_cond is distinct from true then
    raise exception 'ASSERTION FAILED: %', p_msg;
  end if;
end;
$$;

create function tests.assert_eq(p_actual anyelement, p_expected anyelement, p_msg text)
returns void
language plpgsql
as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'ASSERTION FAILED: % (expected %, got %)', p_msg, p_expected, p_actual;
  end if;
end;
$$;

create function tests.assert_near(p_actual double precision, p_expected double precision, p_tol double precision, p_msg text)
returns void
language plpgsql
as $$
begin
  if p_actual is null or abs(p_actual - p_expected) > p_tol then
    raise exception 'ASSERTION FAILED: % (expected % ± %, got %)', p_msg, p_expected, p_tol, p_actual;
  end if;
end;
$$;

-- Executes p_sql and asserts that it fails with the application error p_code
-- (or SQLSTATE p_code when it looks like one).
create function tests.expect_error(p_sql text, p_code text, p_msg text default null)
returns void
language plpgsql
as $$
declare
  v_message text;
  v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_message = message_text, v_state = returned_sqlstate;
    if v_message = p_code or v_state = p_code then
      return;
    end if;
    raise exception 'ASSERTION FAILED: % — expected error %, got % (%)', coalesce(p_msg, p_sql), p_code, v_message, v_state;
  end;
  raise exception 'ASSERTION FAILED: % — expected error %, but statement succeeded', coalesce(p_msg, p_sql), p_code;
end;
$$;

-- Creates and onboards a player. p_glass/p_net steer the calibrated level.
create function tests.player(p_username text, p_glass integer default 2, p_net integer default 1, p_city integer default 1)
returns uuid
language plpgsql
as $$
declare
  v uuid := tests.new_user(p_username || '@padel.test');
begin
  perform tests.act_as(v);
  perform public.complete_onboarding(jsonb_build_object(
    'username', p_username,
    'display_name', initcap(replace(p_username, '_', ' ')),
    'city_id', p_city,
    'preferred_side', 'both',
    'dominant_hand', 'right',
    'calibration', jsonb_build_object('experience', '1to3y', 'frequency', 'weekly', 'racket', 'amateur',
                                      'glass', p_glass, 'net', p_net, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 0, 'transition_lob', 0,
                                   'net_game', 0, 'overheads', 0, 'consistency_decisions', 0)
  ));
  perform tests.as_admin();
  return v;
end;
$$;

create function tests.lineup(p uuid[])
returns jsonb
language sql
as $$
  select jsonb_build_array(
    jsonb_build_object('player_id', p[1], 'team', 1, 'court_side', 'right'),
    jsonb_build_object('player_id', p[2], 'team', 1, 'court_side', 'left'),
    jsonb_build_object('player_id', p[3], 'team', 2, 'court_side', 'right'),
    jsonb_build_object('player_id', p[4], 'team', 2, 'court_side', 'left')
  )
$$;

create function tests.sets(variadic p integer[])
returns jsonb
language sql
as $$
  select coalesce(jsonb_agg(jsonb_build_object('t1', p[i], 't2', p[i + 1]) order by i), '[]'::jsonb)
    from generate_series(1, cardinality(p), 2) i
$$;

-- Creates a match as p_players[1] and returns its id.
create function tests.match(p_players uuid[], p_type text default 'ranked', p_sets jsonb default null, p_format text default 'best_of_3', p_played_at timestamptz default null)
returns uuid
language plpgsql
as $$
declare
  v jsonb;
begin
  perform tests.act_as(p_players[1]);
  v := public.create_match(jsonb_build_object(
    'match_type', p_type,
    'format', p_format,
    'played_at', coalesce(p_played_at, now() - interval '2 hours'),
    'players', tests.lineup(p_players),
    'sets', coalesce(p_sets, tests.sets(6, 4, 6, 3))
  ), gen_random_uuid());
  perform tests.as_admin();
  return (v ->> 'id')::uuid;
end;
$$;

create function tests.version(p_match uuid)
returns integer
language sql
security definer
set search_path = ''
as $$ select version from public.matches where id = p_match $$;

-- All other participants confirm.
create function tests.confirm_all(p_match uuid)
returns void
language plpgsql
as $$
declare
  v uuid;
  ids uuid[];
begin
  perform tests.as_admin();
  select array_agg(player_id order by player_id) into ids
    from public.match_players where match_id = p_match and response <> 'confirmed';
  foreach v in array coalesce(ids, '{}') loop
    perform tests.act_as(v);
    perform public.confirm_match(p_match, tests.version(p_match));
  end loop;
  perform tests.as_admin();
end;
$$;
