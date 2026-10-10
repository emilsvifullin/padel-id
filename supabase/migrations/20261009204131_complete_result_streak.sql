-- Preserve statistics and ten-match form, but compute the current streak
-- from the complete confirmed history. No rating mathematics changes.

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

  select coalesce(array_agg(x.result order by x.played_at desc, x.id), array[]::text[]) into v_form
    from (select m.played_at, m.id, case when mp.team = m.winner_team then 'W' else 'L' end as result
      from public.match_players mp join public.matches m on m.id = mp.match_id
     where mp.player_id = p_player and m.status = 'confirmed'
     order by m.played_at desc, m.id limit 10) x;
  -- The latest result fixes the streak type; stop only at the first opposite
  -- confirmed result. Pending/disputed/cancelled results never enter this loop.
  for r in
    select case when mp.team = m.winner_team then 'W' else 'L' end as result
      from public.match_players mp join public.matches m on m.id = mp.match_id
     where mp.player_id = p_player and m.status = 'confirmed'
     order by m.played_at desc, m.id
  loop
    if v_streak_type is null then v_streak_type := r.result; end if;
    exit when r.result <> v_streak_type;
    v_streak := v_streak + 1;
  end loop;

  return v || jsonb_build_object(
    'form', to_jsonb(v_form),
    'last_ten', jsonb_build_object('matches', cardinality(v_form),
      'wins', (select count(*) from unnest(v_form) x where x = 'W'),
      'losses', (select count(*) from unnest(v_form) x where x = 'L')),
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


revoke all on function private.player_stats(uuid) from public, anon, authenticated, service_role;
