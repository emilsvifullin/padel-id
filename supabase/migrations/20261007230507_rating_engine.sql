-- Padel ID rating engine ("PIR-1").
--
-- Model
-- -----
-- Each player i has a skill estimate mu_i on the 0–7 padel scale and an
-- uncertainty sigma_i (standard deviation, same units).
--
-- * Team strength: R = (a + b) / 2 − 0.1 · |a − b|. A large level gap inside a
--   pair weakens the pair (opponents play the weaker partner).
-- * Game model: a team wins a game with probability p = logistic(Δ / 2.1) where
--   Δ = R_team − R_opponents. Sets (6 games, tie-break at 6–6) and the match
--   format (best of three, best of three with a super tie-break, single set)
--   are evaluated exactly with dynamic programming, so the expected match win
--   probability is consistent with the game model (Δ = 0.5 → ≈74 %, Δ = 1 → ≈90 %).
-- * Uncertainty: the expectation is integrated over Δ ~ N(ΔR, V) with 5-point
--   Gauss–Hermite quadrature, where V = Σ coef_i² · sigma_i².
-- * Update: an extended Kalman filter step on the match outcome W ∈ {0, 1}:
--     H_i  = ±coef_i · dE/dΔ
--     S    = Σ H_i² sigma_i² + E (1 − E)
--     K_i  = sigma_i² H_i / S
--     Δmu_i = K_i · (W − E) · margin · weight         (|Δmu_i| ≤ 0.5)
--     sigma_i'² = max(0.2², sigma_i² (1 − weight · K_i H_i)) + 0.002 · weight
--   The sign of every change follows the result: winners never lose rating.
-- * Margin: the score modulates the size (not the sign) of the change:
--     margin = clamp(1 + 1.5 · (G − E[G]) · (W ? 1 : −1), 0.7, 1.3)
--   where G is the share of games won.
-- * Inactivity: sigma² grows by 0.0004 per day after 14 idle days (up to 0.6).
-- * Anti-farming: repeated ranked matches between the same four players within
--   30 days are down-weighted: weight = 1 / (1 + 0.5 · n_previous).

create or replace function private.game_win_prob(p_delta double precision)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 1.0 / (1.0 + exp(-p_delta / 2.1))
$$;

-- Probability of winning a 6-game set with a tie-break at 6–6.
create or replace function private.set_win_prob(p double precision, p_tiebreak double precision)
returns double precision
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  s double precision[] := array_fill(0::double precision, array[8, 8]);
  a integer;
  b integer;
  total integer;
  v double precision;
  win double precision := 0;
begin
  s[1][1] := 1;
  for total in 0..12 loop
    for a in 0..least(total, 7) loop
      b := total - a;
      continue when b < 0 or b > 7;
      v := s[a + 1][b + 1];
      continue when v = 0;
      if (a = 6 and b <= 4) or a = 7 then
        win := win + v;
        continue;
      end if;
      continue when (b = 6 and a <= 4) or b = 7;
      if a = 6 and b = 6 then
        win := win + v * p_tiebreak;
        continue;
      end if;
      s[a + 2][b + 1] := s[a + 2][b + 1] + v * p;
      s[a + 1][b + 2] := s[a + 1][b + 2] + v * (1 - p);
    end loop;
  end loop;
  return win;
end;
$$;

create or replace function private.match_win_prob(p_delta double precision, p_format text)
returns double precision
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  p double precision := private.game_win_prob(p_delta);
  q double precision := private.set_win_prob(p, p);
begin
  return case p_format
    when 'single_set' then q
    when 'best_of_3' then q * q * (3 - 2 * q)
    when 'best_of_3_super_tiebreak' then q * q + 2 * q * (1 - q) * p
  end;
end;
$$;

-- E[f(Δ)] for Δ ~ N(p_delta, p_var); f = match win probability (p_kind = 'match')
-- or game win probability (p_kind = 'game').
create or replace function private.expected_outcome(
  p_delta double precision,
  p_var double precision,
  p_format text,
  p_kind text
)
returns double precision
language plpgsql
immutable
parallel safe
set search_path = ''
as $$
declare
  nodes constant double precision[] := array[-2.0201828704560856, -0.9585724646138185, 0, 0.9585724646138185, 2.0201828704560856];
  weights constant double precision[] := array[0.01995324205904591, 0.39361932315224116, 0.9453087204829419, 0.39361932315224116, 0.01995324205904591];
  spread double precision := sqrt(2 * greatest(p_var, 0));
  acc double precision := 0;
  x double precision;
begin
  for i in 1..5 loop
    x := p_delta + spread * nodes[i];
    acc := acc + weights[i] * case p_kind
      when 'match' then private.match_win_prob(x, p_format)
      else private.game_win_prob(x)
    end;
  end loop;
  return acc / sqrt(pi());
end;
$$;

create or replace function private.team_strength(a double precision, b double precision)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select (a + b) / 2 - 0.1 * abs(a - b)
$$;

-- Partial derivative of the team strength with respect to the player's own rating.
create or replace function private.team_coef(self double precision, partner double precision)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 0.5 - 0.1 * sign(self - partner)
$$;

-- Rating reliability in percent derived from sigma (0.95 → 0 %, 0.25 → 100 %).
create or replace function private.reliability(p_sigma double precision)
returns integer
language sql
immutable
parallel safe
set search_path = ''
as $$
  select greatest(0, least(100, round(100 * (1 - (p_sigma - 0.25) / 0.70))))::integer
$$;

-- Effective sigma after inactivity inflation.
create or replace function private.effective_sigma(
  p_sigma double precision,
  p_last_activity timestamptz,
  p_at timestamptz
)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select sqrt(
    p_sigma ^ 2 + least(
      0.0004 * greatest(0, extract(epoch from (p_at - p_last_activity)) / 86400.0 - 14),
      greatest(0, 0.36 - p_sigma ^ 2)
    )
  )
$$;

-- Initial rating from the onboarding questionnaire.
create or replace function private.calibrate(p_answers jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  experience constant jsonb := '{"none":0, "lt6m":0.3, "6to12m":0.6, "1to3y":1.0, "gt3y":1.4}';
  frequency constant jsonb := '{"rare":0, "monthly":0.1, "weekly":0.25, "often":0.4}';
  racket constant jsonb := '{"none":0, "amateur":0.15, "trained":0.35, "competitive":0.6}';
  glass constant double precision[] := array[0, 0.35, 0.8, 1.3];
  net constant double precision[] := array[0, 0.3, 0.7, 1.1];
  competition constant double precision[] := array[0, 0.2, 0.5, 0.9];
  v_mu double precision := 0.5;
  v_glass integer;
  v_net integer;
  v_comp integer;
begin
  if p_answers is null or private.jtype(p_answers) <> 'object'
     or not (experience ? (p_answers ->> 'experience'))
     or not (frequency ? (p_answers ->> 'frequency'))
     or not (racket ? (p_answers ->> 'racket'))
     or private.jtype(p_answers -> 'glass') <> 'number'
     or private.jtype(p_answers -> 'net') <> 'number'
     or private.jtype(p_answers -> 'competition') <> 'number' then
    perform private.fail('invalid_calibration');
  end if;
  v_glass := (p_answers ->> 'glass')::integer;
  v_net := (p_answers ->> 'net')::integer;
  v_comp := (p_answers ->> 'competition')::integer;
  if v_glass not between 0 and 3 or v_net not between 0 and 3 or v_comp not between 0 and 3 then
    perform private.fail('invalid_calibration');
  end if;

  v_mu := v_mu
    + (experience ->> (p_answers ->> 'experience'))::double precision
    + (frequency ->> (p_answers ->> 'frequency'))::double precision
    + (racket ->> (p_answers ->> 'racket'))::double precision
    + glass[v_glass + 1]
    + net[v_net + 1]
    + competition[v_comp + 1];

  if p_answers ->> 'experience' = 'none' then
    v_mu := least(v_mu, 1.5);
  end if;
  v_mu := round(least(v_mu, 5.0)::numeric, 2)::double precision;

  return jsonb_build_object(
    'mu', v_mu,
    'sigma', 0.9,
    'answers', jsonb_build_object(
      'experience', p_answers ->> 'experience',
      'frequency', p_answers ->> 'frequency',
      'racket', p_answers ->> 'racket',
      'glass', v_glass,
      'net', v_net,
      'competition', v_comp
    )
  );
end;
$$;

-- Pure rating update. p_players: array of 4 objects
--   {id, team, mu, sigma, last_activity}
-- Returns the full explanation used both for applying and for previews.
create or replace function private.compute_rating_update(
  p_players jsonb,
  p_format text,
  p_winner smallint,
  p_games1 integer,
  p_games2 integer,
  p_weight double precision,
  p_at timestamptz
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  ids uuid[] := array[]::uuid[];
  teams integer[] := array[]::integer[];
  mus double precision[] := array[]::double precision[];
  sig double precision[] := array[]::double precision[];
  raw_sig double precision[] := array[]::double precision[];
  idle double precision[] := array[]::double precision[];
  coefs double precision[] := array[0, 0, 0, 0]::double precision[];
  t1 integer[] := array[]::integer[];
  t2 integer[] := array[]::integer[];
  r1 double precision;
  r2 double precision;
  delta double precision;
  var double precision := 0;
  e double precision;
  d double precision;
  eg double precision;
  g double precision;
  w double precision;
  margin double precision;
  s double precision := 0;
  h double precision[] := array[0, 0, 0, 0]::double precision[];
  k double precision;
  dm double precision;
  s2 double precision;
  new_mu double precision;
  sign_t double precision;
  results jsonb := '[]'::jsonb;
  item jsonb;
  partner integer;
begin
  if jsonb_array_length(p_players) <> 4 then
    perform private.fail('match_lineup_invalid');
  end if;

  for item in select value from jsonb_array_elements(p_players) loop
    ids := ids || (item ->> 'id')::uuid;
    teams := teams || (item ->> 'team')::integer;
    mus := mus || (item ->> 'mu')::double precision;
    raw_sig := raw_sig || (item ->> 'sigma')::double precision;
    sig := sig || private.effective_sigma(
      (item ->> 'sigma')::double precision,
      (item ->> 'last_activity')::timestamptz,
      p_at
    );
    idle := idle || greatest(0, floor(extract(epoch from (p_at - (item ->> 'last_activity')::timestamptz)) / 86400.0));
  end loop;

  for i in 1..4 loop
    if teams[i] = 1 then t1 := t1 || i; else t2 := t2 || i; end if;
  end loop;
  if cardinality(t1) <> 2 or cardinality(t2) <> 2 then
    perform private.fail('match_lineup_invalid');
  end if;

  r1 := private.team_strength(mus[t1[1]], mus[t1[2]]);
  r2 := private.team_strength(mus[t2[1]], mus[t2[2]]);
  delta := r1 - r2;

  for i in 1..4 loop
    partner := case
      when i = t1[1] then t1[2] when i = t1[2] then t1[1]
      when i = t2[1] then t2[2] else t2[1]
    end;
    coefs[i] := private.team_coef(mus[i], mus[partner]);
    var := var + coefs[i] ^ 2 * sig[i] ^ 2;
  end loop;

  e := private.expected_outcome(delta, var, p_format, 'match');
  d := (private.expected_outcome(delta + 0.01, var, p_format, 'match')
      - private.expected_outcome(delta - 0.01, var, p_format, 'match')) / 0.02;
  eg := private.expected_outcome(delta, var, p_format, 'game');
  g := p_games1::double precision / greatest(p_games1 + p_games2, 1);
  w := case when p_winner = 1 then 1 else 0 end;
  margin := greatest(0.7, least(1.3, 1 + 1.5 * (g - eg) * (case when w = 1 then 1 else -1 end)));

  for i in 1..4 loop
    sign_t := case when teams[i] = 1 then 1 else -1 end;
    h[i] := sign_t * coefs[i] * d;
    s := s + h[i] ^ 2 * sig[i] ^ 2;
  end loop;
  s := s + e * (1 - e);

  for i in 1..4 loop
    k := sig[i] ^ 2 * h[i] / s;
    dm := greatest(-0.5, least(0.5, k * (w - e) * margin * p_weight));
    new_mu := greatest(0, least(7, mus[i] + dm));
    s2 := greatest(0.04, sig[i] ^ 2 * (1 - p_weight * k * h[i])) + 0.002 * p_weight;
    s2 := least(s2, sig[i] ^ 2);
    results := results || jsonb_build_object(
      'id', ids[i],
      'team', teams[i],
      'mu_before', mus[i],
      'sigma_before', raw_sig[i],
      'sigma_effective', sig[i],
      'idle_days', idle[i],
      'coef', coefs[i],
      'gain', abs(k),
      'delta', new_mu - mus[i],
      'mu_after', new_mu,
      'sigma_after', sqrt(s2)
    );
  end loop;

  return jsonb_build_object(
    'algorithm', 'PIR-1',
    'format', p_format,
    'team1_strength', r1,
    'team2_strength', r2,
    'expected_win_team1', e,
    'expected_game_share_team1', eg,
    'game_share_team1', g,
    'winner_team', p_winner,
    'margin_factor', margin,
    'weight', p_weight,
    'players', results
  );
end;
$$;

-- Applies a confirmed ranked match to the four players' ratings. Must be called
-- inside the transaction that confirmed the match. Idempotent: a match is never
-- applied twice (guarded by matches.rating_applied and the unique
-- (player_id, match_id) constraint on rating_events).
create or replace function private.apply_ranked_match(p_match uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  m public.matches%rowtype;
  v_players jsonb;
  v_ids uuid[];
  v_same integer;
  v_weight double precision;
  v_result jsonb;
  p jsonb;
  v_partner jsonb;
  v_opponents jsonb;
  v_now timestamptz := now();
begin
  select * into m from public.matches where id = p_match for update;
  if not found or m.status <> 'confirmed' or m.match_type <> 'ranked' or m.rating_applied then
    return;
  end if;

  select array_agg(player_id order by player_id) into v_ids
    from public.match_players where match_id = p_match;

  -- Lock the four rating rows in a deterministic order to avoid deadlocks.
  perform 1 from public.player_ratings
   where player_id = any (v_ids)
   order by player_id
   for update;

  select jsonb_agg(jsonb_build_object(
           'id', mp.player_id,
           'team', mp.team,
           'mu', r.mu,
           'sigma', r.sigma,
           'last_activity', coalesce(r.last_ranked_at, r.created_at)
         ) order by mp.team, mp.court_side)
    into v_players
    from public.match_players mp
    join public.player_ratings r on r.player_id = mp.player_id
   where mp.match_id = p_match;

  select count(*) into v_same
    from public.matches o
   where o.id <> p_match
     and o.status = 'confirmed'
     and o.match_type = 'ranked'
     and o.confirmed_at > v_now - interval '30 days'
     and (select array_agg(player_id order by player_id) from public.match_players where match_id = o.id) = v_ids;

  v_weight := 1.0 / (1 + 0.5 * v_same);

  v_result := private.compute_rating_update(
    v_players, m.format, m.winner_team, m.team1_games, m.team2_games, v_weight, v_now
  );

  for p in select value from jsonb_array_elements(v_result -> 'players') loop
    select jsonb_build_object('id', q ->> 'id', 'mu', (q ->> 'mu_before')::double precision)
      into v_partner
      from jsonb_array_elements(v_result -> 'players') q
     where q ->> 'team' = p ->> 'team' and q ->> 'id' <> p ->> 'id';
    select jsonb_agg(jsonb_build_object('id', q ->> 'id', 'mu', (q ->> 'mu_before')::double precision))
      into v_opponents
      from jsonb_array_elements(v_result -> 'players') q
     where q ->> 'team' <> p ->> 'team';

    insert into public.rating_events (player_id, match_id, kind, mu_before, sigma_before, mu_after, sigma_after, details)
    values (
      (p ->> 'id')::uuid,
      p_match,
      'match',
      (p ->> 'mu_before')::double precision,
      (p ->> 'sigma_before')::double precision,
      (p ->> 'mu_after')::double precision,
      (p ->> 'sigma_after')::double precision,
      jsonb_build_object(
        'algorithm', v_result ->> 'algorithm',
        'team', (p ->> 'team')::integer,
        'won', (p ->> 'team')::integer = m.winner_team,
        'team_strength', case when p ->> 'team' = '1' then v_result -> 'team1_strength' else v_result -> 'team2_strength' end,
        'opponent_strength', case when p ->> 'team' = '1' then v_result -> 'team2_strength' else v_result -> 'team1_strength' end,
        'expected_win', case when p ->> 'team' = '1'
          then (v_result ->> 'expected_win_team1')::double precision
          else 1 - (v_result ->> 'expected_win_team1')::double precision end,
        'expected_game_share', case when p ->> 'team' = '1'
          then (v_result ->> 'expected_game_share_team1')::double precision
          else 1 - (v_result ->> 'expected_game_share_team1')::double precision end,
        'game_share', case when p ->> 'team' = '1'
          then (v_result ->> 'game_share_team1')::double precision
          else 1 - (v_result ->> 'game_share_team1')::double precision end,
        'margin_factor', v_result -> 'margin_factor',
        'weight', v_weight,
        'repeat_lineup', v_same,
        'gain', p -> 'gain',
        'coef', p -> 'coef',
        'sigma_effective', p -> 'sigma_effective',
        'idle_days', p -> 'idle_days',
        'partner', v_partner,
        'opponents', v_opponents
      )
    );

    update public.player_ratings r
       set mu = (p ->> 'mu_after')::double precision,
           sigma = (p ->> 'sigma_after')::double precision,
           peak_mu = greatest(r.peak_mu, (p ->> 'mu_after')::double precision),
           ranked_matches = r.ranked_matches + 1,
           ranked_wins = r.ranked_wins + case when (p ->> 'team')::integer = m.winner_team then 1 else 0 end,
           last_ranked_at = v_now
     where r.player_id = (p ->> 'id')::uuid;
  end loop;

  update public.matches
     set rating_applied = true,
         rating_weight = v_weight
   where id = p_match;
end;
$$;
