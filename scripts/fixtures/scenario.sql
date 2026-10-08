-- Padel ID fixture scenario.
--
-- Builds a realistic community in a dedicated local database (never the test
-- database `padelid`) exclusively through the public API functions, acting as
-- the individual users exactly like supabase/tests/00_setup.sql does
-- (auth.sessions row + request.jwt.claims + `set local role authenticated`).
--
-- Matches are entered oldest first with the real validation, confirmed by all
-- four players (which runs the real rating engine and Padel DNA updates) and
-- then moved into the past, so the history spans about 70 days. All ids are
-- deterministic, so regenerated fixtures only differ in timestamps and in
-- values that depend on the current time.
--
-- Run through scripts/fixtures/export.sh.

\set ON_ERROR_STOP on
set client_min_messages = warning;
set timezone = 'UTC';

drop schema if exists fixtures cascade;
create schema fixtures;
grant usage on schema fixtures to anon, authenticated, service_role;

create table fixtures.players (
  code text primary key,
  id uuid not null unique,
  email text not null unique
);

create table fixtures.refs (
  key text primary key,
  id uuid not null
);

-- Deterministic, well-formed (version 4 layout) UUID for a fixture key.
create function fixtures.uuid(p_key text)
returns uuid
language sql
immutable
as $$
  select (substr(h, 1, 12) || '4' || substr(h, 14, 3)
          || substr('89ab', (('x' || substr(h, 17, 1))::bit(4)::integer % 4) + 1, 1)
          || substr(h, 18, 15))::uuid
    from (select md5('padelid-fixtures:' || p_key) as h) x
$$;

-- A moment p_days before today at the given UTC time.
create function fixtures.at(p_days integer, p_time text)
returns timestamptz
language sql
stable
as $$
  select ((current_date - p_days)::timestamp + p_time::time) at time zone 'UTC'
$$;

create function fixtures.act_as(p_uid uuid)
returns void
language plpgsql
as $$
declare
  v_session uuid;
begin
  execute 'reset role';
  select id into v_session from auth.sessions where user_id = p_uid order by created_at limit 1;
  if v_session is null then
    raise exception 'fixture user % has no session', p_uid;
  end if;
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated', 'session_id', v_session)::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  execute 'set local role authenticated';
end;
$$;

create function fixtures.as_admin()
returns void
language plpgsql
as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end;
$$;

-- Executes the statements as the given user and returns the JSON result of the
-- last one as text ('null' for SQL NULL, exactly what the gateway returns).
create function fixtures.run_as(p_uid uuid, variadic p_sql text[])
returns text
language plpgsql
as $$
declare
  v jsonb;
  s text;
begin
  perform fixtures.act_as(p_uid);
  foreach s in array p_sql loop
    execute s into v;
  end loop;
  perform fixtures.as_admin();
  return coalesce(v::text, 'null');
end;
$$;

create function fixtures.pid(p_code text)
returns uuid
language plpgsql
volatile
as $$
declare
  v uuid;
begin
  select id into v from fixtures.players where code = p_code;
  if v is null then
    raise exception 'unknown fixture player %', p_code;
  end if;
  return v;
end;
$$;

-- Line-up [team 1 right, team 1 left, team 2 right, team 2 left].
create function fixtures.lineup(p_codes text[])
returns jsonb
language sql
volatile
as $$
  select jsonb_build_array(
    jsonb_build_object('player_id', fixtures.pid(p_codes[1]), 'team', 1, 'court_side', 'right'),
    jsonb_build_object('player_id', fixtures.pid(p_codes[2]), 'team', 1, 'court_side', 'left'),
    jsonb_build_object('player_id', fixtures.pid(p_codes[3]), 'team', 2, 'court_side', 'right'),
    jsonb_build_object('player_id', fixtures.pid(p_codes[4]), 'team', 2, 'court_side', 'left')
  )
$$;

create function fixtures.set(p_t1 integer, p_t2 integer, p_tb1 integer default null, p_tb2 integer default null)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('t1', p_t1, 't2', p_t2, 'super_tiebreak', false, 'tb1', p_tb1, 'tb2', p_tb2)
$$;

create function fixtures.stb(p_t1 integer, p_t2 integer)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('t1', p_t1, 't2', p_t2, 'super_tiebreak', true, 'tb1', null, 'tb2', null)
$$;

create function fixtures.club(p_name text)
returns bigint
language sql
volatile
as $$
  select id from public.clubs where name = p_name
$$;

-- Signs up a user: auth account, live session and recovery key.
create function fixtures.sign_up(p_code text, p_username text, p_email text)
returns uuid
language plpgsql
as $$
declare
  v uuid := fixtures.uuid('user:' || p_username);
begin
  perform fixtures.as_admin();
  insert into auth.users (id, email, encrypted_password)
  values (v, p_email, extensions.crypt('Padel-Fixture-2026', extensions.gen_salt('bf', 4)));
  insert into auth.sessions (id, user_id) values (fixtures.uuid('session:' || p_username), v);
  insert into fixtures.players (code, id, email) values (p_code, v, p_email);
  perform private.issue_recovery_key(v);
  return v;
end;
$$;

-- Completes onboarding through the API and dates the account p_days back.
create function fixtures.onboard(p_code text, p_payload jsonb, p_days integer, p_bio text default null)
returns void
language plpgsql
as $$
declare
  v uuid := fixtures.pid(p_code);
  v_joined timestamptz := fixtures.at(p_days, '17:40');
begin
  perform fixtures.act_as(v);
  perform public.complete_onboarding(p_payload);
  if p_bio is not null then
    perform public.update_profile(jsonb_build_object('bio', p_bio));
  end if;
  perform fixtures.as_admin();
  update auth.users set created_at = v_joined - interval '6 minutes' where id = v;
  update auth.sessions set created_at = v_joined - interval '6 minutes' where user_id = v;
  update private.recovery_keys set created_at = v_joined - interval '6 minutes' where user_id = v;
  update public.profiles set created_at = v_joined where id = v;
  update public.rating_events set created_at = v_joined where player_id = v and kind = 'calibration';
  update public.dna_self_assessments set updated_at = v_joined where player_id = v;
  update public.player_dna_history set day = v_joined::date where player_id = v and day = current_date;
end;
$$;

-- Creates a match as p_creator (played two hours ago; settle() moves it).
create function fixtures.create(p_key text, p_type text, p_format text, p_players text[], p_sets jsonb,
                                p_creator text, p_club text default null)
returns uuid
language plpgsql
as $$
declare
  v_creator uuid := fixtures.pid(p_creator);
  v_payload jsonb;
  v jsonb;
begin
  perform fixtures.as_admin();
  v_payload := jsonb_build_object(
    'match_type', p_type,
    'format', p_format,
    'played_at', now() - interval '2 hours',
    'club_id', fixtures.club(p_club),
    'players', fixtures.lineup(p_players),
    'sets', p_sets
  );
  perform fixtures.act_as(v_creator);
  v := public.create_match(v_payload, fixtures.uuid('idempotency:' || p_key));
  perform fixtures.as_admin();
  return (v ->> 'id')::uuid;
end;
$$;

create function fixtures.confirm(p_match uuid, p_code text)
returns void
language plpgsql
as $$
declare
  v_version integer;
begin
  perform fixtures.as_admin();
  select version into v_version from public.matches where id = p_match;
  perform fixtures.act_as(fixtures.pid(p_code));
  perform public.confirm_match(p_match, v_version);
  perform fixtures.as_admin();
end;
$$;

-- Every participant who has not answered yet confirms, in line-up order.
create function fixtures.confirm_all(p_match uuid)
returns void
language plpgsql
as $$
declare
  v_code text;
begin
  perform fixtures.as_admin();
  for v_code in
    select f.code
      from public.match_players mp
      join fixtures.players f on f.id = mp.player_id
     where mp.match_id = p_match and mp.response = 'pending'
     order by mp.team, mp.court_side desc
  loop
    perform fixtures.confirm(p_match, v_code);
  end loop;
end;
$$;

create function fixtures.dispute(p_match uuid, p_code text, p_reason text, p_comment text)
returns void
language plpgsql
as $$
declare
  v_version integer;
begin
  perform fixtures.as_admin();
  select version into v_version from public.matches where id = p_match;
  perform fixtures.act_as(fixtures.pid(p_code));
  perform public.dispute_match(p_match, v_version, p_reason, p_comment);
  perform fixtures.as_admin();
end;
$$;

create function fixtures.feedback(p_match uuid, p_rater text, p_ratee text, p_strengths text[],
                                  p_improvements text[] default '{}')
returns void
language plpgsql
as $$
declare
  v_payload jsonb;
begin
  perform fixtures.as_admin();
  v_payload := jsonb_build_object('ratings', jsonb_build_array(jsonb_build_object(
    'player_id', fixtures.pid(p_ratee),
    'strengths', to_jsonb(p_strengths),
    'improvements', to_jsonb(p_improvements)
  )));
  perform fixtures.act_as(fixtures.pid(p_rater));
  perform public.submit_match_feedback(p_match, v_payload);
  perform fixtures.as_admin();
end;
$$;

-- Moves a match into the past (played at p_at, entered 80 minutes later,
-- answers 35 minutes apart), gives it a deterministic id and dates the Padel
-- DNA snapshot written by its confirmation on the day it was played.
create function fixtures.settle(p_key text, p_match uuid, p_at timestamptz)
returns uuid
language plpgsql
as $$
declare
  v_new uuid := fixtures.uuid('match:' || p_key);
  v_entered timestamptz := p_at + interval '80 minutes';
  v_status text;
  v_creator uuid;
  v_last timestamptz;
begin
  perform fixtures.as_admin();
  perform set_config('session_replication_role', 'replica', true);
  select status, created_by into v_status, v_creator from public.matches where id = p_match;

  with ordered as (
    select player_id, row_number() over (order by team, court_side desc) as rn
      from public.match_players
     where match_id = p_match and response <> 'pending' and player_id <> v_creator
  )
  update public.match_players mp
     set responded_at = v_entered + o.rn * interval '35 minutes'
    from ordered o
   where mp.match_id = p_match and mp.player_id = o.player_id;
  update public.match_players set responded_at = v_entered where match_id = p_match and player_id = v_creator;
  select max(responded_at) into v_last from public.match_players where match_id = p_match;

  update public.matches
     set id = v_new,
         played_at = p_at,
         created_at = v_entered,
         updated_at = v_last,
         confirmed_at = case when status = 'confirmed' then v_last end
   where id = p_match;
  update public.match_players set match_id = v_new where match_id = p_match;
  update public.rating_events set match_id = v_new, created_at = v_last where match_id = p_match;
  update public.match_feedback
     set match_id = v_new, created_at = v_last + interval '45 minutes', updated_at = v_last + interval '45 minutes'
   where match_id = p_match;

  if v_status = 'confirmed' and p_at::date < current_date then
    delete from public.player_dna_history h
     using public.match_players mp
     where mp.match_id = v_new and h.player_id = mp.player_id and h.day = p_at::date;
    update public.player_dna_history h
       set day = p_at::date
      from public.match_players mp
     where mp.match_id = v_new and h.player_id = mp.player_id and h.day = current_date;
  end if;

  perform set_config('session_replication_role', 'origin', true);
  return v_new;
end;
$$;

-- A confirmed match: created, confirmed by everybody, then settled.
create function fixtures.played(p_key text, p_days integer, p_time text, p_type text, p_format text,
                                p_players text[], p_sets jsonb, p_creator text, p_club text default null)
returns uuid
language plpgsql
as $$
declare
  v uuid;
begin
  v := fixtures.create(p_key, p_type, p_format, p_players, p_sets, p_creator, p_club);
  perform fixtures.confirm_all(v);
  return v;
end;
$$;

grant select on all tables in schema fixtures to authenticated;

-- ---------------------------------------------------------------------------
-- Scenario
-- ---------------------------------------------------------------------------

begin;

do $$
declare
  luzhniki constant text := 'Падел Арена Лужники';
  corner constant text := 'Corner Padel Club';
  moscow integer := (select id from public.cities where name = 'Москва' and country_code = 'RU');
  v uuid;
  v_orlov uuid;
  v_novikov uuid;
  v_zakharov uuid;
  v_club bigint;
  v_code text;
begin
  -- Accounts (sign-up issues a recovery key, the session stays open).
  v_orlov := fixtures.sign_up('OR', 'm_orlov', 'm.orlov@padelid.app');
  perform fixtures.sign_up('SO', 'd_sokolov', 'd.sokolov@padelid.app');
  perform fixtures.sign_up('VO', 'volkov_padel', 'a.volkov@padelid.app');
  perform fixtures.sign_up('MO', 's_morozov', 's.morozov@padelid.app');
  perform fixtures.sign_up('KU', 'anna_kuz', 'anna.kuznetsova@padelid.app');
  perform fixtures.sign_up('LE', 'kate_lebedeva', 'e.lebedeva@padelid.app');
  perform fixtures.sign_up('PA', 'igor_pavlov', 'i.pavlov@padelid.app');
  v_novikov := fixtures.sign_up('NO', 'coach_novikov', 'a.novikov@padelid.app');
  perform fixtures.sign_up('FE', 'maria_fedorova', 'm.fedorova@padelid.app');
  perform fixtures.sign_up('EG', 'pavel_egorov', 'p.egorov@padelid.app');
  perform fixtures.sign_up('VA', 'olga_vasilyeva', 'o.vasilyeva@padelid.app');
  v_zakharov := fixtures.sign_up('ZA', 'artem_zakharov', 'a.zakharov@padelid.app');
  -- A brand new account that has not completed onboarding yet.
  perform fixtures.sign_up('NEW', 'new_player', 'new.player@padelid.app');
  update auth.users set created_at = now() - interval '3 minutes' where id = fixtures.pid('NEW');

  -- Clubs are added by the first player while filling in the profile.
  perform fixtures.act_as(v_orlov);
  perform public.create_club(moscow, luzhniki);
  perform public.create_club(moscow, corner);
  perform fixtures.as_admin();

  perform fixtures.onboard('OR', jsonb_build_object(
    'username', 'm_orlov', 'display_name', 'Михаил Орлов', 'city_id', moscow, 'club_id', fixtures.club(luzhniki),
    'preferred_side', 'right', 'dominant_hand', 'right', 'playing_since', 2021,
    'calibration', jsonb_build_object('experience', '1to3y', 'frequency', 'weekly', 'racket', 'amateur',
                                      'glass', 2, 'net', 2, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 1, 'transition_lob', -1,
                                   'net_game', 1, 'overheads', 0, 'consistency_decisions', 0)
  ), 92, 'Играю справа, люблю атаковать у сетки. Ищу партнёров на утренние игры в будни.');

  perform fixtures.onboard('SO', jsonb_build_object(
    'username', 'd_sokolov', 'display_name', 'Дмитрий Соколов', 'city_id', moscow, 'club_id', fixtures.club(luzhniki),
    'preferred_side', 'left', 'dominant_hand', 'right', 'playing_since', 2019,
    'calibration', jsonb_build_object('experience', 'gt3y', 'frequency', 'weekly', 'racket', 'trained',
                                      'glass', 2, 'net', 2, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 2, 'transition_lob', 1,
                                   'net_game', 0, 'overheads', -1, 'consistency_decisions', 1)
  ), 121, 'Левая сторона, бандеха и терпение в защите.');

  perform fixtures.onboard('VO', jsonb_build_object(
    'username', 'volkov_padel', 'display_name', 'Алексей Волков', 'city_id', moscow, 'club_id', fixtures.club(corner),
    'preferred_side', 'right', 'dominant_hand', 'right', 'playing_since', 2018,
    'calibration', jsonb_build_object('experience', 'gt3y', 'frequency', 'often', 'racket', 'trained',
                                      'glass', 2, 'net', 2, 'competition', 2),
    'dna_self', jsonb_build_object('serve_return', 1, 'defense', 0, 'transition_lob', 0,
                                   'net_game', 1, 'overheads', 2, 'consistency_decisions', 0)
  ), 148);

  perform fixtures.onboard('MO', jsonb_build_object(
    'username', 's_morozov', 'display_name', 'Сергей Морозов', 'city_id', moscow, 'club_id', fixtures.club(corner),
    'preferred_side', 'left', 'dominant_hand', 'left', 'playing_since', 2020,
    'calibration', jsonb_build_object('experience', '1to3y', 'frequency', 'weekly', 'racket', 'trained',
                                      'glass', 2, 'net', 1, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 1, 'transition_lob', 0,
                                   'net_game', -1, 'overheads', 1, 'consistency_decisions', 0)
  ), 112);

  perform fixtures.onboard('KU', jsonb_build_object(
    'username', 'anna_kuz', 'display_name', 'Анна Кузнецова', 'city_id', moscow, 'club_id', fixtures.club(luzhniki),
    'preferred_side', 'left', 'dominant_hand', 'right', 'playing_since', 2022,
    'calibration', jsonb_build_object('experience', '1to3y', 'frequency', 'weekly', 'racket', 'amateur',
                                      'glass', 1, 'net', 2, 'competition', 0),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 0, 'transition_lob', 1,
                                   'net_game', 1, 'overheads', -1, 'consistency_decisions', 0)
  ), 86);

  perform fixtures.onboard('LE', jsonb_build_object(
    'username', 'kate_lebedeva', 'display_name', 'Екатерина Лебедева', 'city_id', moscow, 'club_id', fixtures.club(corner),
    'preferred_side', 'right', 'dominant_hand', 'right', 'playing_since', 2019,
    'calibration', jsonb_build_object('experience', 'gt3y', 'frequency', 'weekly', 'racket', 'amateur',
                                      'glass', 2, 'net', 2, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 1, 'defense', 1, 'transition_lob', 0,
                                   'net_game', 0, 'overheads', -1, 'consistency_decisions', 1)
  ), 131, 'Турниры выходного дня, ищу пару на микст.');

  perform fixtures.onboard('PA', jsonb_build_object(
    'username', 'igor_pavlov', 'display_name', 'Игорь Павлов', 'city_id', moscow,
    'preferred_side', 'both', 'dominant_hand', 'right', 'playing_since', 2022,
    'calibration', jsonb_build_object('experience', '1to3y', 'frequency', 'monthly', 'racket', 'amateur',
                                      'glass', 2, 'net', 1, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 0, 'transition_lob', 0,
                                   'net_game', 0, 'overheads', 0, 'consistency_decisions', 0)
  ), 101);

  perform fixtures.onboard('NO', jsonb_build_object(
    'username', 'coach_novikov', 'display_name', 'Андрей Новиков', 'city_id', moscow, 'club_id', fixtures.club(luzhniki),
    'preferred_side', 'both', 'dominant_hand', 'right', 'playing_since', 2012,
    'calibration', jsonb_build_object('experience', 'gt3y', 'frequency', 'often', 'racket', 'competitive',
                                      'glass', 3, 'net', 3, 'competition', 2),
    'dna_self', jsonb_build_object('serve_return', 1, 'defense', 2, 'transition_lob', 1,
                                   'net_game', 1, 'overheads', 1, 'consistency_decisions', 2)
  ), 163, 'Тренер, FEP Nivel 2. Техника у сетки и тактика игры в паре.');

  perform fixtures.onboard('FE', jsonb_build_object(
    'username', 'maria_fedorova', 'display_name', 'Мария Фёдорова', 'city_id', moscow, 'club_id', fixtures.club(corner),
    'preferred_side', 'right', 'dominant_hand', 'right', 'playing_since', 2025,
    'calibration', jsonb_build_object('experience', '6to12m', 'frequency', 'weekly', 'racket', 'amateur',
                                      'glass', 1, 'net', 1, 'competition', 0),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', -1, 'transition_lob', 0,
                                   'net_game', 1, 'overheads', 0, 'consistency_decisions', 0)
  ), 76);

  perform fixtures.onboard('EG', jsonb_build_object(
    'username', 'pavel_egorov', 'display_name', 'Павел Егоров', 'city_id', moscow,
    'preferred_side', 'left', 'dominant_hand', 'right', 'playing_since', 2021,
    'calibration', jsonb_build_object('experience', '1to3y', 'frequency', 'often', 'racket', 'amateur',
                                      'glass', 2, 'net', 2, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 1, 'transition_lob', -1,
                                   'net_game', 0, 'overheads', 1, 'consistency_decisions', 0)
  ), 104);

  perform fixtures.onboard('VA', jsonb_build_object(
    'username', 'olga_vasilyeva', 'display_name', 'Ольга Васильева', 'city_id', moscow, 'club_id', fixtures.club(luzhniki),
    'preferred_side', 'right', 'dominant_hand', 'right', 'playing_since', 2024,
    'calibration', jsonb_build_object('experience', '6to12m', 'frequency', 'weekly', 'racket', 'trained',
                                      'glass', 1, 'net', 1, 'competition', 1),
    'dna_self', jsonb_build_object('serve_return', 1, 'defense', 0, 'transition_lob', 0,
                                   'net_game', 0, 'overheads', -1, 'consistency_decisions', 0)
  ), 81);

  perform fixtures.onboard('ZA', jsonb_build_object(
    'username', 'artem_zakharov', 'display_name', 'Артём Захаров', 'city_id', moscow, 'club_id', fixtures.club(corner),
    'preferred_side', 'both', 'dominant_hand', 'right', 'playing_since', 2017,
    'calibration', jsonb_build_object('experience', 'gt3y', 'frequency', 'weekly', 'racket', 'trained',
                                      'glass', 2, 'net', 1, 'competition', 2),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 1, 'transition_lob', 0,
                                   'net_game', 0, 'overheads', 1, 'consistency_decisions', 1)
  ), 203);

  -- ---------------------------------------------------------------------
  -- Confirmed matches, oldest first. Line-ups: team 1 right, team 1 left,
  -- team 2 right, team 2 left. Feedback is given right after confirmation.
  -- ---------------------------------------------------------------------

  v := fixtures.played('1', 70, '16:00', 'ranked', 'best_of_3', array['OR', 'SO', 'VO', 'MO'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(6, 3)), 'OR', luzhniki);
  perform fixtures.feedback(v, 'SO', 'OR', array['net_game', 'serve_return'], array['transition_lob']);
  perform fixtures.feedback(v, 'OR', 'SO', array['defense']);
  perform fixtures.feedback(v, 'VO', 'OR', array['net_game']);
  perform fixtures.settle('1', v, fixtures.at(70, '16:00'));

  v := fixtures.played('2', 67, '05:30', 'ranked', 'best_of_3', array['OR', 'KU', 'LE', 'EG'],
    jsonb_build_array(fixtures.set(4, 6), fixtures.set(6, 3), fixtures.set(4, 6)), 'LE', corner);
  perform fixtures.settle('2', v, fixtures.at(67, '05:30'));

  v := fixtures.played('3', 64, '15:30', 'friendly', 'best_of_3', array['OR', 'PA', 'FE', 'VA'],
    jsonb_build_array(fixtures.set(6, 2), fixtures.set(6, 4)), 'PA', luzhniki);
  perform fixtures.settle('3', v, fixtures.at(64, '15:30'));

  v := fixtures.played('4', 61, '08:00', 'ranked', 'best_of_3_super_tiebreak', array['OR', 'SO', 'PA', 'ZA'],
    jsonb_build_array(fixtures.set(6, 7, 5, 7), fixtures.set(6, 4), fixtures.stb(10, 7)), 'SO', luzhniki);
  perform fixtures.feedback(v, 'SO', 'OR', array['consistency_decisions']);
  perform fixtures.settle('4', v, fixtures.at(61, '08:00'));

  v := fixtures.played('5', 58, '17:00', 'ranked', 'best_of_3', array['VO', 'MO', 'FE', 'EG'],
    jsonb_build_array(fixtures.set(6, 3), fixtures.set(6, 4)), 'VO', corner);
  perform fixtures.feedback(v, 'VO', 'MO', array['overheads']);
  perform fixtures.settle('5', v, fixtures.at(58, '17:00'));

  v := fixtures.played('6', 55, '16:30', 'ranked', 'best_of_3', array['LE', 'OR', 'VO', 'KU'],
    jsonb_build_array(fixtures.set(7, 5), fixtures.set(6, 4)), 'OR', corner);
  perform fixtures.feedback(v, 'LE', 'OR', array['defense', 'net_game'], array['transition_lob']);
  perform fixtures.settle('6', v, fixtures.at(55, '16:30'));

  v := fixtures.played('7', 52, '16:00', 'ranked', 'best_of_3', array['OR', 'SO', 'NO', 'MO'],
    jsonb_build_array(fixtures.set(3, 6), fixtures.set(6, 7, 4, 7)), 'NO', luzhniki);
  perform fixtures.settle('7', v, fixtures.at(52, '16:00'));

  v := fixtures.played('8', 49, '06:00', 'ranked', 'single_set', array['OR', 'VA', 'PA', 'EG'],
    jsonb_build_array(fixtures.set(7, 6, 7, 5)), 'OR', luzhniki);
  perform fixtures.settle('8', v, fixtures.at(49, '06:00'));

  v := fixtures.played('9', 46, '09:00', 'friendly', 'best_of_3', array['FE', 'OR', 'LE', 'ZA'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(3, 6), fixtures.set(6, 3)), 'FE', corner);
  perform fixtures.settle('9', v, fixtures.at(46, '09:00'));

  v := fixtures.played('10', 43, '16:00', 'ranked', 'best_of_3', array['OR', 'SO', 'VO', 'MO'],
    jsonb_build_array(fixtures.set(7, 5), fixtures.set(6, 4)), 'MO', corner);
  perform fixtures.feedback(v, 'MO', 'OR', array['net_game'], array['overheads']);
  perform fixtures.settle('10', v, fixtures.at(43, '16:00'));

  v := fixtures.played('11', 40, '17:30', 'ranked', 'best_of_3', array['PA', 'OR', 'NO', 'KU'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(4, 6), fixtures.set(7, 5)), 'KU', luzhniki);
  perform fixtures.settle('11', v, fixtures.at(40, '17:30'));

  v := fixtures.played('12', 37, '16:00', 'ranked', 'best_of_3', array['OR', 'EG', 'VO', 'SO'],
    jsonb_build_array(fixtures.set(4, 6), fixtures.set(6, 3), fixtures.set(3, 6)), 'EG', corner);
  perform fixtures.settle('12', v, fixtures.at(37, '16:00'));

  v := fixtures.played('13', 34, '08:30', 'ranked', 'best_of_3_super_tiebreak', array['OR', 'SO', 'ZA', 'PA'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(3, 6), fixtures.stb(11, 9)), 'OR', luzhniki);
  perform fixtures.feedback(v, 'SO', 'OR', array['net_game', 'consistency_decisions']);
  perform fixtures.feedback(v, 'OR', 'SO', array['defense', 'transition_lob'], array['overheads']);
  perform fixtures.feedback(v, 'ZA', 'OR', array['serve_return']);
  perform fixtures.settle('13', v, fixtures.at(34, '08:30'));

  v := fixtures.played('14', 31, '17:00', 'ranked', 'best_of_3', array['LE', 'KU', 'NO', 'VA'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(6, 4)), 'NO', luzhniki);
  perform fixtures.feedback(v, 'NO', 'KU', array['defense'], array['overheads']);
  perform fixtures.settle('14', v, fixtures.at(31, '17:00'));

  v := fixtures.played('15', 28, '15:00', 'friendly', 'single_set', array['OR', 'FE', 'EG', 'VA'],
    jsonb_build_array(fixtures.set(6, 3)), 'OR', corner);
  perform fixtures.settle('15', v, fixtures.at(28, '15:00'));

  v := fixtures.played('16', 25, '16:30', 'ranked', 'best_of_3', array['OR', 'MO', 'VO', 'LE'],
    jsonb_build_array(fixtures.set(4, 6), fixtures.set(3, 6)), 'VO', corner);
  perform fixtures.settle('16', v, fixtures.at(25, '16:30'));

  v := fixtures.played('17', 22, '07:00', 'ranked', 'best_of_3', array['FE', 'OR', 'PA', 'KU'],
    jsonb_build_array(fixtures.set(4, 6), fixtures.set(6, 4), fixtures.set(6, 2)), 'OR', corner);
  perform fixtures.feedback(v, 'FE', 'OR', array['overheads'], array['transition_lob']);
  perform fixtures.settle('17', v, fixtures.at(22, '07:00'));

  v := fixtures.played('18', 19, '16:00', 'ranked', 'best_of_3', array['OR', 'SO', 'NO', 'MO'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(7, 5)), 'SO', luzhniki);
  perform fixtures.feedback(v, 'NO', 'OR', array['net_game'], array['transition_lob']);
  perform fixtures.feedback(v, 'OR', 'NO', array['overheads', 'net_game']);
  perform fixtures.settle('18', v, fixtures.at(19, '16:00'));

  v := fixtures.played('19', 15, '17:00', 'ranked', 'best_of_3', array['OR', 'ZA', 'VO', 'EG'],
    jsonb_build_array(fixtures.set(6, 7, 6, 8), fixtures.set(7, 5), fixtures.set(4, 6)), 'ZA', corner);
  perform fixtures.settle('19', v, fixtures.at(15, '17:00'));

  v := fixtures.played('20', 11, '16:00', 'ranked', 'best_of_3', array['VO', 'MO', 'PA', 'ZA'],
    jsonb_build_array(fixtures.set(6, 1), fixtures.set(6, 4)), 'PA', corner);
  perform fixtures.feedback(v, 'PA', 'ZA', array['net_game']);
  perform fixtures.settle('20', v, fixtures.at(11, '16:00'));

  v := fixtures.played('21', 7, '08:00', 'ranked', 'best_of_3_super_tiebreak', array['OR', 'SO', 'LE', 'VO'],
    jsonb_build_array(fixtures.set(6, 3), fixtures.set(4, 6), fixtures.stb(10, 8)), 'OR', luzhniki);
  perform fixtures.feedback(v, 'SO', 'OR', array['serve_return']);
  perform fixtures.feedback(v, 'LE', 'OR', array['net_game'], array['transition_lob']);
  perform fixtures.settle('21', v, fixtures.at(7, '08:00'));

  v := fixtures.played('22', 3, '16:00', 'ranked', 'best_of_3', array['OR', 'SO', 'MO', 'EG'],
    jsonb_build_array(fixtures.set(7, 6, 7, 4), fixtures.set(6, 3)), 'MO', luzhniki);
  perform fixtures.feedback(v, 'EG', 'OR', array['defense']);
  v := fixtures.settle('22', v, fixtures.at(3, '16:00'));
  insert into fixtures.refs (key, id) values ('recent', v);

  -- ---------------------------------------------------------------------
  -- Coach: Новиков applies, the admin Захаров approves, the coach assesses
  -- Орлов.
  -- ---------------------------------------------------------------------

  v_club := fixtures.club(luzhniki);
  perform fixtures.act_as(v_novikov);
  perform public.submit_coach_application(jsonb_build_object(
    'experience_years', 9,
    'certification', 'FEP Nivel 2',
    'about', 'Тренирую взрослых любителей девять лет. Ставлю технику у сетки, бандеху и тактику игры в паре.',
    'club_id', v_club
  ));
  perform fixtures.as_admin();
  insert into private.admins (user_id, created_at) values (v_zakharov, fixtures.at(200, '10:00'));
  perform fixtures.act_as(v_zakharov);
  perform public.admin_review_coach(v_novikov, 'approved', 'Сертификат FEP проверен.');
  perform fixtures.act_as(v_novikov);
  perform public.submit_coach_assessment(v_orlov, jsonb_build_object(
    'scores', jsonb_build_object('serve_return', 4, 'defense', 4, 'transition_lob', 3,
                                 'net_game', 4.5, 'overheads', 3.5, 'consistency_decisions', 4),
    'note', 'Сильная игра у сетки и хорошее чтение розыгрыша. Работаем над свечой из защиты: выше и глубже, меньше риска.'
  ));
  perform fixtures.as_admin();
  update public.coach_applications
     set submitted_at = fixtures.at(41, '09:15'), reviewed_at = fixtures.at(40, '11:40')
   where player_id = v_novikov;
  update public.coach_assessments
     set id = fixtures.uuid('assessment:orlov'), created_at = fixtures.at(6, '10:30')
   where coach_id = v_novikov and player_id = v_orlov;

  -- ---------------------------------------------------------------------
  -- Open matches.
  -- ---------------------------------------------------------------------

  -- Ranked, entered by Волков; everybody but Орлов has confirmed.
  v := fixtures.create('open-action', 'ranked', 'best_of_3', array['VO', 'LE', 'OR', 'SO'],
    jsonb_build_array(fixtures.set(4, 6), fixtures.set(6, 4), fixtures.set(4, 6)), 'VO', corner);
  perform fixtures.confirm(v, 'LE');
  perform fixtures.confirm(v, 'SO');
  v := fixtures.settle('open-action', v, fixtures.at(1, '16:30'));
  insert into fixtures.refs (key, id) values ('action', v);

  -- Ranked, entered by Орлов; Павлов confirmed, two answers outstanding.
  v := fixtures.create('open-waiting', 'ranked', 'best_of_3', array['OR', 'KU', 'PA', 'ZA'],
    jsonb_build_array(fixtures.set(7, 5), fixtures.set(6, 2)), 'OR', luzhniki);
  perform fixtures.confirm(v, 'PA');
  v := fixtures.settle('open-waiting', v, fixtures.at(2, '06:00'));
  insert into fixtures.refs (key, id) values ('waiting', v);

  -- Friendly, entered by Егоров; Морозов confirmed, Орлов disputes the score.
  v := fixtures.create('open-disputed', 'friendly', 'best_of_3', array['VA', 'EG', 'OR', 'MO'],
    jsonb_build_array(fixtures.set(6, 4), fixtures.set(6, 4)), 'EG', corner);
  perform fixtures.dispute(v, 'OR', 'wrong_score', 'Второй сет закончился 6:4 в нашу пользу, был третий сет.');
  perform fixtures.confirm(v, 'MO');
  v := fixtures.settle('open-disputed', v, fixtures.at(2, '15:00'));
  insert into fixtures.refs (key, id) values ('disputed', v);

  -- ---------------------------------------------------------------------
  -- Ratings follow the shifted history; Padel DNA is recomputed at today's
  -- date with the final inputs.
  -- ---------------------------------------------------------------------

  update public.player_ratings r
     set last_ranked_at = (select max(e.created_at) from public.rating_events e
                            where e.player_id = r.player_id and e.kind = 'match'),
         created_at = (select p.created_at from public.profiles p where p.id = r.player_id);

  for v_code in select code from fixtures.players where code <> 'NEW' order by code loop
    perform private.recompute_dna(fixtures.pid(v_code));
  end loop;
end;
$$;

commit;
