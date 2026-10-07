-- Padel ID public API (part 3): statistics, insights, compatibility, search,
-- profiles and rating history. All analytics are computed from real data at
-- request time; the API returns structured facts that the client renders.

-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------

create or replace function private.player_stats(p_player uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v jsonb;
  v_form text[];
  v_streak_type text;
  v_streak integer := 0;
  r record;
begin
  with pm as (
    select m.*, mp.team, mp.court_side, (mp.team = m.winner_team) as won
      from public.match_players mp
      join public.matches m on m.id = mp.match_id
     where mp.player_id = p_player and m.status = 'confirmed'
  ), sets as (
    select pm.id, pm.team, s.ordinality as n, (s.value ->> 't1')::integer as t1, (s.value ->> 't2')::integer as t2,
           coalesce((s.value ->> 'super_tiebreak')::boolean, false) as stb
      from pm cross join lateral jsonb_array_elements(pm.score) with ordinality s
  )
  select jsonb_build_object(
    'matches', (select count(*) from pm),
    'wins', (select count(*) from pm where won),
    'losses', (select count(*) from pm where not won),
    'ranked', jsonb_build_object('matches', (select count(*) from pm where match_type = 'ranked'),
                                 'wins', (select count(*) from pm where match_type = 'ranked' and won)),
    'friendly', jsonb_build_object('matches', (select count(*) from pm where match_type = 'friendly'),
                                   'wins', (select count(*) from pm where match_type = 'friendly' and won)),
    'sets', jsonb_build_object(
      'won', (select count(*) from sets where (team = 1 and t1 > t2) or (team = 2 and t2 > t1)),
      'lost', (select count(*) from sets where (team = 1 and t1 < t2) or (team = 2 and t2 < t1))),
    'games', jsonb_build_object(
      'won', (select coalesce(sum(case when team = 1 then team1_games else team2_games end), 0) from pm),
      'lost', (select coalesce(sum(case when team = 1 then team2_games else team1_games end), 0) from pm)),
    'tiebreaks', jsonb_build_object(
      'won', (select count(*) from sets where not stb and greatest(t1, t2) = 7 and least(t1, t2) = 6
                and ((team = 1 and t1 > t2) or (team = 2 and t2 > t1))),
      'lost', (select count(*) from sets where not stb and greatest(t1, t2) = 7 and least(t1, t2) = 6
                and ((team = 1 and t1 < t2) or (team = 2 and t2 < t1)))),
    'deciding_sets', jsonb_build_object(
      'won', (select count(*) from sets where n = 3 and ((team = 1 and t1 > t2) or (team = 2 and t2 > t1))),
      'lost', (select count(*) from sets where n = 3 and ((team = 1 and t1 < t2) or (team = 2 and t2 < t1)))),
    'sides', jsonb_build_object(
      'left', jsonb_build_object('matches', (select count(*) from pm where court_side = 'left'),
                                 'wins', (select count(*) from pm where court_side = 'left' and won)),
      'right', jsonb_build_object('matches', (select count(*) from pm where court_side = 'right'),
                                  'wins', (select count(*) from pm where court_side = 'right' and won))),
    'last_played_at', (select max(played_at) from pm)
  ) into v;

  v_form := array[]::text[];
  for r in
    select (mp.team = m.winner_team) as won
      from public.match_players mp
      join public.matches m on m.id = mp.match_id
     where mp.player_id = p_player and m.status = 'confirmed'
     order by m.played_at desc, m.id
     limit 10
  loop
    v_form := v_form || case when r.won then 'W' else 'L' end;
  end loop;
  if cardinality(v_form) > 0 then
    v_streak_type := v_form[1];
    for i in 1..cardinality(v_form) loop
      exit when v_form[i] <> v_streak_type;
      v_streak := v_streak + 1;
    end loop;
  end if;

  return v || jsonb_build_object(
    'form', to_jsonb(v_form),
    'streak', case when v_streak_type is null then null
                   else jsonb_build_object('type', case when v_streak_type = 'W' then 'win' else 'loss' end, 'count', v_streak) end,
    'partners', coalesce((
      select jsonb_agg(jsonb_build_object('player', private.player_card(x.partner), 'matches', x.n, 'wins', x.w) order by x.n desc, x.w desc)
        from (
          select o.player_id as partner, count(*) as n, count(*) filter (where mp.team = m.winner_team) as w
            from public.match_players mp
            join public.matches m on m.id = mp.match_id and m.status = 'confirmed'
            join public.match_players o on o.match_id = mp.match_id and o.team = mp.team and o.player_id <> mp.player_id
           where mp.player_id = p_player
           group by o.player_id
           order by count(*) desc, count(*) filter (where mp.team = m.winner_team) desc
           limit 3
        ) x
    ), '[]'::jsonb),
    'rivals', coalesce((
      select jsonb_agg(jsonb_build_object('player', private.player_card(x.rival), 'matches', x.n, 'wins', x.w) order by x.n desc, x.w)
        from (
          select o.player_id as rival, count(*) as n, count(*) filter (where mp.team = m.winner_team) as w
            from public.match_players mp
            join public.matches m on m.id = mp.match_id and m.status = 'confirmed'
            join public.match_players o on o.match_id = mp.match_id and o.team <> mp.team
           where mp.player_id = p_player
           group by o.player_id
           order by count(*) desc, count(*) filter (where mp.team = m.winner_team)
           limit 3
        ) x
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Rating history
-- ---------------------------------------------------------------------------

create or replace function public.rating_history(p_player uuid, p_days integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_from timestamptz := case when p_days is null then '-infinity'::timestamptz else now() - make_interval(days => greatest(p_days, 1)) end;
begin
  if not exists (select 1 from public.player_ratings where player_id = p_player) then
    perform private.fail('player_not_found');
  end if;
  return jsonb_build_object(
    'points', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', e.created_at,
               'mu', round(e.mu_after::numeric, 3),
               'sigma', round(e.sigma_after::numeric, 3),
               'delta', case when e.mu_before is null then null else round((e.mu_after - e.mu_before)::numeric, 3) end,
               'kind', e.kind,
               'match_id', e.match_id,
               'won', (e.details ->> 'won')::boolean,
               'expected_win', round((e.details ->> 'expected_win')::numeric, 3)
             ) order by e.created_at, e.id)
        from (
          select * from public.rating_events where player_id = p_player and created_at >= v_from
          union all
          select * from (
            select * from public.rating_events
             where player_id = p_player and created_at < v_from
             order by created_at desc, id desc limit 1
          ) prev
        ) e
    ), '[]'::jsonb),
    'peak_mu', (select round(peak_mu::numeric, 2) from public.player_ratings where player_id = p_player)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Compatibility between two players as potential partners
-- ---------------------------------------------------------------------------

create or replace function private.compatibility(p_a uuid, p_b uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  a public.profiles%rowtype;
  b public.profiles%rowtype;
  ra public.player_ratings%rowtype;
  rb public.player_ratings%rowtype;
  v_level double precision;
  v_sides double precision;
  v_style double precision;
  v_style_conf double precision;
  v_chem double precision;
  v_chem_n integer;
  v_chem_resid double precision;
  v_logistics double precision;
  v_sa double precision;
  v_sb double precision;
  v_gap double precision;
  w_level double precision := 0.35;
  w_sides double precision := 0.2;
  w_style double precision := 0.2;
  w_chem double precision := 0.15;
  w_log double precision := 0.1;
  v_score double precision;
  v_reasons jsonb := '[]'::jsonb;
  v_cover jsonb;
begin
  select * into a from public.profiles where id = p_a;
  select * into b from public.profiles where id = p_b;
  select * into ra from public.player_ratings where player_id = p_a;
  select * into rb from public.player_ratings where player_id = p_b;
  if a.id is null or b.id is null or ra.player_id is null or rb.player_id is null or p_a = p_b then
    return null;
  end if;

  -- Level fit: partners of similar level form balanced, rating-relevant teams.
  v_sa := private.effective_sigma(ra.sigma, coalesce(ra.last_ranked_at, ra.created_at), now());
  v_sb := private.effective_sigma(rb.sigma, coalesce(rb.last_ranked_at, rb.created_at), now());
  v_gap := abs(ra.mu - rb.mu);
  v_level := exp(-(v_gap ^ 2) / (2 * (0.5 ^ 2 + 0.25 * (v_sa ^ 2 + v_sb ^ 2))));
  v_reasons := v_reasons || jsonb_build_object('code', 'level_gap', 'value', round(v_gap::numeric, 2));

  -- Court sides: complementary preferences make the pairing work naturally.
  v_sides := case
    when a.preferred_side <> 'both' and b.preferred_side <> 'both' and a.preferred_side <> b.preferred_side then 1.0
    when a.preferred_side = 'both' and b.preferred_side = 'both' then 0.8
    when a.preferred_side = 'both' or b.preferred_side = 'both' then 0.85
    else 0.35
  end;
  v_reasons := v_reasons || jsonb_build_object('code', 'sides', 'a', a.preferred_side, 'b', b.preferred_side);

  -- Style: how well the pair covers each other's weaker dimensions.
  select avg(greatest(da.offset_mean, db.offset_mean) - least(da.offset_mean, db.offset_mean)),
         avg(least(1 - sqrt(da.offset_var) / 0.45, 1 - sqrt(db.offset_var) / 0.45))
    into v_style, v_style_conf
    from public.player_dna da
    join public.player_dna db on db.dimension = da.dimension and db.player_id = p_b
   where da.player_id = p_a;
  if v_style is not null then
    v_style := least(1, 0.5 + v_style * 1.5);
    v_style_conf := greatest(0, v_style_conf);
    w_style := w_style * greatest(0.25, v_style_conf);
    select jsonb_agg(x.dimension) into v_cover from (
      select da.dimension
        from public.player_dna da
        join public.player_dna db on db.dimension = da.dimension and db.player_id = p_b
       where da.player_id = p_a and da.offset_mean < -0.05 and db.offset_mean > 0.05
       order by db.offset_mean - da.offset_mean desc
       limit 2
    ) x;
    if v_cover is not null then
      v_reasons := v_reasons || jsonb_build_object('code', 'covers_weakness', 'dimensions', v_cover);
    end if;
  else
    v_style := 0.5;
    w_style := 0;
  end if;

  -- Chemistry: actual results together versus model expectation.
  select count(*), avg((case when (ea.details ->> 'won')::boolean then 1 else 0 end) - (ea.details ->> 'expected_win')::double precision)
    into v_chem_n, v_chem_resid
    from public.rating_events ea
    join public.rating_events eb on eb.match_id = ea.match_id and eb.player_id = p_b
   where ea.player_id = p_a and ea.kind = 'match'
     and (ea.details ->> 'team') = (eb.details ->> 'team');
  if v_chem_n >= 2 then
    v_chem := 1 / (1 + exp(-4 * v_chem_resid));
    w_chem := w_chem * least(1, v_chem_n / 5.0);
    v_reasons := v_reasons || jsonb_build_object('code', 'chemistry', 'matches', v_chem_n, 'residual', round(v_chem_resid::numeric, 2));
  else
    select count(*) into v_chem_n
      from public.match_players x
      join public.match_players y on y.match_id = x.match_id and y.player_id = p_b and y.team = x.team
      join public.matches m on m.id = x.match_id and m.status = 'confirmed'
     where x.player_id = p_a;
    if v_chem_n > 0 then
      v_reasons := v_reasons || jsonb_build_object('code', 'played_together', 'matches', v_chem_n);
    end if;
    v_chem := 0.5;
    w_chem := 0;
  end if;

  -- Logistics: same club or city makes regular games realistic.
  v_logistics := case
    when a.club_id is not null and a.club_id = b.club_id then 1.0
    when a.city_id is not null and a.city_id = b.city_id then 0.7
    else 0.2
  end;
  if a.club_id is not null and a.club_id = b.club_id then
    v_reasons := v_reasons || jsonb_build_object('code', 'same_club');
  elsif a.city_id is not null and a.city_id = b.city_id then
    v_reasons := v_reasons || jsonb_build_object('code', 'same_city');
  end if;

  v_score := (w_level * v_level + w_sides * v_sides + w_style * v_style + w_chem * v_chem + w_log * v_logistics)
           / (w_level + w_sides + w_style + w_chem + w_log);

  return jsonb_build_object(
    'score', round(100 * v_score)::integer,
    'components', jsonb_build_array(
      jsonb_build_object('key', 'level', 'value', round(v_level::numeric, 2), 'weight', round(w_level::numeric, 3)),
      jsonb_build_object('key', 'sides', 'value', round(v_sides::numeric, 2), 'weight', round(w_sides::numeric, 3)),
      jsonb_build_object('key', 'style', 'value', round(v_style::numeric, 2), 'weight', round(w_style::numeric, 3)),
      jsonb_build_object('key', 'chemistry', 'value', round(v_chem::numeric, 2), 'weight', round(w_chem::numeric, 3)),
      jsonb_build_object('key', 'logistics', 'value', round(v_logistics::numeric, 2), 'weight', round(w_log::numeric, 3))
    ),
    'reasons', v_reasons
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Insights: data-driven analysis of the player's progress
-- ---------------------------------------------------------------------------

create or replace function private.insights(p_player uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  r public.player_ratings%rowtype;
  v_out jsonb := '[]'::jsonb;
  v_sigma double precision;
  v_rel integer;
  v_trend double precision;
  v_trend_n integer;
  v_resid double precision;
  v_resid_n integer;
  v_left_n integer; v_left_w integer; v_right_n integer; v_right_w integer;
  v_close_n integer; v_close_w integer;
  v_partner record;
  v_weak record;
  v_needed integer := 0;
  v_s double precision;
  v_idle integer;
begin
  select * into r from public.player_ratings where player_id = p_player;
  if not found then
    return v_out;
  end if;
  v_sigma := private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now());
  v_rel := private.reliability(v_sigma);
  v_idle := floor(extract(epoch from (now() - coalesce(r.last_ranked_at, r.created_at))) / 86400.0);

  -- Reliability: how many typical ranked matches until the rating is reliable.
  if v_rel < 70 then
    v_s := v_sigma;
    while private.reliability(v_s) < 70 and v_needed < 30 loop
      -- One balanced match against established players (sigma 0.35).
      v_s := sqrt(greatest(0.04, v_s ^ 2 * (1 - (v_s ^ 2 * 0.065) / (v_s ^ 2 * 0.065 + 3 * 0.35 ^ 2 * 0.065 + 0.25))) + 0.002);
      v_needed := v_needed + 1;
    end loop;
    v_out := v_out || jsonb_build_object('kind', 'reliability_path', 'sentiment', 'neutral',
      'values', jsonb_build_object('reliability', v_rel, 'matches_needed', v_needed, 'target', 70));
  end if;

  -- Inactivity increases uncertainty.
  if v_idle >= 21 and r.ranked_matches > 0 then
    v_out := v_out || jsonb_build_object('kind', 'inactivity', 'sentiment', 'attention',
      'values', jsonb_build_object('days', v_idle, 'reliability', v_rel));
  end if;

  -- Rating trend over 30 days.
  select count(*), sum(mu_after - mu_before) into v_trend_n, v_trend
    from public.rating_events
   where player_id = p_player and kind = 'match' and created_at > now() - interval '30 days';
  if v_trend_n >= 2 then
    v_out := v_out || jsonb_build_object('kind', 'trend', 'sentiment',
      case when v_trend > 0.02 then 'positive' when v_trend < -0.02 then 'attention' else 'neutral' end,
      'values', jsonb_build_object('delta', round(v_trend::numeric, 2), 'matches', v_trend_n, 'days', 30));
  end if;

  -- Performance versus expectation (last 10 ranked matches).
  select count(*), avg((case when (details ->> 'won')::boolean then 1 else 0 end) - (details ->> 'expected_win')::double precision)
    into v_resid_n, v_resid
    from (select details from public.rating_events where player_id = p_player and kind = 'match'
           order by created_at desc limit 10) x;
  if v_resid_n >= 4 and abs(v_resid) >= 0.08 then
    v_out := v_out || jsonb_build_object('kind', 'vs_expectation',
      'sentiment', case when v_resid > 0 then 'positive' else 'attention' end,
      'values', jsonb_build_object('residual', round(v_resid::numeric, 2), 'matches', v_resid_n));
  end if;

  -- Court side performance.
  select count(*) filter (where mp.court_side = 'left'),
         count(*) filter (where mp.court_side = 'left' and mp.team = m.winner_team),
         count(*) filter (where mp.court_side = 'right'),
         count(*) filter (where mp.court_side = 'right' and mp.team = m.winner_team)
    into v_left_n, v_left_w, v_right_n, v_right_w
    from public.match_players mp
    join public.matches m on m.id = mp.match_id and m.status = 'confirmed'
   where mp.player_id = p_player;
  if v_left_n >= 4 and v_right_n >= 4
     and abs(v_left_w::double precision / v_left_n - v_right_w::double precision / v_right_n) >= 0.15 then
    v_out := v_out || jsonb_build_object('kind', 'side_split', 'sentiment', 'neutral',
      'values', jsonb_build_object(
        'better_side', case when v_left_w::double precision / v_left_n > v_right_w::double precision / v_right_n then 'left' else 'right' end,
        'left_win_rate', round(v_left_w::numeric / v_left_n, 2), 'left_matches', v_left_n,
        'right_win_rate', round(v_right_w::numeric / v_right_n, 2), 'right_matches', v_right_n));
  end if;

  -- Close sets (7–5, 7–6, super tie-breaks).
  select count(*),
         count(*) filter (where (mp.team = 1 and (s.value ->> 't1')::integer > (s.value ->> 't2')::integer)
                             or (mp.team = 2 and (s.value ->> 't2')::integer > (s.value ->> 't1')::integer))
    into v_close_n, v_close_w
    from public.match_players mp
    join public.matches m on m.id = mp.match_id and m.status = 'confirmed'
    cross join lateral jsonb_array_elements(m.score) s
   where mp.player_id = p_player
     and ((s.value ->> 'super_tiebreak')::boolean or greatest((s.value ->> 't1')::integer, (s.value ->> 't2')::integer) = 7);
  if v_close_n >= 4 and abs(v_close_w::double precision / v_close_n - 0.5) >= 0.15 then
    v_out := v_out || jsonb_build_object('kind', 'close_sets',
      'sentiment', case when v_close_w::double precision / v_close_n > 0.5 then 'positive' else 'attention' end,
      'values', jsonb_build_object('won', v_close_w, 'total', v_close_n));
  end if;

  -- Best partnership by results versus expectation.
  select x.partner, x.n, x.resid into v_partner
    from (
      select eb.player_id as partner, count(*) as n,
             avg((case when (ea.details ->> 'won')::boolean then 1 else 0 end) - (ea.details ->> 'expected_win')::double precision) as resid
        from public.rating_events ea
        join public.rating_events eb on eb.match_id = ea.match_id and eb.player_id <> ea.player_id
                                     and (eb.details ->> 'team') = (ea.details ->> 'team')
       where ea.player_id = p_player and ea.kind = 'match'
       group by eb.player_id
      having count(*) >= 3
    ) x
   order by x.resid desc
   limit 1;
  if v_partner.partner is not null and v_partner.resid > 0.05 then
    v_out := v_out || jsonb_build_object('kind', 'best_partner', 'sentiment', 'positive',
      'values', jsonb_build_object('player', private.player_card(v_partner.partner), 'matches', v_partner.n,
                                   'residual', round(v_partner.resid::numeric, 2)));
  end if;

  -- Training focus: weakest DNA dimension with enough evidence.
  select dimension, offset_mean, 1 - sqrt(offset_var) / 0.45 as confidence into v_weak
    from public.player_dna
   where player_id = p_player
   order by offset_mean asc
   limit 1;
  if v_weak.dimension is not null and v_weak.offset_mean < -0.08 and v_weak.confidence >= 0.25 then
    v_out := v_out || jsonb_build_object('kind', 'focus_area', 'sentiment', 'neutral',
      'values', jsonb_build_object('dimension', v_weak.dimension, 'offset', round(v_weak.offset_mean::numeric, 2),
                                   'confidence', round(v_weak.confidence::numeric, 2)));
  end if;

  return v_out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public read API
-- ---------------------------------------------------------------------------

create or replace function public.player_profile(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_is_coach boolean;
  v_deleted boolean;
begin
  select deleted_at is not null into v_deleted from public.profiles where id = p_player;
  if v_deleted is null or not exists (select 1 from public.player_ratings where player_id = p_player) then
    perform private.fail('player_not_found');
  end if;
  v_is_coach := exists (select 1 from public.coach_applications where player_id = v_uid and status = 'approved');

  if v_deleted then
    return jsonb_build_object('profile', private.player_card(p_player), 'deleted', true);
  end if;

  return jsonb_build_object(
    'deleted', false,
    'profile', private.profile_json(p_player),
    'rating', private.rating_json(p_player),
    'dna', private.dna_json(p_player),
    'stats', private.player_stats(p_player),
    'recent_matches', coalesce((
      select jsonb_agg(private.match_list_item(x.id, v_uid) || jsonb_build_object(
               'subject_team', x.team,
               'subject_rating_delta', (select round((e.mu_after - e.mu_before)::numeric, 3) from public.rating_events e
                                        where e.match_id = x.id and e.player_id = p_player)
             ) order by x.played_at desc)
        from (
          select m.id, m.played_at, mp.team from public.matches m
            join public.match_players mp on mp.match_id = m.id and mp.player_id = p_player
           where m.status = 'confirmed'
           order by m.played_at desc limit 5
        ) x
    ), '[]'::jsonb),
    'compatibility', case when p_player = v_uid then null else private.compatibility(v_uid, p_player) end,
    'coach_assessments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', ca.id,
               'coach', private.player_card(ca.coach_id),
               'scores', ca.scores,
               'created_at', ca.created_at,
               'note', case when v_uid in (ca.player_id, ca.coach_id) then ca.note end
             ) order by ca.created_at desc)
        from (
          select distinct on (a.coach_id) a.*
            from public.coach_assessments a
            join public.coach_applications app on app.player_id = a.coach_id and app.status = 'approved'
           where a.player_id = p_player
           order by a.coach_id, a.created_at desc
        ) ca
    ), '[]'::jsonb),
    'viewer', jsonb_build_object(
      'is_me', p_player = v_uid,
      'can_assess', v_is_coach and p_player <> v_uid
    )
  );
end;
$$;

create or replace function public.home()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform private.require_active_player(v_uid);
  update public.matches m
     set status = 'expired', closed_at = now()
   where m.status in ('pending', 'disputed')
     and m.updated_at < now() - interval '7 days'
     and exists (select 1 from public.match_players mp where mp.match_id = m.id and mp.player_id = v_uid);

  return public.player_profile(v_uid) || jsonb_build_object(
    'insights', private.insights(v_uid),
    'action_items', coalesce((
      select jsonb_agg(private.match_list_item(m.id, v_uid) order by m.updated_at desc)
        from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
       where (m.status in ('pending', 'disputed') and mp.response = 'pending')
          or (m.status = 'disputed' and m.created_by = v_uid)
    ), '[]'::jsonb),
    'open_matches_count', (
      select count(*) from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
       where m.status in ('pending', 'disputed')
    )
  );
end;
$$;

create or replace function public.recent_players(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  return coalesce((
    select jsonb_agg(private.player_card(x.player_id) || jsonb_build_object('matches_together', x.n) order by x.last desc)
      from (
        select o.player_id, count(*) as n, max(m.played_at) as last
          from public.match_players mp
          join public.matches m on m.id = mp.match_id and m.status in ('pending', 'disputed', 'confirmed')
          join public.match_players o on o.match_id = mp.match_id and o.player_id <> mp.player_id
          join public.profiles p on p.id = o.player_id and p.deleted_at is null
         where mp.player_id = v_uid
         group by o.player_id
         order by max(m.played_at) desc
         limit greatest(1, least(coalesce(p_limit, 20), 50))
      ) x
  ), '[]'::jsonb);
end;
$$;

create or replace function public.search_players(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_q text := private.norm(ltrim(coalesce(p ->> 'query', ''), '@'));
  v_city integer := case when private.jtype(p -> 'city_id') = 'number' then (p ->> 'city_id')::integer end;
  v_club bigint := case when private.jtype(p -> 'club_id') = 'number' then (p ->> 'club_id')::bigint end;
  v_min double precision := coalesce((p ->> 'min_level')::double precision, 0);
  v_max double precision := coalesce((p ->> 'max_level')::double precision, 7);
  v_side text := p ->> 'side';
  v_reliable boolean := coalesce((p ->> 'reliable_only')::boolean, false);
  v_coaches boolean := coalesce((p ->> 'coaches_only')::boolean, false);
  v_sort text := coalesce(p ->> 'sort', 'compatibility');
  v_limit integer := greatest(1, least(coalesce((p ->> 'limit')::integer, 20), 50));
  v_offset integer := greatest(0, least(coalesce((p ->> 'offset')::integer, 0), 1000));
  v_my_mu double precision;
  v_items jsonb;
  v_total integer;
begin
  if v_side is not null and v_side not in ('left', 'right', 'both') then
    perform private.fail('invalid_request');
  end if;
  if v_sort not in ('compatibility', 'level_desc', 'level_asc', 'recent', 'name') then
    perform private.fail('invalid_request');
  end if;
  select mu into v_my_mu from public.player_ratings where player_id = v_uid;

  with candidates as (
    select pr.id, pr.display_name, r.mu, r.last_ranked_at,
           private.reliability(private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now())) as rel,
           case when v_q = '' then 0 else extensions.similarity(pr.name_norm || ' ' || pr.username, v_q) end as sim
      from public.profiles pr
      join public.player_ratings r on r.player_id = pr.id
     where pr.deleted_at is null
       and pr.id <> v_uid
       and (pr.discoverable or exists (
             select 1 from public.match_players a
               join public.match_players b on b.match_id = a.match_id and b.player_id = pr.id
              where a.player_id = v_uid))
       and (v_q = '' or (pr.name_norm || ' ' || pr.username) like '%' || v_q || '%'
            or extensions.similarity(pr.name_norm || ' ' || pr.username, v_q) > 0.3)
       and (v_city is null or pr.city_id = v_city)
       and (v_club is null or pr.club_id = v_club)
       and r.mu between v_min and v_max
       and (v_side is null or pr.preferred_side = v_side or (v_side <> 'both' and pr.preferred_side = 'both'))
       and (not v_coaches or pr.is_coach)
  ), filtered as (
    select c.*,
           case when v_sort = 'compatibility' and v_my_mu is not null
                then (private.compatibility(v_uid, c.id) ->> 'score')::integer end as compat
      from candidates c
     where not v_reliable or c.rel >= 50
  ), ordered as (
    select f.*, count(*) over () as total,
           row_number() over (order by
             case when v_q <> '' and v_sort = 'compatibility' then -f.sim end,
             case when v_sort = 'compatibility' then -coalesce(f.compat, 0) end,
             case when v_sort = 'level_desc' then -f.mu end,
             case when v_sort = 'level_asc' then f.mu end,
             case when v_sort = 'recent' then extract(epoch from f.last_ranked_at) end desc nulls last,
             f.display_name, f.id) as rn
      from filtered f
  )
  select coalesce(jsonb_agg(private.player_card(o.id) || jsonb_build_object('compatibility', o.compat) order by o.rn), '[]'::jsonb),
         coalesce(max(o.total), 0)
    into v_items, v_total
    from ordered o
   where o.rn > v_offset and o.rn <= v_offset + v_limit;

  return jsonb_build_object(
    'items', v_items,
    'total', v_total,
    'next_offset', case when v_offset + v_limit < v_total then v_offset + v_limit end
  );
end;
$$;

create or replace function public.compatibility(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform private.require_active_player(p_player);
  perform private.require_active_player(v_uid);
  return private.compatibility(v_uid, p_player);
end;
$$;

create or replace function public.player_dna(p_player uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform private.require_active_player(p_player);
  return private.dna_json(p_player) || jsonb_build_object(
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('dimension', h.dimension, 'day', h.day, 'level', round(h.level::numeric, 2)) order by h.day, h.dimension)
        from public.player_dna_history h
       where h.player_id = p_player and h.day > current_date - 180
    ), '[]'::jsonb),
    'rating', private.rating_json(p_player)
  );
end;
$$;
