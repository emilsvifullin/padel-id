-- Padel ID public API (part 2): matches — score validation, lifecycle,
-- confirmations, disputes, feedback and match analysis.
--
-- Lifecycle
--   pending   → created; the creator is auto-confirmed, the other three must respond
--   disputed  → at least one participant disputed; the creator edits or cancels
--   confirmed → all four confirmed; immutable; ranked matches update ratings
--   cancelled → cancelled by the creator
--   expired   → no resolution within 7 days of the last change
--
-- Concurrency: every mutation locks the match row (SELECT … FOR UPDATE) and
-- checks the client's expected `version`. Edits bump the version and reset the
-- other participants' responses, so a confirmation can never apply to a score
-- the participant has not seen. Retries are idempotent (idempotency keys for
-- create/edit, state-based for confirm/dispute/cancel).

-- Validates and normalises a score. Each set: {"t1": int, "t2": int,
-- "super_tiebreak": bool, "tb1": int|null, "tb2": int|null}.
create or replace function private.validate_score(p_format text, p_sets jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  n integer;
  s jsonb;
  i integer := 0;
  a integer;
  b integer;
  tb1 integer;
  tb2 integer;
  is_stb boolean;
  sets1 integer := 0;
  sets2 integer := 0;
  games1 integer := 0;
  games2 integer := 0;
  out_sets jsonb := '[]'::jsonb;
  hi integer;
  lo integer;
begin
  if p_format not in ('best_of_3', 'best_of_3_super_tiebreak', 'single_set') then
    perform private.fail('invalid_format');
  end if;
  if p_sets is null or private.jtype(p_sets) <> 'array' then
    perform private.fail('invalid_score', 'sets must be an array');
  end if;
  n := jsonb_array_length(p_sets);
  if (p_format = 'single_set' and n <> 1) or (p_format <> 'single_set' and n not in (2, 3)) then
    perform private.fail('invalid_score', 'wrong number of sets');
  end if;

  for s in select value from jsonb_array_elements(p_sets) loop
    i := i + 1;
    if private.jtype(s) <> 'object' or private.jtype(s -> 't1') <> 'number' or private.jtype(s -> 't2') <> 'number' then
      perform private.fail('invalid_score', format('set %s is malformed', i));
    end if;
    if sets1 = 2 or sets2 = 2 then
      perform private.fail('invalid_score', 'match already decided');
    end if;
    a := (s ->> 't1')::numeric::integer;
    b := (s ->> 't2')::numeric::integer;
    if (s ->> 't1')::numeric <> a or (s ->> 't2')::numeric <> b or a < 0 or b < 0 then
      perform private.fail('invalid_score', format('set %s has invalid games', i));
    end if;
    is_stb := coalesce((s ->> 'super_tiebreak')::boolean, false);
    hi := greatest(a, b);
    lo := least(a, b);
    tb1 := null;
    tb2 := null;

    if is_stb then
      if p_format <> 'best_of_3_super_tiebreak' or i <> 3 then
        perform private.fail('invalid_score', 'super tie-break is only allowed as the deciding set');
      end if;
      if not ((hi = 10 and lo <= 8) or (hi > 10 and hi - lo = 2)) then
        perform private.fail('invalid_score', 'super tie-break must be won by 2 points with at least 10');
      end if;
    else
      if p_format = 'best_of_3_super_tiebreak' and i = 3 then
        perform private.fail('invalid_score', 'deciding set must be a super tie-break');
      end if;
      if not ((hi = 6 and lo <= 4) or (hi = 7 and lo in (5, 6))) then
        perform private.fail('invalid_score', format('set %s: %s-%s is not a valid set score', i, a, b));
      end if;
      if hi = 7 and lo = 6 then
        if private.jtype(s -> 'tb1') = 'number' and private.jtype(s -> 'tb2') = 'number' then
          tb1 := (s ->> 'tb1')::numeric::integer;
          tb2 := (s ->> 'tb2')::numeric::integer;
          if tb1 < 0 or tb2 < 0
             or (a > b and not ((tb1 = 7 and tb2 <= 5) or (tb1 > 7 and tb1 - tb2 = 2)))
             or (b > a and not ((tb2 = 7 and tb1 <= 5) or (tb2 > 7 and tb2 - tb1 = 2))) then
            perform private.fail('invalid_score', format('set %s: invalid tie-break score', i));
          end if;
        elsif s ? 'tb1' and private.jtype(s -> 'tb1') <> 'null' or s ? 'tb2' and private.jtype(s -> 'tb2') <> 'null' then
          perform private.fail('invalid_score', format('set %s: invalid tie-break score', i));
        end if;
      elsif (s ? 'tb1' and private.jtype(s -> 'tb1') <> 'null') or (s ? 'tb2' and private.jtype(s -> 'tb2') <> 'null') then
        perform private.fail('invalid_score', format('set %s: tie-break only applies to 7-6', i));
      end if;
    end if;

    if a > b then sets1 := sets1 + 1; else sets2 := sets2 + 1; end if;
    if is_stb then
      if a > b then games1 := games1 + 1; else games2 := games2 + 1; end if;
    else
      games1 := games1 + a;
      games2 := games2 + b;
    end if;

    out_sets := out_sets || jsonb_build_object('t1', a, 't2', b, 'super_tiebreak', is_stb, 'tb1', tb1, 'tb2', tb2);
  end loop;

  if p_format <> 'single_set' and greatest(sets1, sets2) <> 2 then
    perform private.fail('invalid_score', 'match is not finished');
  end if;

  return jsonb_build_object(
    'sets', out_sets,
    'winner_team', case when sets1 > sets2 then 1 else 2 end,
    'team1_sets', sets1,
    'team2_sets', sets2,
    'team1_games', games1,
    'team2_games', games2
  );
end;
$$;

-- Validates a match payload from a client and returns the normalised form.
create or replace function private.validate_match_input(p jsonb, p_creator uuid, p_existing uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_type text := p ->> 'match_type';
  v_format text := p ->> 'format';
  v_played timestamptz;
  v_club bigint;
  v_players jsonb := p -> 'players';
  v_score jsonb;
  pl jsonb;
  v_ids uuid[] := array[]::uuid[];
  v_slots text[] := array[]::text[];
  v_id uuid;
  v_count integer;
begin
  if p is null or private.jtype(p) <> 'object' then
    perform private.fail('invalid_request');
  end if;
  if v_type not in ('friendly', 'ranked') or v_type is null then
    perform private.fail('invalid_match_type');
  end if;

  begin
    v_played := (p ->> 'played_at')::timestamptz;
  exception when others then
    perform private.fail('invalid_played_at');
  end;
  if v_played is null then
    perform private.fail('invalid_played_at');
  end if;
  if v_played > now() + interval '1 hour' then
    perform private.fail('played_at_in_future');
  end if;
  if (v_type = 'ranked' and v_played < now() - interval '14 days')
     or (v_type = 'friendly' and v_played < now() - interval '90 days') then
    perform private.fail('played_at_too_old');
  end if;

  if p ? 'club_id' and private.jtype(p -> 'club_id') = 'number' then
    v_club := (p ->> 'club_id')::bigint;
    if not exists (select 1 from public.clubs where id = v_club) then
      perform private.fail('club_not_found');
    end if;
  end if;

  if v_players is null or private.jtype(v_players) <> 'array' or jsonb_array_length(v_players) <> 4 then
    perform private.fail('match_lineup_invalid');
  end if;
  for pl in select value from jsonb_array_elements(v_players) loop
    begin
      v_id := (pl ->> 'player_id')::uuid;
    exception when others then
      perform private.fail('player_not_found');
    end;
    if v_id is null then
      perform private.fail('player_not_found');
    end if;
    if v_id = any (v_ids) then
      perform private.fail('duplicate_player', v_id::text);
    end if;
    if coalesce(pl ->> 'team', '') not in ('1', '2') or coalesce(pl ->> 'court_side', '') not in ('left', 'right') then
      perform private.fail('match_lineup_invalid');
    end if;
    if (pl ->> 'team') || ':' || (pl ->> 'court_side') = any (v_slots) then
      perform private.fail('match_lineup_invalid', 'two players in the same position');
    end if;
    perform private.require_active_player(v_id);
    v_ids := v_ids || v_id;
    v_slots := v_slots || ((pl ->> 'team') || ':' || (pl ->> 'court_side'));
  end loop;
  if not (p_creator = any (v_ids)) then
    perform private.fail('creator_not_participant');
  end if;

  v_score := private.validate_score(v_format, p -> 'sets');

  if v_type = 'ranked' then
    foreach v_id in array v_ids loop
      select count(*) into v_count
        from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = v_id
       where m.match_type = 'ranked'
         and m.status in ('pending', 'disputed', 'confirmed')
         and m.played_at between v_played - interval '18 hours' and v_played + interval '18 hours'
         and m.id is distinct from p_existing;
      if v_count >= 6 then
        perform private.fail('too_many_ranked_matches', v_id::text);
      end if;
    end loop;
  end if;

  -- The same four players cannot start two different matches within 45
  -- minutes: this is the same match entered twice (for example by two
  -- different participants).
  if exists (
    select 1 from public.matches m
     where m.status in ('pending', 'disputed', 'confirmed')
       and m.id is distinct from p_existing
       and m.played_at > v_played - interval '45 minutes'
       and m.played_at < v_played + interval '45 minutes'
       and (select array_agg(mp.player_id order by mp.player_id) from public.match_players mp where mp.match_id = m.id)
           = (select array_agg(x order by x) from unnest(v_ids) x)
  ) then
    perform private.fail('duplicate_match');
  end if;

  return jsonb_build_object(
    'match_type', v_type,
    'format', v_format,
    'played_at', v_played,
    'club_id', v_club,
    'players', v_players,
    'score', v_score
  );
end;
$$;

create or replace function private.insert_lineup(p_match uuid, p_players jsonb, p_creator uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  insert into public.match_players (match_id, player_id, team, court_side, response, responded_at)
  select p_match,
         (x ->> 'player_id')::uuid,
         (x ->> 'team')::smallint,
         x ->> 'court_side',
         case when (x ->> 'player_id')::uuid = p_creator then 'confirmed' else 'pending' end,
         case when (x ->> 'player_id')::uuid = p_creator then now() end
    from jsonb_array_elements(p_players) x;
end;
$$;

-- Builds the {id, team, mu, sigma, last_activity} array for the rating engine
-- from current ratings.
create or replace function private.engine_players(p_players jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_agg(jsonb_build_object(
           'id', r.player_id,
           'team', (x ->> 'team')::integer,
           'mu', r.mu,
           'sigma', r.sigma,
           'last_activity', coalesce(r.last_ranked_at, r.created_at)
         ))
    from jsonb_array_elements(p_players) x
    join public.player_ratings r on r.player_id = (x ->> 'player_id')::uuid
$$;

create or replace function private.repeat_lineup_weight(p_ids uuid[], p_exclude uuid)
returns double precision
language sql
stable
set search_path = ''
as $$
  select 1.0 / (1 + 0.5 * count(*))
    from public.matches o
   where o.id is distinct from p_exclude
     and o.status = 'confirmed'
     and o.match_type = 'ranked'
     and o.confirmed_at > now() - interval '30 days'
     and (select array_agg(player_id order by player_id) from public.match_players where match_id = o.id)
         = (select array_agg(x order by x) from unnest(p_ids) x)
$$;

-- Structured, data-driven analysis of a match.
create or replace function private.match_analysis(p_match uuid, p_viewer uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  m public.matches%rowtype;
  v_players jsonb;
  v_expected double precision;
  v_projection jsonb;
  v_team1 uuid[];
  v_team2 uuid[];
  v_h2h jsonb;
  v_sets jsonb;
  v_first_winner integer;
  v_comeback boolean := false;
  v_tiebreaks integer := 0;
  v_bagels integer := 0;
  v_my_team integer;
  v_viewer_projection jsonb;
  v_weight double precision;
begin
  select * into m from public.matches where id = p_match;
  v_sets := m.score;

  select array_agg(player_id order by player_id) filter (where team = 1),
         array_agg(player_id order by player_id) filter (where team = 2)
    into v_team1, v_team2
    from public.match_players where match_id = p_match;

  if m.rating_applied then
    select (details ->> 'expected_win')::double precision
           * case when (details ->> 'team')::integer = 1 then 1 else -1 end
           + case when (details ->> 'team')::integer = 1 then 0 else 1 end
      into v_expected
      from public.rating_events where match_id = p_match limit 1;
  else
    select jsonb_agg(jsonb_build_object('player_id', player_id, 'team', team)) into v_players
      from public.match_players where match_id = p_match;
    v_weight := private.repeat_lineup_weight(v_team1 || v_team2, p_match);
    v_projection := private.compute_rating_update(
      private.engine_players(v_players), m.format, m.winner_team, m.team1_games, m.team2_games, v_weight, now()
    );
    v_expected := (v_projection ->> 'expected_win_team1')::double precision;
  end if;

  v_first_winner := case when (v_sets -> 0 ->> 't1')::integer > (v_sets -> 0 ->> 't2')::integer then 1 else 2 end;
  v_comeback := jsonb_array_length(v_sets) = 3 and v_first_winner <> m.winner_team;
  select count(*) filter (where (s ->> 'super_tiebreak')::boolean or greatest((s ->> 't1')::integer, (s ->> 't2')::integer) = 7 and least((s ->> 't1')::integer, (s ->> 't2')::integer) = 6),
         count(*) filter (where not (s ->> 'super_tiebreak')::boolean and least((s ->> 't1')::integer, (s ->> 't2')::integer) = 0)
    into v_tiebreaks, v_bagels
    from jsonb_array_elements(v_sets) s;

  select jsonb_build_object(
           'matches', count(*),
           'team1_wins', count(*) filter (where (o.winner_team = 1 and t1 = v_team1) or (o.winner_team = 2 and t2 = v_team1))
         )
    into v_h2h
    from (
      select o.id, o.winner_team,
             (select array_agg(player_id order by player_id) from public.match_players where match_id = o.id and team = 1) t1,
             (select array_agg(player_id order by player_id) from public.match_players where match_id = o.id and team = 2) t2
        from public.matches o
       where o.status = 'confirmed' and o.id <> p_match and o.played_at < m.played_at
         and exists (select 1 from public.match_players x where x.match_id = o.id and x.player_id = v_team1[1])
    ) o
   where (t1 = v_team1 and t2 = v_team2) or (t1 = v_team2 and t2 = v_team1);

  select team into v_my_team from public.match_players where match_id = p_match and player_id = p_viewer;
  if v_my_team is not null and m.match_type = 'ranked' and not m.rating_applied and m.status in ('pending', 'disputed') then
    select jsonb_build_object('delta', round((x ->> 'delta')::numeric, 3), 'mu_after', round((x ->> 'mu_after')::numeric, 2))
      into v_viewer_projection
      from jsonb_array_elements(v_projection -> 'players') x
     where (x ->> 'id')::uuid = p_viewer;
  end if;

  return jsonb_build_object(
    'expected_win_team1', round(v_expected::numeric, 3),
    'upset', (m.winner_team = 1 and v_expected < 0.4) or (m.winner_team = 2 and v_expected > 0.6),
    'comeback', v_comeback,
    'tiebreaks', v_tiebreaks,
    'bagels', v_bagels,
    'game_share_team1', round((m.team1_games::numeric / greatest(m.team1_games + m.team2_games, 1)), 3),
    'head_to_head', v_h2h,
    'partnerships', jsonb_build_object(
      'team1', (select count(*) from public.matches o where o.status = 'confirmed' and o.id <> p_match and o.played_at < m.played_at
                  and (select count(*) from public.match_players x where x.match_id = o.id and x.player_id = any (v_team1)
                         and x.team = (select team from public.match_players y where y.match_id = o.id and y.player_id = v_team1[1])) = 2),
      'team2', (select count(*) from public.matches o where o.status = 'confirmed' and o.id <> p_match and o.played_at < m.played_at
                  and (select count(*) from public.match_players x where x.match_id = o.id and x.player_id = any (v_team2)
                         and x.team = (select team from public.match_players y where y.match_id = o.id and y.player_id = v_team2[1])) = 2)
    ),
    'projected_change', v_viewer_projection
  );
end;
$$;

create or replace function private.match_json(p_match uuid, p_viewer uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  m public.matches%rowtype;
  me public.match_players%rowtype;
  v_is_participant boolean;
begin
  select * into m from public.matches where id = p_match;
  if not found then
    perform private.fail('match_not_found');
  end if;
  select * into me from public.match_players where match_id = p_match and player_id = p_viewer;
  v_is_participant := found;
  if not v_is_participant and m.status <> 'confirmed' then
    perform private.fail('match_not_found');
  end if;

  return jsonb_build_object(
    'id', m.id,
    'match_type', m.match_type,
    'format', m.format,
    'status', m.status,
    'played_at', m.played_at,
    'club', (select jsonb_build_object('id', cl.id, 'name', cl.name, 'city', c.name)
               from public.clubs cl join public.cities c on c.id = cl.city_id where cl.id = m.club_id),
    'sets', m.score,
    'winner_team', m.winner_team,
    'team1_sets', m.team1_sets,
    'team2_sets', m.team2_sets,
    'team1_games', m.team1_games,
    'team2_games', m.team2_games,
    'version', m.version,
    'created_by', m.created_by,
    'created_at', m.created_at,
    'updated_at', m.updated_at,
    'confirmed_at', m.confirmed_at,
    'expires_at', case when m.status in ('pending', 'disputed') then m.updated_at + interval '7 days' end,
    'rating_applied', m.rating_applied,
    'rating_weight', m.rating_weight,
    'players', (
      select jsonb_agg(jsonb_build_object(
               'player', private.player_card(mp.player_id),
               'team', mp.team,
               'court_side', mp.court_side,
               'response', mp.response,
               'responded_at', mp.responded_at,
               'dispute_reason', case when v_is_participant then mp.dispute_reason end,
               'dispute_comment', case when v_is_participant then mp.dispute_comment end,
               'rating_change', (
                 select jsonb_build_object(
                          'mu_before', round(e.mu_before::numeric, 3),
                          'mu_after', round(e.mu_after::numeric, 3),
                          'delta', round((e.mu_after - e.mu_before)::numeric, 3),
                          'sigma_before', round(e.sigma_before::numeric, 3),
                          'sigma_after', round(e.sigma_after::numeric, 3),
                          'details', e.details
                        )
                   from public.rating_events e
                  where e.match_id = m.id and e.player_id = mp.player_id
               )
             ) order by mp.team, mp.court_side desc)
        from public.match_players mp
       where mp.match_id = m.id
    ),
    'viewer', jsonb_build_object(
      'is_participant', v_is_participant,
      'team', me.team,
      'response', me.response,
      'is_creator', m.created_by = p_viewer,
      'can_confirm', v_is_participant and m.status in ('pending', 'disputed') and me.response <> 'confirmed',
      'can_dispute', v_is_participant and m.status in ('pending', 'disputed') and m.created_by <> p_viewer and me.response <> 'disputed',
      'can_edit', m.created_by = p_viewer and m.status in ('pending', 'disputed'),
      'can_cancel', m.created_by = p_viewer and m.status in ('pending', 'disputed'),
      'can_give_feedback', v_is_participant and m.status = 'confirmed' and m.confirmed_at > now() - interval '14 days',
      'feedback', case when v_is_participant then coalesce((
        select jsonb_agg(jsonb_build_object('player_id', f.ratee_id, 'strengths', f.strengths, 'improvements', f.improvements))
          from public.match_feedback f where f.match_id = m.id and f.rater_id = p_viewer
      ), '[]'::jsonb) end
    ),
    'analysis', private.match_analysis(m.id, p_viewer)
  );
end;
$$;

-- Compact list item for match lists.
create or replace function private.match_list_item(p_match uuid, p_viewer uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', m.id,
    'match_type', m.match_type,
    'format', m.format,
    'status', m.status,
    'played_at', m.played_at,
    'club_name', (select name from public.clubs where id = m.club_id),
    'sets', m.score,
    'winner_team', m.winner_team,
    'version', m.version,
    'updated_at', m.updated_at,
    'expires_at', case when m.status in ('pending', 'disputed') then m.updated_at + interval '7 days' end,
    'is_creator', m.created_by = p_viewer,
    'my_team', me.team,
    'my_response', me.response,
    'needs_action', me.player_id is not null and (
      (m.status in ('pending', 'disputed') and me.response = 'pending')
      or (m.status = 'disputed' and m.created_by = p_viewer)
    ),
    'pending_count', (select count(*) from public.match_players x where x.match_id = m.id and x.response = 'pending'),
    'disputed_count', (select count(*) from public.match_players x where x.match_id = m.id and x.response = 'disputed'),
    'rating_delta', (select round((e.mu_after - e.mu_before)::numeric, 3) from public.rating_events e
                      where e.match_id = m.id and e.player_id = p_viewer),
    'players', (
      select jsonb_agg(jsonb_build_object(
               'player', private.player_card(mp.player_id),
               'team', mp.team,
               'court_side', mp.court_side,
               'response', mp.response
             ) order by mp.team, mp.court_side desc)
        from public.match_players mp where mp.match_id = m.id
    )
  )
    from public.matches m
    left join public.match_players me on me.match_id = m.id and me.player_id = p_viewer
   where m.id = p_match
$$;

-- Lazily expires a stale open match (in addition to the scheduled job).
create or replace function private.expire_if_stale(p_match uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
begin
  update public.matches
     set status = 'expired', closed_at = now()
   where id = p_match
     and status in ('pending', 'disputed')
     and updated_at < now() - interval '7 days';
  return found;
end;
$$;

create or replace function private.expire_stale_matches()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  n integer;
begin
  update public.matches
     set status = 'expired', closed_at = now()
   where status in ('pending', 'disputed')
     and updated_at < now() - interval '7 days';
  get diagnostics n = row_count;
  delete from private.rate_limits where window_start < now() - interval '2 days';
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Public match API
-- ---------------------------------------------------------------------------

create or replace function public.create_match(p jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_existing uuid;
  v_input jsonb;
  v_id uuid;
begin
  if p_idempotency_key is null then
    perform private.fail('idempotency_key_required');
  end if;
  perform private.require_active_player(v_uid);

  select id into v_existing from public.matches where created_by = v_uid and idempotency_key = p_idempotency_key;
  if v_existing is not null then
    return private.match_json(v_existing, v_uid);
  end if;

  -- Serialise concurrent creates by the same user (duplicate detection and
  -- idempotency rely on it).
  perform pg_advisory_xact_lock(hashtextextended('create_match:' || v_uid::text, 0));
  select id into v_existing from public.matches where created_by = v_uid and idempotency_key = p_idempotency_key;
  if v_existing is not null then
    return private.match_json(v_existing, v_uid);
  end if;

  if not private.hit_rate_limit('create_match:' || v_uid, 30, 86400) then
    perform private.fail('rate_limited');
  end if;

  v_input := private.validate_match_input(p, v_uid, null);

  insert into public.matches (
    created_by, match_type, format, played_at, club_id, score, winner_team,
    team1_sets, team2_sets, team1_games, team2_games, idempotency_key
  ) values (
    v_uid, v_input ->> 'match_type', v_input ->> 'format', (v_input ->> 'played_at')::timestamptz,
    (v_input ->> 'club_id')::bigint, v_input -> 'score' -> 'sets', (v_input -> 'score' ->> 'winner_team')::smallint,
    (v_input -> 'score' ->> 'team1_sets')::smallint, (v_input -> 'score' ->> 'team2_sets')::smallint,
    (v_input -> 'score' ->> 'team1_games')::smallint, (v_input -> 'score' ->> 'team2_games')::smallint,
    p_idempotency_key
  ) returning id into v_id;

  perform private.insert_lineup(v_id, v_input -> 'players', v_uid);
  return private.match_json(v_id, v_uid);
end;
$$;

create or replace function public.update_match(p_match uuid, p_version integer, p jsonb, p_idempotency_key uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  m public.matches%rowtype;
  v_input jsonb;
begin
  if p_idempotency_key is null then
    perform private.fail('idempotency_key_required');
  end if;
  select * into m from public.matches where id = p_match for update;
  if not found or not exists (select 1 from public.match_players where match_id = p_match and player_id = v_uid) then
    perform private.fail('match_not_found');
  end if;
  if m.created_by <> v_uid then
    perform private.fail('forbidden');
  end if;
  if m.last_edit_key = p_idempotency_key then
    return private.match_json(p_match, v_uid);
  end if;
  if private.expire_if_stale(p_match) then
    perform private.fail('match_closed');
  end if;
  if m.status not in ('pending', 'disputed') then
    perform private.fail(case when m.status = 'confirmed' then 'match_locked' else 'match_closed' end);
  end if;
  if m.version <> p_version then
    perform private.fail('version_conflict', m.version::text);
  end if;

  v_input := private.validate_match_input(p, v_uid, p_match);

  delete from public.match_players where match_id = p_match;
  perform private.insert_lineup(p_match, v_input -> 'players', v_uid);

  update public.matches set
    match_type = v_input ->> 'match_type',
    format = v_input ->> 'format',
    played_at = (v_input ->> 'played_at')::timestamptz,
    club_id = (v_input ->> 'club_id')::bigint,
    score = v_input -> 'score' -> 'sets',
    winner_team = (v_input -> 'score' ->> 'winner_team')::smallint,
    team1_sets = (v_input -> 'score' ->> 'team1_sets')::smallint,
    team2_sets = (v_input -> 'score' ->> 'team2_sets')::smallint,
    team1_games = (v_input -> 'score' ->> 'team1_games')::smallint,
    team2_games = (v_input -> 'score' ->> 'team2_games')::smallint,
    status = 'pending',
    version = m.version + 1,
    last_edit_key = p_idempotency_key
  where id = p_match;

  return private.match_json(p_match, v_uid);
end;
$$;

-- Recomputes the aggregate status after a response change and finalises the
-- match when all four players confirmed.
create or replace function private.settle_match(p_match uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_disputed integer;
  v_pending integer;
  v_type text;
  v_player uuid;
begin
  select count(*) filter (where response = 'disputed'), count(*) filter (where response = 'pending')
    into v_disputed, v_pending
    from public.match_players where match_id = p_match;

  if v_disputed > 0 then
    update public.matches set status = 'disputed' where id = p_match and status <> 'disputed';
  elsif v_pending > 0 then
    update public.matches set status = 'pending' where id = p_match and status <> 'pending';
  else
    update public.matches set status = 'confirmed', confirmed_at = now()
     where id = p_match
     returning match_type into v_type;
    if v_type = 'ranked' then
      perform private.apply_ranked_match(p_match);
    end if;
    for v_player in select player_id from public.match_players where match_id = p_match loop
      perform private.recompute_dna(v_player);
    end loop;
  end if;
end;
$$;

create or replace function public.confirm_match(p_match uuid, p_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  m public.matches%rowtype;
  v_response text;
begin
  select * into m from public.matches where id = p_match for update;
  select response into v_response from public.match_players where match_id = p_match and player_id = v_uid;
  if m.id is null or v_response is null then
    perform private.fail('match_not_found');
  end if;
  if v_response = 'confirmed' or m.status = 'confirmed' then
    return private.match_json(p_match, v_uid);
  end if;
  if private.expire_if_stale(p_match) or m.status in ('cancelled', 'expired') then
    perform private.fail('match_closed');
  end if;
  if m.version <> p_version then
    perform private.fail('version_conflict', m.version::text);
  end if;

  update public.match_players
     set response = 'confirmed', responded_at = now(), dispute_reason = null, dispute_comment = null
   where match_id = p_match and player_id = v_uid;

  perform private.settle_match(p_match);
  return private.match_json(p_match, v_uid);
end;
$$;

create or replace function public.dispute_match(p_match uuid, p_version integer, p_reason text, p_comment text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  m public.matches%rowtype;
  v_response text;
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  if p_reason not in ('wrong_score', 'wrong_players', 'wrong_type', 'not_played', 'other') or p_reason is null then
    perform private.fail('invalid_dispute_reason');
  end if;
  if char_length(v_comment) > 140 then
    perform private.fail('dispute_comment_too_long');
  end if;
  select * into m from public.matches where id = p_match for update;
  select response into v_response from public.match_players where match_id = p_match and player_id = v_uid;
  if m.id is null or v_response is null then
    perform private.fail('match_not_found');
  end if;
  if m.created_by = v_uid then
    perform private.fail('creator_cannot_dispute');
  end if;
  if m.status = 'confirmed' then
    perform private.fail('match_locked');
  end if;
  if private.expire_if_stale(p_match) or m.status in ('cancelled', 'expired') then
    perform private.fail('match_closed');
  end if;
  if v_response = 'disputed' then
    update public.match_players set dispute_reason = p_reason, dispute_comment = v_comment
     where match_id = p_match and player_id = v_uid;
    return private.match_json(p_match, v_uid);
  end if;
  if m.version <> p_version then
    perform private.fail('version_conflict', m.version::text);
  end if;

  update public.match_players
     set response = 'disputed', responded_at = now(), dispute_reason = p_reason, dispute_comment = v_comment
   where match_id = p_match and player_id = v_uid;
  update public.matches set status = 'disputed' where id = p_match;
  return private.match_json(p_match, v_uid);
end;
$$;

create or replace function public.cancel_match(p_match uuid, p_version integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  m public.matches%rowtype;
begin
  select * into m from public.matches where id = p_match for update;
  if m.id is null or not exists (select 1 from public.match_players where match_id = p_match and player_id = v_uid) then
    perform private.fail('match_not_found');
  end if;
  if m.created_by <> v_uid then
    perform private.fail('forbidden');
  end if;
  if m.status = 'cancelled' then
    return private.match_json(p_match, v_uid);
  end if;
  if m.status = 'confirmed' then
    perform private.fail('match_locked');
  end if;
  if m.status = 'expired' then
    perform private.fail('match_closed');
  end if;
  if m.version <> p_version then
    perform private.fail('version_conflict', m.version::text);
  end if;
  update public.matches set status = 'cancelled', closed_at = now() where id = p_match;
  return private.match_json(p_match, v_uid);
end;
$$;

create or replace function public.match_detail(p_match uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform private.expire_if_stale(p_match);
  return private.match_json(p_match, v_uid);
end;
$$;

create or replace function public.my_matches(p_scope text, p_before timestamptz default null, p_limit integer default 30, p_type text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_items jsonb;
begin
  if p_scope not in ('open', 'history') then
    perform private.fail('invalid_request');
  end if;
  if p_type is not null and p_type not in ('friendly', 'ranked') then
    perform private.fail('invalid_request');
  end if;

  if p_scope = 'open' then
    update public.matches m
       set status = 'expired', closed_at = now()
     where m.status in ('pending', 'disputed')
       and m.updated_at < now() - interval '7 days'
       and exists (select 1 from public.match_players mp where mp.match_id = m.id and mp.player_id = v_uid);
    select coalesce(jsonb_agg(private.match_list_item(x.id, v_uid) order by x.needs desc, x.updated_at desc), '[]'::jsonb)
      into v_items
      from (
        select m.id, m.updated_at,
               ((m.status in ('pending', 'disputed') and mp.response = 'pending')
                 or (m.status = 'disputed' and m.created_by = v_uid)) as needs
          from public.matches m
          join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
         where m.status in ('pending', 'disputed')
      ) x;
    return jsonb_build_object('items', v_items, 'next_before', null);
  end if;

  select coalesce(jsonb_agg(private.match_list_item(x.id, v_uid) order by x.played_at desc, x.id), '[]'::jsonb)
    into v_items
    from (
      select m.id, m.played_at
        from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
       where m.status = 'confirmed'
         and (p_before is null or m.played_at < p_before)
         and (p_type is null or m.match_type = p_type)
       order by m.played_at desc, m.id
       limit v_limit
    ) x;

  return jsonb_build_object(
    'items', v_items,
    'next_before', case when jsonb_array_length(v_items) = v_limit then v_items -> (v_limit - 1) ->> 'played_at' end
  );
end;
$$;

create or replace function public.player_matches(p_player uuid, p_before timestamptz default null, p_limit integer default 30, p_type text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_items jsonb;
begin
  if not exists (select 1 from public.profiles where id = p_player) then
    perform private.fail('player_not_found');
  end if;
  if p_type is not null and p_type not in ('friendly', 'ranked') then
    perform private.fail('invalid_request');
  end if;
  select coalesce(jsonb_agg(
           private.match_list_item(x.id, v_uid) || jsonb_build_object(
             'subject_team', x.team,
             'subject_rating_delta', (select round((e.mu_after - e.mu_before)::numeric, 3) from public.rating_events e
                                      where e.match_id = x.id and e.player_id = p_player)
           ) order by x.played_at desc, x.id), '[]'::jsonb)
    into v_items
    from (
      select m.id, m.played_at, mp.team
        from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = p_player
       where m.status = 'confirmed'
         and (p_before is null or m.played_at < p_before)
         and (p_type is null or m.match_type = p_type)
       order by m.played_at desc, m.id
       limit v_limit
    ) x;
  return jsonb_build_object(
    'items', v_items,
    'next_before', case when jsonb_array_length(v_items) = v_limit then v_items -> (v_limit - 1) ->> 'played_at' end
  );
end;
$$;

-- Expected outcome and rating impact before a match is recorded.
create or replace function public.preview_match(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_format text := coalesce(p ->> 'format', 'best_of_3');
  v_players jsonb := p -> 'players';
  v_engine jsonb;
  v_ids uuid[];
  v_weight double precision;
  v_win jsonb;
  v_loss jsonb;
  v_actual jsonb;
  v_score jsonb;
  v_e double precision;
  v_eg double precision;
  v_n integer := 20;
  v_g1 integer;
  pl jsonb;
begin
  if v_format not in ('best_of_3', 'best_of_3_super_tiebreak', 'single_set') then
    perform private.fail('invalid_format');
  end if;
  if v_players is null or private.jtype(v_players) <> 'array' or jsonb_array_length(v_players) <> 4 then
    perform private.fail('match_lineup_invalid');
  end if;
  for pl in select value from jsonb_array_elements(v_players) loop
    perform private.require_active_player((pl ->> 'player_id')::uuid);
    v_ids := v_ids || (pl ->> 'player_id')::uuid;
  end loop;
  if (select count(distinct x) from unnest(v_ids) x) <> 4 then
    perform private.fail('duplicate_player');
  end if;
  if (select count(*) from jsonb_array_elements(v_players) x where x ->> 'team' = '1') <> 2 then
    perform private.fail('match_lineup_invalid');
  end if;

  v_engine := private.engine_players(v_players);
  v_weight := private.repeat_lineup_weight(v_ids, null);

  -- Neutral-margin scenarios: games split exactly as the model expects.
  v_win := private.compute_rating_update(v_engine, v_format, 1::smallint, 12, 8, v_weight, now());
  v_e := (v_win ->> 'expected_win_team1')::double precision;
  v_eg := (v_win ->> 'expected_game_share_team1')::double precision;
  v_g1 := round(v_n * v_eg);
  v_win := private.compute_rating_update(v_engine, v_format, 1::smallint, greatest(v_g1, 1), greatest(v_n - v_g1, 0), v_weight, now());
  v_loss := private.compute_rating_update(v_engine, v_format, 2::smallint, greatest(v_g1, 0), greatest(v_n - v_g1, 1), v_weight, now());

  if p ? 'sets' and private.jtype(p -> 'sets') = 'array' then
    begin
      v_score := private.validate_score(v_format, p -> 'sets');
      v_actual := private.compute_rating_update(v_engine, v_format, (v_score ->> 'winner_team')::smallint,
        (v_score ->> 'team1_games')::integer, (v_score ->> 'team2_games')::integer, v_weight, now());
    exception when sqlstate 'P0001' then
      v_actual := null;
    end;
  end if;

  return jsonb_build_object(
    'expected_win_team1', round(v_e::numeric, 3),
    'team1_strength', round((v_win ->> 'team1_strength')::numeric, 2),
    'team2_strength', round((v_win ->> 'team2_strength')::numeric, 2),
    'weight', v_weight,
    'players', (
      select jsonb_agg(jsonb_build_object(
               'player_id', w ->> 'id',
               'team', (w ->> 'team')::integer,
               'if_team1_wins', round((w ->> 'delta')::numeric, 3),
               'if_team2_wins', round((l ->> 'delta')::numeric, 3),
               'with_entered_score', case when v_actual is null then null else (
                 select round((a ->> 'delta')::numeric, 3) from jsonb_array_elements(v_actual -> 'players') a where a ->> 'id' = w ->> 'id'
               ) end
             ))
        from jsonb_array_elements(v_win -> 'players') w
        join jsonb_array_elements(v_loss -> 'players') l on l ->> 'id' = w ->> 'id'
    )
  );
end;
$$;

create or replace function public.submit_match_feedback(p_match uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  m public.matches%rowtype;
  item jsonb;
  v_ratee uuid;
  v_strengths text[];
  v_improvements text[];
  v_affected uuid[] := array[]::uuid[];
begin
  select * into m from public.matches where id = p_match;
  if not found or not exists (select 1 from public.match_players where match_id = p_match and player_id = v_uid) then
    perform private.fail('match_not_found');
  end if;
  if m.status <> 'confirmed' then
    perform private.fail('match_not_confirmed');
  end if;
  if m.confirmed_at < now() - interval '14 days' then
    perform private.fail('feedback_window_closed');
  end if;
  if p is null or private.jtype(p -> 'ratings') <> 'array' then
    perform private.fail('invalid_request');
  end if;

  for item in select value from jsonb_array_elements(p -> 'ratings') loop
    begin
      v_ratee := (item ->> 'player_id')::uuid;
    exception when others then
      perform private.fail('player_not_found');
    end;
    if v_ratee = v_uid or not exists (select 1 from public.match_players where match_id = p_match and player_id = v_ratee) then
      perform private.fail('invalid_feedback_target');
    end if;
    if v_ratee = any (v_affected) then
      perform private.fail('invalid_request', 'duplicate feedback target');
    end if;
    begin
      v_strengths := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(item -> 'strengths', '[]'::jsonb)) x), '{}');
      v_improvements := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(item -> 'improvements', '[]'::jsonb)) x), '{}');
    exception when others then
      perform private.fail('invalid_feedback');
    end;
    if cardinality(v_strengths) > 2 or cardinality(v_improvements) > 1
       or not (v_strengths <@ private.dna_dimensions()) or not (v_improvements <@ private.dna_dimensions())
       or v_strengths && v_improvements
       or (select count(distinct x) from unnest(v_strengths) x) <> cardinality(v_strengths) then
      perform private.fail('invalid_feedback');
    end if;

    if cardinality(v_strengths) + cardinality(v_improvements) = 0 then
      delete from public.match_feedback where match_id = p_match and rater_id = v_uid and ratee_id = v_ratee;
    else
      insert into public.match_feedback (match_id, rater_id, ratee_id, strengths, improvements)
      values (p_match, v_uid, v_ratee, v_strengths, v_improvements)
      on conflict (match_id, rater_id, ratee_id) do update
        set strengths = excluded.strengths, improvements = excluded.improvements, updated_at = now();
    end if;
    v_affected := v_affected || v_ratee;
  end loop;

  foreach v_ratee in array v_affected loop
    perform private.recompute_dna(v_ratee);
  end loop;

  return private.match_json(p_match, v_uid);
end;
$$;
