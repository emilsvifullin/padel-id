-- Password attempt limits, hidden players, account origin, search scoring and
-- duplicate detection (20261008210000_security_and_search.sql).

-- Wrong passwords are counted per user across every password check, and the
-- counter is not rolled back by the rejection.
create function tests.test_password_attempts_are_counted()
returns void language plpgsql as $$
declare
  u uuid := tests.player('pw_counted');
  other uuid := tests.player('pw_other');
  v jsonb;
begin
  perform tests.act_as(u);
  v := public.regenerate_recovery_key('wrong-1');
  perform tests.assert_eq(v, '{"error": "invalid_password"}'::jsonb, 'wrong password reported in the result');
  perform tests.as_admin();
  perform tests.assert_eq((select hits from private.rate_limits where bucket = 'verify_password:' || u), 1, 'failed attempt counted');
  perform tests.assert((select count(*) from private.recovery_keys where user_id = u) = 0, 'no key issued for a wrong password');

  -- Ten attempts in total, spread over all three password checks.
  perform tests.act_as(u);
  for i in 1..3 loop
    perform tests.assert_eq(public.regenerate_recovery_key('wrong'), '{"error": "invalid_password"}'::jsonb, 'still invalid');
  end loop;
  for i in 1..3 loop
    perform tests.assert_eq(public.verify_my_password('wrong'), false, 'verify_my_password rejects');
  end loop;
  perform tests.act_as_service();
  for i in 1..3 loop
    perform tests.assert_eq(public.svc_check_password(u, 'wrong'), false, 'svc_check_password rejects');
  end loop;
  perform tests.as_admin();
  perform tests.assert_eq((select hits from private.rate_limits where bucket = 'verify_password:' || u), 10, 'shared bucket');

  -- The budget is spent: even the right password is refused everywhere.
  perform tests.act_as(u);
  perform tests.expect_error('select public.regenerate_recovery_key(''Correct-Horse-7'')', 'rate_limited', 'regenerate limited');
  perform tests.expect_error('select public.verify_my_password(''Correct-Horse-7'')', 'rate_limited', 'verify limited');
  perform tests.act_as_service();
  perform tests.expect_error(format('select public.svc_check_password(%L, %L)', u, 'Correct-Horse-7'), 'rate_limited', 'service check limited');

  -- Other users keep their own budget.
  perform tests.assert(public.svc_check_password(other, 'Correct-Horse-7'), 'other user unaffected');
  perform tests.assert_eq(public.svc_check_password(null, 'x'), false, 'no user, no match');
  perform tests.act_as(other);
  v := public.regenerate_recovery_key('Correct-Horse-7');
  perform tests.assert((v ->> 'recovery_key') ~ '^[0-9A-Z]{5}(-[0-9A-Z]{5}){3}$', 'right password issues a key');

  -- The service check stays closed to end users.
  perform tests.expect_error(format('select public.svc_check_password(%L, %L)', other, 'x'), '42501', 'users cannot call svc_check_password');
  perform tests.act_as_anon();
  perform tests.expect_error(format('select public.svc_check_password(%L, %L)', other, 'x'), '42501', 'anon cannot call svc_check_password');
end $$;

-- discoverable = false hides profile-level reads from strangers; players who
-- shared a match, the player and administrators still see everything, and
-- line-up cards inside public matches are unchanged.
create function tests.test_hidden_player_profile_reads()
returns void language plpgsql as $$
declare
  hidden uuid := tests.player('hid_target');
  partner uuid := tests.player('hid_partner');
  x uuid := tests.player('hid_x');
  y uuid := tests.player('hid_y');
  stranger uuid := tests.player('hid_stranger');
  coach uuid := tests.player('hid_coach');
  admin uuid := tests.player('hid_admin');
  scores jsonb := '{"scores":{"serve_return":3,"defense":3,"transition_lob":3,"net_game":3,"overheads":4,"consistency_decisions":3}}';
  reads text[] := array['player_profile(%L)', 'player_dna(%L)', 'rating_history(%L)', 'player_matches(%L)', 'compatibility(%L)'];
  f text;
  viewer uuid;
  m uuid;
  v jsonb;
begin
  update public.profiles set discoverable = false where id = hidden;
  insert into private.admins (user_id) values (admin);
  insert into public.coach_applications (player_id, status, experience_years, about)
  values (coach, 'approved', 5, 'Тренирую любителей пять лет, техника у сетки.');
  update public.profiles set is_coach = true where id = coach;
  m := tests.match(array[partner, hidden, x, y], 'ranked');
  perform tests.confirm_all(m);

  -- A stranger gets the same answer as for a player that does not exist.
  perform tests.act_as(stranger);
  foreach f in array reads loop
    perform tests.expect_error(format('select public.' || f, hidden), 'player_not_found', 'stranger: ' || split_part(f, '(', 1));
    perform tests.expect_error(format('select public.' || f, gen_random_uuid()), 'player_not_found', 'unknown player: ' || split_part(f, '(', 1));
  end loop;
  v := public.search_players(jsonb_build_object('query', 'hid_target'));
  perform tests.assert(v::text not like '%' || hidden || '%', 'still hidden from search');

  -- The public match keeps the hidden player's line-up card.
  v := public.match_detail(m);
  perform tests.assert(v -> 'players' @> jsonb_build_array(jsonb_build_object('player', jsonb_build_object('id', hidden))), 'line-up card in match detail');
  v := public.player_matches(partner);
  perform tests.assert(v::text like '%' || hidden || '%', 'line-up card in a visible player''s history');

  -- A coach who never played with the player cannot assess them.
  perform tests.act_as(coach);
  perform tests.expect_error(format('select public.submit_coach_assessment(%L, %L::jsonb)', hidden, scores), 'player_not_found', 'coach without a shared match');

  -- The player, a player they shared a match with and an administrator can read.
  foreach viewer in array array[hidden, partner, admin] loop
    perform tests.act_as(viewer);
    v := public.player_profile(hidden);
    perform tests.assert_eq(v -> 'profile' ->> 'id', hidden::text, 'profile visible');
    perform tests.assert((public.player_dna(hidden) -> 'rating') is not null, 'dna visible');
    perform tests.assert(jsonb_array_length(public.rating_history(hidden, null) -> 'points') >= 2, 'rating history visible');
    perform tests.assert_eq(jsonb_array_length(public.player_matches(hidden) -> 'items'), 1, 'match history visible');
    if viewer <> hidden then
      perform tests.assert((public.compatibility(hidden) ->> 'score') is not null, 'compatibility visible');
    end if;
  end loop;

  -- Discoverable again: open to everyone, including the coach.
  perform tests.as_admin();
  update public.profiles set discoverable = true where id = hidden;
  perform tests.act_as(stranger);
  perform tests.assert_eq(public.player_profile(hidden) ->> 'deleted', 'false', 'stranger sees a discoverable player');
  perform tests.act_as(coach);
  v := public.submit_coach_assessment(hidden, scores);
  perform tests.assert_eq(v -> 'profile' ->> 'id', hidden::text, 'coach can assess a discoverable player');

  -- Helpers stay private.
  perform tests.act_as(stranger);
  perform tests.expect_error(format('select private.require_visible_player(%L, %L)', stranger, hidden), '42501', 'visibility helper closed');
end $$;

-- Inserts an auth user as GoTrue does: the row first, app_metadata merged by a
-- later UPDATE in the same transaction; then runs the commit-time check.
create function tests.gotrue_insert_user(p_insert_meta jsonb, p_update_meta jsonb default null)
returns void language plpgsql as $$
declare
  v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_app_meta_data) values (v, v || '@origin.test', p_insert_meta);
  if p_update_meta is not null then
    update auth.users set raw_app_meta_data = coalesce(raw_app_meta_data, '{}') || p_update_meta where id = v;
  end if;
  execute 'set constraints auth.padelid_require_account_service immediate';
  execute 'set constraints auth.padelid_require_account_service deferred';
end $$;

-- New auth users must carry the marker that only the account service sets.
create function tests.test_users_require_account_service_origin()
returns void language plpgsql as $$
begin
  -- Public GoTrue sign-up: app_metadata holds only the provider.
  perform tests.expect_error('select tests.gotrue_insert_user(''{"provider": "email", "providers": ["email"]}'')',
    'signup_not_allowed', 'sign-up without the marker is rejected');
  perform tests.expect_error('select tests.gotrue_insert_user(null)', 'signup_not_allowed', 'no app_metadata at all');
  perform tests.expect_error('select tests.gotrue_insert_user(''{"padelid_origin": "gotrue"}'')', 'signup_not_allowed', 'wrong marker value');
  perform tests.expect_error('select tests.gotrue_insert_user(''{"provider": "email"}'', ''{"padelid_origin": "other"}'')',
    'signup_not_allowed', 'wrong marker set later');

  -- Account service: createUser inserts, then merges app_metadata before commit.
  perform tests.gotrue_insert_user('{"provider": "email", "providers": ["email"]}', '{"padelid_origin": "account-service"}');
  perform tests.gotrue_insert_user('{"provider": "email", "padelid_origin": "account-service"}');

  -- Only inserts are checked (existing users are untouched), at commit.
  perform tests.assert(exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'auth.users'::regclass and t.tgname = 'padelid_require_account_service'
       and t.tgtype = 5 -- row-level, AFTER INSERT only
       and t.tgdeferrable and t.tginitdeferred and t.tgenabled = 'O'
  ), 'deferred insert-only trigger on auth.users');
end $$;

-- search_players scores candidates set-based; the scores and the order must be
-- those of private.compatibility(), the function behind the profile endpoint.
create function tests.test_search_compatibility_matches_profile()
returns void language plpgsql as $$
declare
  me uuid := tests.player('scm_me', 2, 1);
  p uuid[] := array[tests.player('scm_partner', 2, 1), tests.player('scm_strong', 3, 3), tests.player('scm_weak', 0, 0),
                    tests.player('scm_friend', 2, 2), tests.player('scm_clubmate', 1, 1), tests.player('scm_far', 2, 1, 2)];
  club bigint;
  m uuid;
  v jsonb;
  item jsonb;
  results jsonb[] := '{}';
  q text;
  prev_score integer;
  prev_name text;
  expected jsonb;
  checked integer := 0;
begin
  insert into public.clubs (city_id, name) values (1, 'Scoring Club') returning id into club;
  update public.profiles set preferred_side = 'right', club_id = club where id = me;
  update public.profiles set preferred_side = 'left' where id = p[1];
  update public.profiles set preferred_side = 'right' where id = p[2];
  update public.profiles set preferred_side = 'left', club_id = club where id = p[5];
  perform tests.act_as(p[2]);
  perform public.set_dna_self('{"serve_return":2,"defense":-1,"transition_lob":1,"net_game":2,"overheads":2,"consistency_decisions":-2}');
  perform tests.act_as(me);
  perform public.set_dna_self('{"serve_return":-2,"defense":1,"transition_lob":0,"net_game":-1,"overheads":-2,"consistency_decisions":1}');
  -- Two rated matches as partners (chemistry) and one friendly (played together).
  for i in 1..2 loop
    m := tests.match(array[me, p[1], p[2], p[3]], 'ranked', tests.sets(6, 3, 4, 6, 6, 4), 'best_of_3', now() - make_interval(hours => 2 * i));
    perform tests.confirm_all(m);
  end loop;
  m := tests.match(array[me, p[4], p[5], p[6]], 'friendly', null, 'best_of_3', now() - interval '8 hours');
  perform tests.confirm_all(m);
  -- A player without DNA (no style component).
  perform tests.as_admin();
  delete from public.player_dna where player_id = p[3];

  perform tests.act_as(me);
  foreach q in array array['{"limit":50}', '{"sort":"compatibility","city_id":1}', '{"query":"scm","limit":50}', '{"limit":2,"offset":2}'] loop
    results := results || public.search_players(q::jsonb);
  end loop;

  perform tests.as_admin();
  perform tests.assert(private.compatibility(me, p[1]) -> 'reasons' @> '[{"code":"chemistry"}]', 'chemistry branch covered');
  perform tests.assert(private.compatibility(me, p[4]) -> 'reasons' @> '[{"code":"played_together"}]', 'played-together branch covered');
  perform tests.assert((private.compatibility(me, p[3]) -> 'components' -> 2 ->> 'weight')::numeric = 0, 'no-DNA branch covered');

  -- Full list without a query: ordered by score, then name.
  perform tests.assert_eq(jsonb_array_length(results[1] -> 'items'), 6, 'all candidates listed');
  for item in select value from jsonb_array_elements(results[1] -> 'items') loop
    expected := private.compatibility(me, (item ->> 'id')::uuid);
    perform tests.assert_eq((item ->> 'compatibility')::integer, (expected ->> 'score')::integer,
      'search score equals profile score for ' || (item ->> 'username'));
    perform tests.assert(prev_score is null or prev_score > (item ->> 'compatibility')::integer
      or (prev_score = (item ->> 'compatibility')::integer and prev_name <= item ->> 'display_name'), 'ordered by score');
    prev_score := (item ->> 'compatibility')::integer;
    prev_name := item ->> 'display_name';
    checked := checked + 1;
  end loop;
  perform tests.assert_eq(checked, 6, 'every candidate checked');

  -- City filter, text query and a later page carry the same scores.
  foreach item in array array[results[2], results[3], results[4]] loop
    perform tests.assert(jsonb_array_length(item -> 'items') > 0, 'non-empty result');
    perform tests.assert(not exists (
      select 1 from jsonb_array_elements(item -> 'items') e
       where (e ->> 'compatibility')::integer is distinct from (private.compatibility(me, (e ->> 'id')::uuid) ->> 'score')::integer
    ), 'scores equal in every variant');
  end loop;
  perform tests.assert_eq(results[4] -> 'items' -> 0 ->> 'id', results[1] -> 'items' -> 2 ->> 'id', 'paging follows the same order');
  perform tests.assert(not (results[2]::text like '%' || p[6] || '%'), 'city filter applied');

  -- Other sorts leave the score out.
  perform tests.act_as(me);
  v := public.search_players('{"sort":"name"}');
  perform tests.assert((v -> 'items' -> 0 ->> 'compatibility') is null, 'no score outside the compatibility sort');
  perform tests.expect_error(format('select private.compatibility_parts(1, 1, %L, null, null, 1, 1, %L, null, null, null, null, 0, null)', 'both', 'both'),
    '42501', 'scoring helper closed');
end $$;

-- The duplicate check (anchored on one player's matches) keeps its semantics.
create function tests.test_duplicate_match_detection()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('dup_one'), tests.player('dup_two'), tests.player('dup_three'), tests.player('dup_four')];
  q uuid := tests.player('dup_five');
  t timestamptz := date_trunc('minute', now()) - interval '3 hours';
  m1 uuid;
  m2 uuid;
  edit jsonb;
begin
  m1 := tests.match(p, 'friendly', null, 'best_of_3', t);

  -- Same four players entered by another participant, other positions, 30 minutes apart.
  perform tests.act_as(p[4]);
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', t + interval '30 minutes',
                       'players', tests.lineup(array[p[4], p[2], p[3], p[1]]), 'sets', tests.sets(6, 4, 6, 4))),
    'duplicate_match', 'same line-up within 45 minutes');

  -- 45 minutes or more apart, or a different line-up, is a different match.
  m2 := tests.match(array[p[4], p[3], p[2], p[1]], 'friendly', null, 'best_of_3', t + interval '50 minutes');
  perform tests.match(array[p[2], p[1], p[3], q], 'friendly', null, 'best_of_3', t);

  -- A cancelled match does not block re-entering it.
  perform tests.act_as(p[1]);
  perform public.cancel_match(m1, tests.version(m1));
  perform tests.match(array[p[3], p[4], p[1], p[2]], 'friendly', null, 'best_of_3', t + interval '5 minutes');

  -- Editing never collides with the match itself, but does with another one.
  edit := jsonb_build_object('match_type', 'friendly', 'format', 'best_of_3', 'played_at', t + interval '55 minutes',
                             'players', tests.lineup(array[p[4], p[3], p[2], p[1]]), 'sets', tests.sets(6, 1, 6, 1));
  perform tests.act_as(p[4]);
  perform public.update_match(m2, tests.version(m2), edit, gen_random_uuid());
  perform tests.expect_error(format('select public.update_match(%L, %s, %L::jsonb, gen_random_uuid())', m2, tests.version(m2),
    jsonb_set(edit, '{played_at}', to_jsonb(t + interval '20 minutes'))), 'duplicate_match', 'edit onto another match');
end $$;
