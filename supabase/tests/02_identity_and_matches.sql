-- Onboarding, profile and the full match lifecycle.

create function tests.test_onboarding()
returns void language plpgsql as $$
declare
  u uuid := tests.new_user('new@padel.test');
  u2 uuid := tests.new_user('other@padel.test');
  v jsonb;
  payload jsonb := '{"username":"ivan_petrov","display_name":"Иван  Петров","city_id":1,"preferred_side":"right","dominant_hand":"left",
    "calibration":{"experience":"1to3y","frequency":"weekly","racket":"amateur","glass":2,"net":1,"competition":1},
    "dna_self":{"serve_return":1,"defense":0,"transition_lob":-1,"net_game":2,"overheads":0,"consistency_decisions":-2}}';
begin
  perform tests.act_as(u);
  v := public.me();
  perform tests.assert_eq((v ->> 'needs_onboarding')::boolean, true, 'fresh account needs onboarding');
  perform tests.assert_eq(v ->> 'email', 'new@padel.test', 'own email visible');

  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', jsonb_set(payload, '{username}', '"Ab"')), 'username_invalid');
  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', jsonb_set(payload, '{username}', '"admin"')), 'username_reserved');
  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', jsonb_set(payload, '{display_name}', '"1"')), 'display_name_invalid');
  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', payload - 'city_id'), 'city_required');
  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', jsonb_set(payload, '{city_id}', '999999')), 'city_not_found');
  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', jsonb_set(payload, '{dna_self,net_game}', '3')), 'invalid_dna_self');

  v := public.complete_onboarding(payload);
  perform tests.assert_eq((v ->> 'needs_onboarding')::boolean, false, 'onboarded');
  perform tests.assert_eq(v -> 'profile' ->> 'display_name', 'Иван Петров', 'name whitespace normalised');
  perform tests.assert_near((v -> 'rating' ->> 'mu')::double precision, 3.2, 1e-9, 'calibrated level');
  perform tests.assert_eq((v -> 'rating' ->> 'provisional')::boolean, true, 'new rating is provisional');

  -- Retrying onboarding is idempotent and does not change anything.
  v := public.complete_onboarding(jsonb_set(payload, '{display_name}', '"Другое Имя"'));
  perform tests.assert_eq(v -> 'profile' ->> 'display_name', 'Иван Петров', 'idempotent onboarding');

  perform tests.act_as(u2);
  perform tests.expect_error(format('select public.complete_onboarding(%L::jsonb)', payload), 'username_taken');
  v := public.check_username('IVAN_PETROV');
  perform tests.assert_eq((v ->> 'available')::boolean, false, 'username taken (case-insensitive)');
  v := public.check_username('ivan_2');
  perform tests.assert_eq((v ->> 'available')::boolean, true, 'username available');

  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.player_dna where player_id = u)::int, 6, 'DNA initialised');
  perform tests.assert((select offset_mean from public.player_dna where player_id = u and dimension = 'net_game')
                     > (select offset_mean from public.player_dna where player_id = u and dimension = 'consistency_decisions'),
                     'self assessment shapes DNA');
  perform tests.assert_near((select avg(offset_mean) from public.player_dna where player_id = u), 0, 1e-9, 'DNA is centred');
end $$;

create function tests.test_profile_update()
returns void language plpgsql as $$
declare
  a uuid := tests.player('anna_k');
  b uuid := tests.player('boris_k');
  v jsonb;
  club jsonb;
begin
  perform tests.act_as(a);
  club := public.create_club(1, '  Padel   Arena ');
  perform tests.assert_eq(club ->> 'name', 'Padel Arena', 'club name normalised');
  perform tests.assert_eq((public.create_club(1, 'padel arena') ->> 'id'), club ->> 'id', 'club deduplicated');
  v := public.update_profile(jsonb_build_object('club_id', (club ->> 'id')::bigint, 'bio', 'Играю по выходным', 'preferred_side', 'left'));
  perform tests.assert_eq(v -> 'profile' -> 'club' ->> 'name', 'Padel Arena', 'club set');
  perform tests.assert_eq(v -> 'profile' ->> 'preferred_side', 'left', 'side updated');
  v := public.update_profile('{"city_id":2}');
  perform tests.assert(v -> 'profile' -> 'club' = 'null'::jsonb, 'changing city clears club from another city');
  perform tests.expect_error($q$ select public.update_profile('{"username":"boris_k"}') $q$, 'username_taken');
  perform tests.expect_error($q$ select public.update_profile('{"preferred_side":"middle"}') $q$, 'invalid_side');
  perform tests.expect_error(format('select public.update_profile(%L::jsonb)', jsonb_build_object('bio', repeat('я', 161))), 'bio_too_long');
  perform tests.expect_error(format('select public.set_avatar(%L)', b::text || '/abcdefgh12.jpg'), 'invalid_avatar_path', 'cannot point avatar at another user folder');
  v := public.set_avatar(a::text || '/abcdefgh12.jpg');
  perform tests.assert_eq(v -> 'profile' ->> 'avatar_path', a::text || '/abcdefgh12.jpg', 'avatar set');
end $$;

create function tests.test_match_creation_validation()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('p_one'), tests.player('p_two'), tests.player('p_three'), tests.player('p_four')];
  outsider uuid := tests.player('p_outsider');
  ghost uuid := tests.new_user('ghost@padel.test');
  base jsonb;
begin
  base := jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '1 hour',
                             'players', tests.lineup(p), 'sets', tests.sets(6, 4, 6, 4));
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{players}', tests.lineup(array[p[1], p[1], p[3], p[4]]))), 'duplicate_player');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{players}', tests.lineup(array[outsider, p[2], p[3], p[4]]))), 'creator_not_participant');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{players}', tests.lineup(array[p[1], ghost, p[3], p[4]]))), 'player_not_found', 'players must be onboarded');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{players}', (tests.lineup(p) - 3) || jsonb_build_array(jsonb_build_object('player_id', p[4], 'team', 2, 'court_side', 'right')))),
    'match_lineup_invalid', 'two players in one position');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{players}', tests.lineup(p) - 3)), 'match_lineup_invalid', 'three players');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{played_at}', to_jsonb(now() + interval '1 day'))), 'played_at_in_future');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{played_at}', to_jsonb(now() - interval '20 days'))), 'played_at_too_old', 'ranked within 14 days');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{sets}', tests.sets(6, 5, 6, 4))), 'invalid_score');
  perform tests.expect_error(format('select public.create_match(%L::jsonb, null)', base), 'idempotency_key_required');

  -- Friendly matches may be older than ranked ones.
  perform public.create_match(jsonb_set(jsonb_set(base, '{match_type}', '"friendly"'), '{played_at}', to_jsonb(now() - interval '20 days')), gen_random_uuid());
end $$;

create function tests.test_match_idempotency_and_duplicates()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('i_one'), tests.player('i_two'), tests.player('i_three'), tests.player('i_four')];
  k uuid := gen_random_uuid();
  base jsonb;
  m1 jsonb;
  m2 jsonb;
begin
  base := jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '1 hour',
                             'players', tests.lineup(p), 'sets', tests.sets(6, 4, 6, 4));
  perform tests.act_as(p[1]);
  m1 := public.create_match(base, k);
  m2 := public.create_match(base, k);
  perform tests.assert_eq(m1 ->> 'id', m2 ->> 'id', 'same idempotency key returns the same match');
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.matches where created_by = p[1])::int, 1, 'only one match stored');

  -- Another participant entering the same match is rejected as a duplicate.
  perform tests.act_as(p[3]);
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_set(base, '{players}', tests.lineup(array[p[3], p[4], p[1], p[2]]))), 'duplicate_match');
end $$;

create function tests.test_match_confirmation_flow()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('c_one'), tests.player('c_two'), tests.player('c_three'), tests.player('c_four')];
  m uuid;
  v jsonb;
  mu_before double precision;
begin
  m := tests.match(p);
  select mu into mu_before from public.player_ratings where player_id = p[1];

  perform tests.act_as(p[2]);
  v := public.match_detail(m);
  perform tests.assert_eq(v ->> 'status', 'pending', 'pending after creation');
  perform tests.assert_eq((v -> 'viewer' ->> 'can_confirm')::boolean, true, 'participant can confirm');
  perform tests.assert_eq((v -> 'viewer' ->> 'can_edit')::boolean, false, 'only creator edits');
  perform tests.assert(v -> 'analysis' -> 'projected_change' ->> 'delta' is not null, 'projection for pending ranked match');

  v := public.confirm_match(m, 1);
  v := public.confirm_match(m, 1);
  perform tests.assert_eq(v ->> 'status', 'pending', 'still waiting for others; repeated confirmation is harmless');

  perform tests.act_as(p[3]);
  perform public.confirm_match(m, 1);
  perform tests.act_as(p[4]);
  v := public.confirm_match(m, 1);
  perform tests.assert_eq(v ->> 'status', 'confirmed', 'confirmed by all four');
  perform tests.assert_eq((v ->> 'rating_applied')::boolean, true, 'rating applied');

  -- Confirming again after finalisation is idempotent.
  perform tests.act_as(p[3]);
  v := public.confirm_match(m, 1);
  perform tests.assert_eq(v ->> 'status', 'confirmed', 'idempotent after confirmation');

  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.rating_events where match_id = m)::int, 4, 'one rating event per player');
  perform tests.assert((select mu from public.player_ratings where player_id = p[1]) > mu_before, 'winner rating increased');
  perform tests.assert_eq((select ranked_matches from public.player_ratings where player_id = p[3]), 1, 'ranked match counted');

  -- Applying again is a no-op.
  perform private.apply_ranked_match(m);
  perform tests.assert_eq((select count(*) from public.rating_events where match_id = m)::int, 4, 'no double application');

  -- Confirmed matches are immutable.
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.update_match(%L, 1, %L::jsonb, gen_random_uuid())', m,
    jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '1 hour',
                       'players', tests.lineup(p), 'sets', tests.sets(6, 0, 6, 0))), 'match_locked');
  perform tests.expect_error(format('select public.cancel_match(%L, 1)', m), 'match_locked');
  perform tests.act_as(p[2]);
  perform tests.expect_error(format('select public.dispute_match(%L, 1, %L)', m, 'wrong_score'), 'match_locked');
end $$;

create function tests.test_match_dispute_edit_cancel()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('d_one'), tests.player('d_two'), tests.player('d_three'), tests.player('d_four')];
  m uuid;
  v jsonb;
  edit jsonb;
  k uuid := gen_random_uuid();
begin
  m := tests.match(p);
  perform tests.act_as(p[2]);
  perform public.confirm_match(m, 1);
  perform tests.act_as(p[3]);
  perform tests.expect_error(format('select public.dispute_match(%L, 1, %L)', m, 'nonsense'), 'invalid_dispute_reason');
  v := public.dispute_match(m, 1, 'wrong_score', 'Было 6:4 7:5');
  perform tests.assert_eq(v ->> 'status', 'disputed', 'disputed');
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.dispute_match(%L, 1, %L)', m, 'wrong_score'), 'creator_cannot_dispute');

  -- Disputed match cannot be finalised even if the rest confirm.
  perform tests.act_as(p[4]);
  v := public.confirm_match(m, 1);
  perform tests.assert_eq(v ->> 'status', 'disputed', 'dispute blocks confirmation');

  -- Creator fixes the score: version bumps and other responses reset.
  edit := jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '2 hours',
                             'players', tests.lineup(p), 'sets', tests.sets(6, 4, 7, 5));
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.update_match(%L, 7, %L::jsonb, gen_random_uuid())', m, edit), 'version_conflict');
  v := public.update_match(m, 1, edit, k);
  perform tests.assert_eq((v ->> 'version')::int, 2, 'version bumped');
  perform tests.assert_eq(v ->> 'status', 'pending', 'back to pending');
  v := public.update_match(m, 1, edit, k);
  perform tests.assert_eq((v ->> 'version')::int, 2, 'retried edit is idempotent');
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.match_players where match_id = m and response = 'pending')::int, 3, 'responses reset');

  -- A confirmation for the old version is rejected.
  perform tests.act_as(p[2]);
  perform tests.expect_error(format('select public.confirm_match(%L, 1)', m), 'version_conflict');
  perform public.confirm_match(m, 2);

  -- Only the creator cancels.
  perform tests.expect_error(format('select public.cancel_match(%L, 2)', m), 'forbidden');
  perform tests.act_as(p[1]);
  v := public.cancel_match(m, 2);
  perform tests.assert_eq(v ->> 'status', 'cancelled', 'cancelled');
  v := public.cancel_match(m, 2);
  perform tests.assert_eq(v ->> 'status', 'cancelled', 'cancel is idempotent');
  perform tests.act_as(p[3]);
  perform tests.expect_error(format('select public.confirm_match(%L, 2)', m), 'match_closed');
end $$;

create function tests.test_match_expiry()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('e_one'), tests.player('e_two'), tests.player('e_three'), tests.player('e_four')];
  m uuid;
begin
  m := tests.match(p);
  set local session_replication_role = replica;
  update public.matches set updated_at = now() - interval '8 days' where id = m;
  set local session_replication_role = origin;
  perform tests.act_as(p[2]);
  perform tests.expect_error(format('select public.confirm_match(%L, 1)', m), 'match_closed');
  perform tests.expect_error(format('select public.dispute_match(%L, 1, %L)', m, 'other'), 'match_closed');
  perform tests.assert_eq(public.match_detail(m) ->> 'status', 'expired', 'reads expire stale matches');
  perform tests.as_admin();
  perform tests.assert_eq((select status from public.matches where id = m), 'expired', 'stale match expired');
  perform tests.assert_eq((select count(*) from public.rating_events where match_id = m)::int, 0, 'no rating for expired match');
end $$;

create function tests.test_friendly_does_not_change_rating()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('f_one'), tests.player('f_two'), tests.player('f_three'), tests.player('f_four')];
  m uuid;
  before double precision;
begin
  select mu into before from public.player_ratings where player_id = p[1];
  m := tests.match(p, 'friendly');
  perform tests.confirm_all(m);
  perform tests.assert_eq((select status from public.matches where id = m), 'confirmed', 'friendly confirmed');
  perform tests.assert_eq((select mu from public.player_ratings where player_id = p[1]), before, 'friendly keeps rating');
  perform tests.assert_eq((select ranked_matches from public.player_ratings where player_id = p[1]), 0, 'not counted as ranked');
end $$;

create function tests.test_anti_farming_weight()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('w_one'), tests.player('w_two'), tests.player('w_three'), tests.player('w_four')];
  m uuid;
begin
  m := tests.match(p, 'ranked', tests.sets(6, 4, 6, 4), 'best_of_3', now() - interval '5 hours');
  perform tests.confirm_all(m);
  m := tests.match(p, 'ranked', tests.sets(6, 2, 6, 2), 'best_of_3', now() - interval '3 hours');
  perform tests.confirm_all(m);
  m := tests.match(array[p[3], p[4], p[1], p[2]], 'ranked', tests.sets(6, 1, 6, 1), 'best_of_3', now() - interval '1 hour');
  perform tests.confirm_all(m);
  perform tests.assert_near((select rating_weight from public.matches where id = m), 0.5, 1e-9, 'third match with same four players is half weight');
end $$;

create function tests.test_ranked_daily_limit()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('l_one'), tests.player('l_two'), tests.player('l_three'), tests.player('l_four')];
  q uuid[];
begin
  for i in 1..6 loop
    q := array[p[1], tests.player('l_x' || chr(96 + i)), tests.player('l_y' || chr(96 + i)), tests.player('l_z' || chr(96 + i))];
    perform tests.match(q, 'ranked', tests.sets(6, 4, 6, 4), 'best_of_3', now() - make_interval(mins => 10 * i));
  end loop;
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.create_match(%L::jsonb, gen_random_uuid())',
    jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '2 hours',
                       'players', tests.lineup(p), 'sets', tests.sets(6, 4, 6, 4))), 'too_many_ranked_matches');
end $$;

create function tests.test_feedback_and_dna()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('g_one'), tests.player('g_two'), tests.player('g_three'), tests.player('g_four')];
  m uuid;
  before double precision;
  v jsonb;
begin
  m := tests.match(p);
  perform tests.act_as(p[2]);
  perform tests.expect_error(format('select public.submit_match_feedback(%L, %L::jsonb)', m,
    jsonb_build_object('ratings', jsonb_build_array(jsonb_build_object('player_id', p[1], 'strengths', jsonb_build_array('net_game'))))),
    'match_not_confirmed');
  perform tests.confirm_all(m);

  select offset_mean into before from public.player_dna where player_id = p[1] and dimension = 'net_game';
  perform tests.act_as(p[2]);
  perform tests.expect_error(format('select public.submit_match_feedback(%L, %L::jsonb)', m,
    jsonb_build_object('ratings', jsonb_build_array(jsonb_build_object('player_id', p[2], 'strengths', jsonb_build_array('net_game'))))),
    'invalid_feedback_target', 'no self feedback');
  perform tests.expect_error(format('select public.submit_match_feedback(%L, %L::jsonb)', m,
    jsonb_build_object('ratings', jsonb_build_array(jsonb_build_object('player_id', p[1], 'strengths', jsonb_build_array('net_game', 'defense', 'overheads'))))),
    'invalid_feedback', 'max two strengths');
  perform tests.expect_error(format('select public.submit_match_feedback(%L, %L::jsonb)', m,
    jsonb_build_object('ratings', jsonb_build_array(jsonb_build_object('player_id', p[1], 'strengths', jsonb_build_array('net_game'), 'improvements', jsonb_build_array('net_game'))))),
    'invalid_feedback', 'strength and weakness cannot overlap');
  v := public.submit_match_feedback(m, jsonb_build_object('ratings', jsonb_build_array(
    jsonb_build_object('player_id', p[1], 'strengths', jsonb_build_array('net_game', 'overheads'), 'improvements', jsonb_build_array('defense')),
    jsonb_build_object('player_id', p[3], 'strengths', jsonb_build_array('defense'))
  )));
  perform tests.assert_eq(jsonb_array_length(v -> 'viewer' -> 'feedback'), 2, 'feedback stored');
  -- Resubmitting replaces instead of duplicating.
  perform public.submit_match_feedback(m, jsonb_build_object('ratings', jsonb_build_array(
    jsonb_build_object('player_id', p[1], 'strengths', jsonb_build_array('net_game', 'overheads'), 'improvements', jsonb_build_array('defense')))));
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.match_feedback where match_id = m and rater_id = p[2])::int, 2, 'no duplicates');
  perform tests.assert((select offset_mean from public.player_dna where player_id = p[1] and dimension = 'net_game') > before,
    'peer feedback moves DNA');
  perform tests.assert((select peer_signals from public.player_dna where player_id = p[1] and dimension = 'defense') = 1, 'signal counted');

  update public.matches set confirmed_at = now() - interval '15 days' where id = m;
  perform tests.act_as(p[3]);
  perform tests.expect_error(format('select public.submit_match_feedback(%L, %L::jsonb)', m,
    jsonb_build_object('ratings', jsonb_build_array(jsonb_build_object('player_id', p[1], 'strengths', jsonb_build_array('net_game'))))),
    'feedback_window_closed');
end $$;

create function tests.test_preview_and_history()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('h_one', 3, 2), tests.player('h_two', 3, 2), tests.player('h_three', 1, 0), tests.player('h_four', 1, 0)];
  v jsonb;
  m uuid;
begin
  perform tests.act_as(p[1]);
  v := public.preview_match(jsonb_build_object('format', 'best_of_3', 'players', tests.lineup(p)));
  perform tests.assert((v ->> 'expected_win_team1')::double precision > 0.6, 'stronger team favoured');
  perform tests.assert((v -> 'players' -> 0 ->> 'if_team1_wins')::double precision > 0, 'win increases');
  perform tests.assert((v -> 'players' -> 0 ->> 'if_team2_wins')::double precision < 0, 'loss decreases');
  perform tests.assert(abs((v -> 'players' -> 0 ->> 'if_team2_wins')::double precision)
                       > abs((v -> 'players' -> 0 ->> 'if_team1_wins')::double precision), 'favourite risks more than it gains');
  perform tests.expect_error(format('select public.preview_match(%L::jsonb)',
    jsonb_build_object('format', 'best_of_3', 'players', tests.lineup(array[p[1], p[1], p[3], p[4]]))), 'duplicate_player');

  m := tests.match(p);
  perform tests.confirm_all(m);
  perform tests.act_as(p[3]);
  v := public.rating_history(p[3], 30);
  perform tests.assert_eq(jsonb_array_length(v -> 'points'), 2, 'calibration + one match');
  perform tests.assert((v -> 'points' -> 1 ->> 'delta')::double precision < 0, 'loss recorded');
  v := public.match_detail(m);
  perform tests.assert((v -> 'players' -> 0 -> 'rating_change' -> 'details' ->> 'expected_win') is not null, 'explanation stored');
end $$;
