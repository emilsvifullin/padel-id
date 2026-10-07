-- Padel DNA: a player's style profile across six dimensions.
--
-- Each dimension d has a latent offset θ_d (in rating units) relative to the
-- player's overall level. θ_d has a Gaussian prior N(0, 0.45²) and is updated by
-- precision-weighted Gaussian observations:
--
--   source                       observation y                 noise variance v
--   ---------------------------  ----------------------------  -----------------------------
--   self assessment (−2..2)      0.3 · answer                  0.6²
--   partner/opponent "strength"  +0.5                          0.9² / w_rater
--   partner/opponent "to improve" −0.5                         0.9² / w_rater
--   verified coach score (0..7)  score − player level at time  0.3² · (1 + age_days / 180)
--   close sets (consistency)     1.5 · (win rate − expected)   0.5² · 6 / max(n, 6)
--
--   w_rater = 1.2 if the rater's rating is reliable (≥ 50 %), 0.7 if the rater
--   is more than half a level below the player; peer feedback decays with age
--   (half-weight after ~8 months).
--
-- The posterior means are centred so that the profile describes relative style:
-- the average of the six dimension levels equals the player's overall rating.
-- Confidence = 1 − posterior_sd / prior_sd.

create or replace function private.recompute_dna(p_player uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  dims constant text[] := private.dna_dimensions();
  prior_var constant double precision := 0.2025;
  dim text;
  v_mu double precision;
  v_self jsonb;
  r record;
  y double precision;
  v double precision;
  wr double precision;
  age double precision;
  prec double precision[] := array[]::double precision[];
  num double precision[] := array[]::double precision[];
  peers integer[] := array[]::integer[];
  coaches integer[] := array[]::integer[];
  self_flags boolean[] := array[]::boolean[];
  match_flags boolean[] := array[]::boolean[];
  verified timestamptz[] := array[]::timestamptz[];
  means double precision[] := array[]::double precision[];
  center double precision := 0;
  i integer;
  close_n integer := 0;
  close_won integer := 0;
  close_expected double precision := 0;
begin
  select mu into v_mu from public.player_ratings where player_id = p_player;
  if not found then
    return;
  end if;

  select answers into v_self from public.dna_self_assessments where player_id = p_player;

  -- Close sets (7–5, 7–6, super tie-breaks) in the last 40 confirmed matches.
  for r in
    select s.value as set_score, mp.team, coalesce((re.details ->> 'expected_win')::double precision, 0.5) as expected
      from public.match_players mp
      join public.matches m on m.id = mp.match_id and m.status = 'confirmed'
      left join public.rating_events re on re.match_id = m.id and re.player_id = mp.player_id
      cross join lateral jsonb_array_elements(m.score) s
     where mp.player_id = p_player
       and m.id in (
         select m2.id from public.matches m2
           join public.match_players mp2 on mp2.match_id = m2.id and mp2.player_id = p_player
          where m2.status = 'confirmed'
          order by m2.played_at desc
          limit 40
       )
  loop
    if (r.set_score ->> 'super_tiebreak')::boolean
       or greatest((r.set_score ->> 't1')::integer, (r.set_score ->> 't2')::integer) = 7 then
      close_n := close_n + 1;
      close_expected := close_expected + 0.5 + (r.expected - 0.5) * 0.5;
      if (r.team = 1 and (r.set_score ->> 't1')::integer > (r.set_score ->> 't2')::integer)
         or (r.team = 2 and (r.set_score ->> 't2')::integer > (r.set_score ->> 't1')::integer) then
        close_won := close_won + 1;
      end if;
    end if;
  end loop;

  foreach dim in array dims loop
    prec := prec || (1 / prior_var);
    num := num || 0::double precision;
    peers := peers || 0;
    coaches := coaches || 0;
    self_flags := self_flags || false;
    match_flags := match_flags || false;
    verified := verified || null::timestamptz;
    i := cardinality(prec);

    if v_self is not null and v_self ? dim then
      y := 0.3 * (v_self ->> dim)::double precision;
      v := 0.36;
      prec[i] := prec[i] + 1 / v;
      num[i] := num[i] + y / v;
      self_flags[i] := true;
    end if;

    for r in
      select f.strengths, f.improvements, f.created_at, rr.mu as rater_mu, rr.sigma as rater_sigma
        from public.match_feedback f
        join public.matches m on m.id = f.match_id and m.status = 'confirmed'
        join public.player_ratings rr on rr.player_id = f.rater_id
       where f.ratee_id = p_player
         and (dim = any (f.strengths) or dim = any (f.improvements))
    loop
      age := extract(epoch from (now() - r.created_at)) / 86400.0;
      wr := (case when private.reliability(r.rater_sigma) >= 50 then 1.2 else 1.0 end)
          * (case when r.rater_mu < v_mu - 0.5 then 0.7 else 1.0 end)
          * exp(-age / 365.0);
      y := case when dim = any (r.strengths) then 0.5 else -0.5 end;
      v := 0.81 / greatest(wr, 0.05);
      prec[i] := prec[i] + 1 / v;
      num[i] := num[i] + y / v;
      peers[i] := peers[i] + 1;
    end loop;

    for r in
      select distinct on (ca.coach_id) ca.scores, ca.player_mu_at, ca.created_at
        from public.coach_assessments ca
        join public.coach_applications app on app.player_id = ca.coach_id and app.status = 'approved'
       where ca.player_id = p_player
       order by ca.coach_id, ca.created_at desc
    loop
      continue when not (r.scores ? dim);
      age := extract(epoch from (now() - r.created_at)) / 86400.0;
      y := (r.scores ->> dim)::double precision - r.player_mu_at;
      v := 0.09 * (1 + age / 180.0);
      prec[i] := prec[i] + 1 / v;
      num[i] := num[i] + y / v;
      coaches[i] := coaches[i] + 1;
      if age <= 180 and (verified[i] is null or r.created_at > verified[i]) then
        verified[i] := r.created_at;
      end if;
    end loop;

    if dim = 'consistency_decisions' and close_n >= 4 then
      y := greatest(-0.6, least(0.6, 1.5 * (close_won::double precision / close_n - close_expected / close_n)));
      v := 0.25 * 6.0 / greatest(close_n, 6);
      prec[i] := prec[i] + 1 / v;
      num[i] := num[i] + y / v;
      match_flags[i] := true;
    end if;

    means := means || (num[i] / prec[i]);
  end loop;

  for i in 1..cardinality(means) loop
    center := center + means[i];
  end loop;
  center := center / cardinality(means);

  for i in 1..cardinality(dims) loop
    insert into public.player_dna as d (
      player_id, dimension, offset_mean, offset_var, peer_signals, coach_signals,
      self_signal, match_signal, coach_verified_at, updated_at
    ) values (
      p_player, dims[i], means[i] - center, 1 / prec[i], peers[i], coaches[i],
      self_flags[i], match_flags[i], verified[i], now()
    )
    on conflict (player_id, dimension) do update
      set offset_mean = excluded.offset_mean,
          offset_var = excluded.offset_var,
          peer_signals = excluded.peer_signals,
          coach_signals = excluded.coach_signals,
          self_signal = excluded.self_signal,
          match_signal = excluded.match_signal,
          coach_verified_at = excluded.coach_verified_at,
          updated_at = now();

    insert into public.player_dna_history (player_id, dimension, day, offset_mean, offset_var, level)
    values (
      p_player, dims[i], current_date, means[i] - center, 1 / prec[i],
      greatest(0, least(7, v_mu + means[i] - center))
    )
    on conflict (player_id, dimension, day) do update
      set offset_mean = excluded.offset_mean,
          offset_var = excluded.offset_var,
          level = excluded.level;
  end loop;
end;
$$;

-- Style archetype derived from the strongest dimension when the profile is
-- confident enough; 'forming' while evidence is insufficient.
create or replace function private.dna_archetype(p_player uuid)
returns text
language sql
stable
set search_path = ''
as $$
  with d as (
    select dimension, offset_mean, 1 - sqrt(offset_var) / 0.45 as confidence
      from public.player_dna
     where player_id = p_player
  ), top as (
    select dimension from d order by offset_mean desc limit 1
  )
  select case
    when not exists (select 1 from d) then 'forming'
    when (select avg(confidence) from d) < 0.3 then 'forming'
    when (select max(offset_mean) - min(offset_mean) from d) < 0.15 then 'all_rounder'
    else case (select dimension from top)
      when 'net_game' then 'net_dominator'
      when 'overheads' then 'finisher'
      when 'defense' then 'wall'
      when 'transition_lob' then 'architect'
      when 'serve_return' then 'returner'
      else 'strategist'
    end
  end
$$;

create or replace function private.dna_json(p_player uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'archetype', private.dna_archetype(p_player),
    'dimensions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'key', d.dimension,
               'level', round(greatest(0, least(7, r.mu + d.offset_mean))::numeric, 2),
               'offset', round(d.offset_mean::numeric, 2),
               'confidence', round(greatest(0, least(1, 1 - sqrt(d.offset_var) / 0.45))::numeric, 2),
               'peer_signals', d.peer_signals,
               'coach_signals', d.coach_signals,
               'self_signal', d.self_signal,
               'match_signal', d.match_signal,
               'coach_verified_at', d.coach_verified_at,
               'trend_30d', (
                 select round((greatest(0, least(7, r.mu + d.offset_mean)) - h.level)::numeric, 2)
                   from public.player_dna_history h
                  where h.player_id = d.player_id
                    and h.dimension = d.dimension
                    and h.day <= current_date - 30
                  order by h.day desc
                  limit 1
               )
             ) order by array_position(private.dna_dimensions(), d.dimension))
        from public.player_dna d
        join public.player_ratings r on r.player_id = d.player_id
       where d.player_id = p_player
    ), '[]'::jsonb)
  )
$$;
