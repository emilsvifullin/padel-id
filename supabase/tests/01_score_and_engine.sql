-- Score validation and rating engine properties.

create function tests.test_score_valid_cases()
returns void language plpgsql as $$
declare
  v jsonb;
begin
  v := private.validate_score('best_of_3', tests.sets(6, 4, 6, 3));
  perform tests.assert_eq((v ->> 'winner_team')::int, 1, 'straight sets winner');
  perform tests.assert_eq((v ->> 'team1_games')::int, 12, 'games team 1');
  perform tests.assert_eq((v ->> 'team2_games')::int, 7, 'games team 2');

  v := private.validate_score('best_of_3', tests.sets(4, 6, 7, 5, 6, 7));
  perform tests.assert_eq((v ->> 'winner_team')::int, 2, 'three sets winner');
  perform tests.assert_eq((v ->> 'team2_sets')::int, 2, 'sets team 2');

  v := private.validate_score('best_of_3', '[{"t1":7,"t2":6,"tb1":7,"tb2":5},{"t1":7,"t2":6,"tb1":12,"tb2":10}]');
  perform tests.assert_eq((v -> 'sets' -> 1 ->> 'tb1')::int, 12, 'extended tie-break kept');

  v := private.validate_score('best_of_3_super_tiebreak', '[{"t1":6,"t2":4},{"t1":3,"t2":6},{"t1":10,"t2":8,"super_tiebreak":true}]');
  perform tests.assert_eq((v ->> 'winner_team')::int, 1, 'super tie-break winner');
  perform tests.assert_eq((v ->> 'team1_games')::int, 10, 'super tie-break counts as one game');

  v := private.validate_score('best_of_3_super_tiebreak', '[{"t1":6,"t2":4},{"t1":3,"t2":6},{"t1":12,"t2":14,"super_tiebreak":true}]');
  perform tests.assert_eq((v ->> 'winner_team')::int, 2, 'extended super tie-break');

  v := private.validate_score('single_set', tests.sets(5, 7));
  perform tests.assert_eq((v ->> 'winner_team')::int, 2, 'single set');
end $$;

create function tests.test_score_invalid_cases()
returns void language plpgsql as $$
begin
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(6, 5, 6, 3)) $q$, 'invalid_score', '6-5 is not final');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(8, 6, 6, 3)) $q$, 'invalid_score', '8-6 impossible');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(7, 3, 6, 3)) $q$, 'invalid_score', '7-3 impossible');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(6, 6, 6, 3)) $q$, 'invalid_score', 'draw set');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(6, 4)) $q$, 'invalid_score', 'one set in best of three');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(6, 4, 3, 6)) $q$, 'invalid_score', 'unfinished match');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', tests.sets(6, 4, 6, 3, 6, 2)) $q$, 'invalid_score', 'extra set after decision');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":7,"t2":6,"tb1":6,"tb2":4},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'tie-break must reach 7');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":7,"t2":6,"tb1":5,"tb2":7},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'tie-break winner must match set winner');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":7,"t2":6,"tb1":9,"tb2":5},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'extended tie-break must end at margin 2');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":6,"t2":4,"tb1":7,"tb2":5},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'tie-break only for 7-6');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":6.5,"t2":4},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'fractional games');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":-6,"t2":4},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'negative games');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":"6","t2":4},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'string games');
  perform tests.expect_error($q$ select private.validate_score('best_of_3_super_tiebreak', '[{"t1":6,"t2":4},{"t1":3,"t2":6},{"t1":6,"t2":3}]') $q$, 'invalid_score', 'deciding set must be STB');
  perform tests.expect_error($q$ select private.validate_score('best_of_3_super_tiebreak', '[{"t1":6,"t2":4},{"t1":3,"t2":6},{"t1":10,"t2":9,"super_tiebreak":true}]') $q$, 'invalid_score', 'STB margin');
  perform tests.expect_error($q$ select private.validate_score('best_of_3', '[{"t1":10,"t2":8,"super_tiebreak":true},{"t1":6,"t2":0}]') $q$, 'invalid_score', 'STB not allowed in classic format');
  perform tests.expect_error($q$ select private.validate_score('single_set', tests.sets(6, 4, 6, 4)) $q$, 'invalid_score', 'single set format');
  perform tests.expect_error($q$ select private.validate_score('best_of_5', tests.sets(6, 4, 6, 4)) $q$, 'invalid_format', 'unknown format');
end $$;

create function tests.test_engine_probabilities()
returns void language plpgsql as $$
begin
  perform tests.assert_near(private.match_win_prob(0, 'best_of_3'), 0.5, 1e-9, 'symmetric at zero');
  perform tests.assert_near(private.match_win_prob(0.5, 'best_of_3'), 0.736, 0.01, 'half level gap');
  perform tests.assert_near(private.match_win_prob(1.0, 'best_of_3'), 0.896, 0.01, 'one level gap');
  perform tests.assert_near(private.match_win_prob(0.7, 'best_of_3') + private.match_win_prob(-0.7, 'best_of_3'), 1, 1e-9, 'complementary');
  perform tests.assert(private.match_win_prob(0.5, 'single_set') < private.match_win_prob(0.5, 'best_of_3'), 'longer format favours the stronger team');
  perform tests.assert(private.expected_outcome(0.8, 0.5, 'best_of_3', 'match') < private.match_win_prob(0.8, 'best_of_3'),
    'uncertainty pulls expectation towards 50 %');
  perform tests.assert_near(private.team_strength(3, 3), 3, 1e-9, 'equal partners');
  perform tests.assert_near(private.team_strength(5, 2), 3.2, 1e-9, 'unbalanced pair penalised');
  perform tests.assert_eq(private.reliability(0.95), 0, 'reliability floor');
  perform tests.assert_eq(private.reliability(0.25), 100, 'reliability ceiling');
end $$;

create function tests.test_engine_update_properties()
returns void language plpgsql as $$
declare
  base jsonb := '[
    {"id":"00000000-0000-0000-0000-000000000001","team":1,"mu":3.0,"sigma":0.35,"last_activity":"2026-01-01T00:00:00Z"},
    {"id":"00000000-0000-0000-0000-000000000002","team":1,"mu":3.0,"sigma":0.35,"last_activity":"2026-01-01T00:00:00Z"},
    {"id":"00000000-0000-0000-0000-000000000003","team":2,"mu":3.0,"sigma":0.35,"last_activity":"2026-01-01T00:00:00Z"},
    {"id":"00000000-0000-0000-0000-000000000004","team":2,"mu":3.0,"sigma":0.35,"last_activity":"2026-01-01T00:00:00Z"}]';
  at constant timestamptz := '2026-01-05T00:00:00Z';
  r jsonb;
  r2 jsonb;
  d1 double precision;
  d3 double precision;
begin
  r := private.compute_rating_update(base, 'best_of_3', 1::smallint, 12, 9, 1.0, at);
  d1 := (r -> 'players' -> 0 ->> 'delta')::double precision;
  d3 := (r -> 'players' -> 2 ->> 'delta')::double precision;
  perform tests.assert(d1 > 0, 'winners gain');
  perform tests.assert(d3 < 0, 'losers lose');
  perform tests.assert_near(d1 + d3, 0, 1e-9, 'zero-sum for symmetric uncertainty');
  perform tests.assert((r -> 'players' -> 0 ->> 'sigma_after')::double precision < 0.35, 'uncertainty shrinks');

  -- Upset win moves more than an expected win.
  r := private.compute_rating_update(jsonb_set(jsonb_set(base, '{2,mu}', '3.6'), '{3,mu}', '3.6'), 'best_of_3', 1::smallint, 12, 10, 1.0, at);
  r2 := private.compute_rating_update(jsonb_set(jsonb_set(base, '{0,mu}', '3.6'), '{1,mu}', '3.6'), 'best_of_3', 1::smallint, 12, 10, 1.0, at);
  perform tests.assert((r -> 'players' -> 0 ->> 'delta')::double precision > (r2 -> 'players' -> 0 ->> 'delta')::double precision,
    'upset rewarded more');
  perform tests.assert((r2 -> 'players' -> 0 ->> 'delta')::double precision > 0, 'favourite still gains when winning narrowly');

  -- A provisional player moves much more than an established one.
  r := private.compute_rating_update(jsonb_set(base, '{0,sigma}', '0.9'), 'best_of_3', 1::smallint, 12, 9, 1.0, at);
  perform tests.assert((r -> 'players' -> 0 ->> 'delta')::double precision > 3 * (r -> 'players' -> 1 ->> 'delta')::double precision,
    'uncertain partner absorbs most of the change');

  -- Margin modulates the size but never the sign.
  r := private.compute_rating_update(base, 'best_of_3', 1::smallint, 12, 2, 1.0, at);
  r2 := private.compute_rating_update(base, 'best_of_3', 1::smallint, 13, 12, 1.0, at);
  perform tests.assert((r -> 'players' -> 0 ->> 'delta')::double precision > (r2 -> 'players' -> 0 ->> 'delta')::double precision,
    'dominant win counts more');
  perform tests.assert_near((r ->> 'margin_factor')::double precision, 1.3, 1e-9, 'margin capped');
  r2 := private.compute_rating_update(base, 'best_of_3', 1::smallint, 13, 14, 1.0, at);
  perform tests.assert((r2 -> 'players' -> 0 ->> 'delta')::double precision > 0, 'winning with fewer games still gains');

  -- Weight scales the change (anti-farming).
  r := private.compute_rating_update(base, 'best_of_3', 1::smallint, 12, 9, 0.5, at);
  r2 := private.compute_rating_update(base, 'best_of_3', 1::smallint, 12, 9, 1.0, at);
  perform tests.assert_near((r -> 'players' -> 0 ->> 'delta')::double precision,
    0.5 * (r2 -> 'players' -> 0 ->> 'delta')::double precision, 1e-9, 'weight halves the change');

  -- Inactivity inflates uncertainty.
  r := private.compute_rating_update(jsonb_set(base, '{0,last_activity}', '"2025-03-01T00:00:00Z"'), 'best_of_3', 1::smallint, 12, 9, 1.0, at);
  perform tests.assert((r -> 'players' -> 0 ->> 'sigma_effective')::double precision > 0.45, 'idle player is less certain');
  perform tests.assert((r -> 'players' -> 0 ->> 'sigma_effective')::double precision <= 0.6 + 1e-9, 'inflation capped');

  -- Bounds.
  r := private.compute_rating_update(jsonb_set(jsonb_set(base, '{0,mu}', '6.99'), '{0,sigma}', '1.2'), 'best_of_3', 1::smallint, 12, 0, 1.0, at);
  perform tests.assert((r -> 'players' -> 0 ->> 'mu_after')::double precision <= 7, 'upper bound');
  perform tests.assert(abs((r -> 'players' -> 0 ->> 'delta')::double precision) <= 0.5, 'per-match cap');
end $$;

create function tests.test_calibration()
returns void language plpgsql as $$
declare
  v jsonb;
begin
  v := private.calibrate('{"experience":"none","frequency":"rare","racket":"none","glass":0,"net":0,"competition":0}');
  perform tests.assert_near((v ->> 'mu')::double precision, 0.5, 1e-9, 'absolute beginner');
  v := private.calibrate('{"experience":"none","frequency":"often","racket":"competitive","glass":3,"net":3,"competition":3}');
  perform tests.assert((v ->> 'mu')::double precision <= 1.5, 'no padel experience caps the start');
  v := private.calibrate('{"experience":"gt3y","frequency":"often","racket":"competitive","glass":3,"net":3,"competition":3}');
  perform tests.assert_near((v ->> 'mu')::double precision, 5.0, 1e-9, 'start capped at 5.0');
  perform tests.assert_near((v ->> 'sigma')::double precision, 0.9, 1e-9, 'start is uncertain');
  perform tests.expect_error($q$ select private.calibrate('{"experience":"1to3y","frequency":"weekly","racket":"none","glass":4,"net":0,"competition":0}') $q$, 'invalid_calibration');
  perform tests.expect_error($q$ select private.calibrate('{"experience":"forever","frequency":"weekly","racket":"none","glass":1,"net":0,"competition":0}') $q$, 'invalid_calibration');
end $$;
