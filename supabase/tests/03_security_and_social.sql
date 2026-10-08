-- Privileges, privacy, search, insights, coaches and account lifecycle.

create function tests.test_table_access_denied()
returns void language plpgsql as $$
declare
  a uuid := tests.player('sec_a');
  t text;
begin
  perform tests.act_as(a);
  foreach t in array array['profiles', 'player_ratings', 'matches', 'match_players', 'rating_events', 'match_feedback',
                           'dna_self_assessments', 'coach_applications', 'coach_assessments', 'player_dna', 'player_dna_history', 'clubs', 'cities'] loop
    perform tests.expect_error(format('select count(*) from public.%I', t), '42501', 'authenticated cannot read ' || t);
    perform tests.expect_error(format('delete from public.%I', t), '42501', 'authenticated cannot delete ' || t);
  end loop;
  perform tests.expect_error('update public.player_ratings set mu = 7', '42501', 'cannot write ratings directly');
  perform tests.expect_error('select * from private.admins', '42501', 'private schema is closed');
  perform tests.expect_error('select private.apply_ranked_match(gen_random_uuid())', '42501', 'private functions are closed');
  perform tests.expect_error(format('select public.svc_anonymize_account(%L)', a), '42501', 'service functions are closed to users');
  perform tests.expect_error(format('select public.svc_issue_recovery_key(%L)', a), '42501', 'recovery keys are service only');
  perform tests.expect_error(format('select public.bff_rate_limit(%L, %L, 1, 60)', 'x', 'y'), '42501', 'gateway rate limit closed to users');

  perform tests.act_as_anon();
  perform tests.expect_error('select public.me()', '42501', 'anon cannot call API');
  perform tests.expect_error('select public.search_players(''{}''::jsonb)', '42501', 'anon cannot search');
  perform tests.expect_error('select count(*) from public.profiles', '42501', 'anon cannot read tables');
  perform tests.expect_error(format('select public.bff_rate_limit(%L, %L, 1, 60)', repeat('x', 40), 'y'), 'forbidden', 'gateway secret required');
end $$;

create function tests.test_unauthenticated_calls_fail()
returns void language plpgsql as $$
begin
  perform tests.act_as_service();
  perform tests.expect_error('select public.me()', '42501', 'service role cannot use end-user API');
  perform tests.as_admin();
  perform tests.expect_error('select public.me()', 'not_authenticated', 'no JWT, no identity');
end $$;

create function tests.test_match_privacy()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('pv_one'), tests.player('pv_two'), tests.player('pv_three'), tests.player('pv_four')];
  outsider uuid := tests.player('pv_out');
  m uuid;
  v jsonb;
begin
  m := tests.match(p);
  perform tests.act_as(p[3]);
  perform public.dispute_match(m, 1, 'other', 'Секретный комментарий');

  perform tests.act_as(outsider);
  perform tests.expect_error(format('select public.match_detail(%L)', m), 'match_not_found', 'pending match hidden from outsiders');
  perform tests.expect_error(format('select public.confirm_match(%L, 1)', m), 'match_not_found', 'outsider cannot confirm');
  perform tests.expect_error(format('select public.dispute_match(%L, 1, %L)', m, 'other'), 'match_not_found', 'outsider cannot dispute');
  perform tests.expect_error(format('select public.cancel_match(%L, 1)', m), 'match_not_found', 'outsider cannot cancel');
  perform tests.expect_error(format('select public.update_match(%L, 1, %L::jsonb, gen_random_uuid())', m, '{}'), 'match_not_found', 'outsider cannot edit');
  v := public.player_matches(p[1]);
  perform tests.assert_eq(jsonb_array_length(v -> 'items'), 0, 'unconfirmed matches not listed for others');

  perform tests.act_as(p[2]);
  perform tests.expect_error(format('select public.update_match(%L, 1, %L::jsonb, gen_random_uuid())', m, '{}'), 'forbidden', 'non-creator cannot edit');
  perform tests.act_as(p[3]);
  perform public.confirm_match(m, 1);
  perform tests.confirm_all(m);

  perform tests.act_as(outsider);
  v := public.match_detail(m);
  perform tests.assert_eq(v ->> 'status', 'confirmed', 'confirmed match is public');
  perform tests.assert((v -> 'players' -> 0 ->> 'dispute_comment') is null, 'dispute details hidden from outsiders');
  perform tests.assert_eq((v -> 'viewer' ->> 'can_give_feedback')::boolean, false, 'outsider cannot give feedback');
  v := public.player_profile(p[1]);
  perform tests.assert(v::text not like '%@padel.test%', 'emails never exposed in profiles');
  v := public.search_players('{"query":"pv"}');
  perform tests.assert(v::text not like '%@padel.test%', 'emails never exposed in search');
end $$;

create function tests.test_search_and_filters()
returns void language plpgsql as $$
declare
  me uuid := tests.player('srch_me', 2, 1);
  near_left uuid := tests.player('srch_left', 2, 1);
  strong uuid := tests.player('srch_strong', 3, 3);
  hidden uuid := tests.player('srch_hidden', 2, 1);
  other_city uuid := tests.player('srch_spb', 2, 1, 2);
  gone uuid := tests.player('srch_gone', 2, 1);
  v jsonb;
  ids text;
begin
  update public.profiles set preferred_side = 'left' where id = near_left;
  update public.profiles set display_name = 'Ёлкина Мария' where id = near_left;
  update public.profiles set discoverable = false where id = hidden;
  perform tests.act_as_service();
  perform public.svc_anonymize_account(gone);

  perform tests.act_as(me);
  v := public.search_players('{"query":"srch"}');
  ids := v -> 'items' #>> '{}';
  perform tests.assert(v::text like '%' || near_left || '%', 'finds by username');
  perform tests.assert(v::text not like '%' || me || '%', 'excludes self');
  perform tests.assert(v::text not like '%' || hidden || '%', 'respects discoverable=false');
  perform tests.assert(v::text not like '%' || gone || '%', 'excludes deleted players');

  v := public.search_players('{"query":"елкина"}');
  perform tests.assert(v::text like '%' || near_left || '%', 'ё/е and case-insensitive name search');

  v := public.search_players('{"query":"srch","city_id":2}');
  perform tests.assert_eq(jsonb_array_length(v -> 'items'), 1, 'city filter');
  perform tests.assert_eq(v -> 'items' -> 0 ->> 'id', other_city::text, 'city filter result');

  v := public.search_players('{"query":"srch","min_level":4}');
  perform tests.assert(v::text like '%' || strong || '%' and v::text not like '%' || near_left || '%', 'level filter');

  v := public.search_players('{"query":"srch","side":"left","city_id":1}');
  perform tests.assert(v::text like '%' || near_left || '%', 'side filter includes left players');

  v := public.search_players('{"query":"srch","sort":"level_desc","limit":1}');
  perform tests.assert_eq(v -> 'items' -> 0 ->> 'id', strong::text, 'sort by level');
  perform tests.assert((v ->> 'next_offset')::int = 1, 'pagination cursor');

  v := public.search_players('{"city_id":1}');
  perform tests.assert((v -> 'items' -> 0 ->> 'compatibility') is not null, 'compatibility computed');
  perform tests.expect_error('select public.search_players(''{"sort":"random"}''::jsonb)', 'invalid_request');

  -- Hidden players remain reachable for people they played with.
  perform tests.as_admin();
  perform tests.confirm_all(tests.match(array[me, hidden, near_left, strong], 'friendly'));
  perform tests.act_as(me);
  v := public.search_players('{"query":"srch_hidden"}');
  perform tests.assert(v::text like '%' || hidden || '%', 'hidden player visible to past partners');
end $$;

create function tests.test_compatibility_and_insights()
returns void language plpgsql as $$
declare
  a uuid := tests.player('cmp_a', 2, 1);
  b uuid := tests.player('cmp_b', 2, 1);
  far uuid := tests.player('cmp_far', 0, 0);
  x uuid := tests.player('cmp_x', 2, 1);
  y uuid := tests.player('cmp_y', 2, 1);
  v jsonb;
  v2 jsonb;
  m uuid;
begin
  update public.profiles set preferred_side = 'right' where id = a;
  update public.profiles set preferred_side = 'left' where id = b;
  update public.profiles set preferred_side = 'right' where id = far;
  perform tests.act_as(a);
  v := public.compatibility(b);
  v2 := public.compatibility(far);
  perform tests.assert((v ->> 'score')::int > (v2 ->> 'score')::int, 'similar level and complementary sides score higher');
  perform tests.assert((v ->> 'score')::int between 0 and 100, 'score range');
  perform tests.assert(v -> 'reasons' @> '[{"code":"sides"}]', 'reasons provided');

  for i in 1..3 loop
    m := tests.match(array[a, b, x, y], 'ranked', tests.sets(6, 3, 6, 2), 'best_of_3', now() - make_interval(hours => i));
    perform tests.confirm_all(m);
  end loop;
  perform tests.act_as(a);
  v := public.compatibility(b);
  perform tests.assert(v -> 'reasons' @> '[{"code":"chemistry"}]', 'chemistry from shared results');
  v := public.home();
  perform tests.assert(jsonb_array_length(v -> 'insights') > 0, 'insights generated from data');
  perform tests.assert(v -> 'insights' @> '[{"kind":"trend"}]', 'trend insight after several matches');
  perform tests.assert((v -> 'stats' ->> 'wins')::int = 3, 'stats count wins');
  perform tests.assert(v -> 'stats' -> 'form' = '["W","W","W"]', 'form');
  perform tests.assert_eq((v -> 'stats' -> 'streak' ->> 'count')::int, 3, 'streak');
end $$;

create function tests.test_coach_flow()
returns void language plpgsql as $$
declare
  coach uuid := tests.player('coach_c');
  admin uuid := tests.player('admin_a');
  player uuid := tests.player('student_s');
  v jsonb;
  before double precision;
begin
  insert into private.admins (user_id) values (admin);
  perform tests.act_as(coach);
  perform tests.expect_error(format('select public.submit_coach_assessment(%L, %L::jsonb)', player, '{}'), 'not_a_coach');
  perform tests.expect_error('select public.submit_coach_application(''{"experience_years":5,"about":"коротко"}''::jsonb)', 'invalid_coach_application');
  v := public.submit_coach_application('{"experience_years":6,"certification":"FEP Nivel 1","about":"Тренирую взрослых любителей шесть лет, работаю над техникой у сетки."}');
  perform tests.assert_eq(v ->> 'status', 'pending', 'application pending');
  perform tests.expect_error('select public.admin_coach_applications()', 'forbidden', 'only admins review');

  perform tests.act_as(admin);
  v := public.admin_coach_applications();
  perform tests.assert_eq(jsonb_array_length(v), 1, 'admin sees the application');
  v := public.admin_review_coach(coach, 'approved', null);
  perform tests.assert_eq(v ->> 'status', 'approved', 'approved');

  perform tests.as_admin();
  select offset_mean into before from public.player_dna where player_id = player and dimension = 'overheads';
  perform tests.act_as(coach);
  perform tests.expect_error(format('select public.submit_coach_assessment(%L, %L::jsonb)', coach, '{}'), 'cannot_assess_self');
  perform tests.expect_error(format('select public.submit_coach_assessment(%L, %L::jsonb)', player,
    '{"scores":{"serve_return":3,"defense":3,"transition_lob":3,"net_game":3,"overheads":3.3,"consistency_decisions":3}}'), 'invalid_assessment', 'half-point steps');
  v := public.submit_coach_assessment(player,
    '{"scores":{"serve_return":3,"defense":3,"transition_lob":3,"net_game":3,"overheads":4.5,"consistency_decisions":2.5},"note":"Сильная бандеха"}');
  perform tests.assert(v -> 'dna' -> 'dimensions' @> '[{"key":"overheads"}]', 'profile returned');
  perform tests.expect_error(format('select public.submit_coach_assessment(%L, %L::jsonb)', player,
    '{"scores":{"serve_return":3,"defense":3,"transition_lob":3,"net_game":3,"overheads":4,"consistency_decisions":3}}'), 'assessment_too_soon');

  perform tests.as_admin();
  perform tests.assert((select offset_mean from public.player_dna where player_id = player and dimension = 'overheads') > before, 'coach raises overheads');
  perform tests.assert((select coach_verified_at from public.player_dna where player_id = player and dimension = 'overheads') is not null, 'coach verified');

  -- Note is private to the player and the coach.
  perform tests.act_as(admin);
  v := public.player_profile(player);
  perform tests.assert((v -> 'coach_assessments' -> 0 ->> 'note') is null, 'note hidden from third parties');
  perform tests.act_as(player);
  v := public.player_profile(player);
  perform tests.assert_eq(v -> 'coach_assessments' -> 0 ->> 'note', 'Сильная бандеха', 'player sees the note');

  -- Revoking removes the verified status and its influence.
  perform tests.act_as(admin);
  perform public.admin_review_coach(coach, 'revoked', 'Нарушение правил');
  perform tests.as_admin();
  perform tests.assert((select coach_verified_at from public.player_dna where player_id = player and dimension = 'overheads') is null, 'verification removed');
  perform tests.assert_eq((select is_coach from public.profiles where id = coach), false, 'coach flag removed');
end $$;

create function tests.test_recovery_keys_and_passwords()
returns void language plpgsql as $$
declare
  u uuid := tests.player('rk_user');
  k text;
  v jsonb;
begin
  perform tests.act_as_service();
  k := public.svc_issue_recovery_key(u);
  perform tests.assert(k ~ '^[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9A-Z]{5}$', 'key format');
  perform tests.assert_eq(public.svc_check_recovery_key('RK_USER@padel.test', k), u, 'key accepted, email case-insensitive');
  perform tests.assert_eq(public.svc_check_recovery_key('rk_user@padel.test', lower(replace(k, '-', ' '))), u, 'key normalised');
  perform tests.assert(public.svc_check_recovery_key('rk_user@padel.test', 'AAAAA-AAAAA-AAAAA-AAAAA') is null, 'wrong key rejected');
  perform tests.assert(public.svc_check_recovery_key('nobody@padel.test', k) is null, 'unknown email rejected');
  perform tests.assert(public.svc_check_password(u, 'Correct-Horse-7'), 'password check');
  perform tests.assert(not public.svc_check_password(u, 'wrong'), 'wrong password');

  perform tests.act_as(u);
  -- Reported in the result (not raised) so that the attempt counter commits.
  perform tests.assert_eq(public.regenerate_recovery_key('wrong'), '{"error": "invalid_password"}'::jsonb, 'wrong password rejected');
  v := public.regenerate_recovery_key('Correct-Horse-7');
  perform tests.act_as_service();
  perform tests.assert(public.svc_check_recovery_key('rk_user@padel.test', k) is null, 'old key invalidated');
  perform tests.assert_eq(public.svc_check_recovery_key('rk_user@padel.test', v ->> 'recovery_key'), u, 'new key works');
  perform tests.as_admin();
  perform tests.assert((select count(*) from private.recovery_keys where key_hash::text like '%' || replace(v ->> 'recovery_key', '-', '') || '%') = 0, 'plain key not stored');
end $$;

create function tests.test_account_anonymization()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('del_one'), tests.player('del_two'), tests.player('del_three'), tests.player('del_four')];
  m_confirmed uuid;
  m_open uuid;
  v jsonb;
begin
  m_confirmed := tests.match(p, 'ranked', tests.sets(6, 4, 6, 4), 'best_of_3', now() - interval '5 hours');
  perform tests.confirm_all(m_confirmed);
  m_open := tests.match(array[p[2], p[1], p[3], p[4]], 'friendly', tests.sets(6, 1, 6, 1), 'best_of_3', now() - interval '1 hour');

  perform tests.act_as_service();
  perform public.svc_anonymize_account(p[1]);
  perform public.svc_anonymize_account(p[1]);

  perform tests.as_admin();
  perform tests.assert_eq((select status from public.matches where id = m_open), 'cancelled', 'open matches cancelled');
  perform tests.assert_eq((select status from public.matches where id = m_confirmed), 'confirmed', 'history preserved');
  perform tests.assert((select deleted_at from public.profiles where id = p[1]) is not null, 'profile tombstoned');
  perform tests.assert_eq((select count(*) from public.player_dna where player_id = p[1])::int, 0, 'DNA removed');

  perform tests.act_as(p[2]);
  v := public.match_detail(m_confirmed);
  perform tests.assert(v -> 'players' @> '[{"player":{"deleted":true,"display_name":"Удалённый игрок"}}]', 'shown as deleted player');
  v := public.player_profile(p[1]);
  perform tests.assert_eq((v ->> 'deleted')::boolean, true, 'deleted profile minimal');
  perform tests.assert(v::text not like '%del_one%', 'username scrubbed');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_build_object('match_type', 'friendly', 'format', 'best_of_3', 'played_at', now() - interval '1 hour',
                       'players', tests.lineup(array[p[2], p[1], p[3], p[4]]), 'sets', tests.sets(6, 4, 6, 4))), 'player_not_found', 'deleted player cannot be added');
end $$;

create function tests.test_gateway_rate_limit()
returns void language plpgsql as $$
declare
  secret text := repeat('s', 48);
begin
  insert into private.bff_secret (secret_hash) values (extensions.digest(secret, 'sha256'));
  perform tests.act_as_anon();
  perform tests.assert(public.bff_rate_limit(secret, 'login:test', 2, 60), 'first hit allowed');
  perform tests.assert(public.bff_rate_limit(secret, 'login:test', 2, 60), 'second hit allowed');
  perform tests.assert(not public.bff_rate_limit(secret, 'login:test', 2, 60), 'third hit blocked');
  perform tests.assert(public.bff_rate_limit(secret, 'login:other', 2, 60), 'buckets are independent');
  perform tests.expect_error(format('select public.bff_rate_limit(%L, %L, 2, 60)', repeat('t', 48), 'login:test'), 'forbidden', 'wrong secret');
end $$;

create function tests.test_revoked_session_is_rejected()
returns void language plpgsql as $$
declare
  u uuid := tests.player('sess_user');
  v_session uuid;
begin
  perform tests.act_as(u);
  perform public.me();
  perform tests.as_admin();
  select id into v_session from auth.sessions where user_id = u limit 1;
  delete from auth.sessions where user_id = u;
  perform set_config('request.jwt.claims',
    json_build_object('sub', u, 'role', 'authenticated', 'session_id', v_session)::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
  perform tests.expect_error('select public.me()', 'session_expired', 'token of a revoked session');
  perform tests.as_admin();
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  execute 'set local role authenticated';
  perform tests.expect_error('select public.me()', 'session_expired', 'token without session id');
end $$;
