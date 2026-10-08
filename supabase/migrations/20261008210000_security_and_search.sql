-- Security and search hardening after the security and performance reviews.
--
-- M1  Password checks are counted per user, and failed attempts stay counted.
-- M2  discoverable = false hides a player beyond search: profile-level reads
--     need the viewer to be the player, to share a match with them, or to be
--     an administrator.
-- L5  New auth.users rows must carry the marker that only the account service
--     sets (public GoTrue sign-up is also disabled in the Auth settings).
-- F3  search_players computes pair statistics once per request instead of
--     calling private.compatibility() for every candidate, and its text filter
--     can use profiles_search_trgm.
-- F11 Duplicate-match detection starts from one player's matches
--     (match_players_player_idx) instead of scanning all matches.
--
-- Function signatures are unchanged. Every function created or replaced here
-- is re-granted at the end of the file.

-- ---------------------------------------------------------------------------
-- M1. Password attempts
--
-- PostgREST runs each RPC in one transaction, so raising an error after
-- private.hit_rate_limit() rolled the attempt back as well: wrong passwords
-- were never counted. All password checks share the per-user bucket
-- 'verify_password:<user>' (10 attempts per 15 minutes) and report a wrong
-- password in their result instead of raising, so the attempt is committed.
-- ---------------------------------------------------------------------------

create or replace function public.regenerate_recovery_key(p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if not private.hit_rate_limit('verify_password:' || v_uid, 10, 900) then
    perform private.fail('rate_limited');
  end if;
  if not private.check_password(v_uid, p_password) then
    -- Returned, not raised: raising would roll back the counted attempt.
    -- The gateway maps this to 403 invalid_password.
    return jsonb_build_object('error', 'invalid_password');
  end if;
  return jsonb_build_object('recovery_key', private.issue_recovery_key(v_uid));
end;
$$;

-- Used by the account service before an email change or account deletion.
-- Volatile (it writes the attempt counter); false for a wrong password, the
-- error rate_limited once the user's budget is spent.
create or replace function public.svc_check_password(p_user uuid, p_password text)
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if p_user is null then
    return false;
  end if;
  if not private.hit_rate_limit('verify_password:' || p_user, 10, 900) then
    perform private.fail('rate_limited');
  end if;
  return private.check_password(p_user, p_password);
end;
$$;

-- ---------------------------------------------------------------------------
-- M2. Visibility of players who turned off discoverability
-- ---------------------------------------------------------------------------

-- A player with discoverable = false is visible only to themselves, to
-- players who share at least one match with them (the same rule as search)
-- and to administrators. Line-up cards inside matches are not affected.
-- Deleted accounts are not discoverable, so their tombstone stays visible to
-- the players they played with.
create or replace function private.require_visible_player(p_viewer uuid, p_player uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if p_viewer = p_player
     or exists (select 1 from public.profiles pr where pr.id = p_player and pr.discoverable)
     or exists (select 1 from private.admins ad where ad.user_id = p_viewer)
     or exists (select 1 from public.match_players a
                  join public.match_players b on b.match_id = a.match_id and b.player_id = p_player
                 where a.player_id = p_viewer) then
    return;
  end if;
  perform private.fail('player_not_found', p_player::text);
end;
$$;

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
  perform private.require_visible_player(v_uid, p_player);
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
  perform private.require_visible_player(v_uid, p_player);
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

create or replace function public.player_matches(p_player uuid, p_before timestamptz default null, p_limit integer default 30,
                                                 p_type text default null, p_before_id uuid default null)
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
  perform private.require_visible_player(v_uid, p_player);
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
         and (p_before is null
              or m.played_at < p_before
              or (m.played_at = p_before and p_before_id is not null and m.id > p_before_id))
         and (p_type is null or m.match_type = p_type)
       order by m.played_at desc, m.id
       limit v_limit
    ) x;
  return jsonb_build_object('items', v_items) || private.history_cursor(v_items, v_limit);
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
  perform private.require_visible_player(v_uid, p_player);
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
  perform private.require_visible_player(v_uid, p_player);
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

create or replace function public.submit_coach_assessment(p_player uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_scores jsonb := p -> 'scores';
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  k text;
  v jsonb;
  v_mu double precision;
begin
  if not exists (select 1 from public.coach_applications where player_id = v_uid and status = 'approved') then
    perform private.fail('not_a_coach');
  end if;
  if p_player = v_uid then
    perform private.fail('cannot_assess_self');
  end if;
  perform private.require_active_player(p_player);
  perform private.require_visible_player(v_uid, p_player);

  if v_scores is null or private.jtype(v_scores) <> 'object'
     or (select count(*) from jsonb_object_keys(v_scores)) <> 6 then
    perform private.fail('invalid_assessment');
  end if;
  for k, v in select key, value from jsonb_each(v_scores) loop
    if not (k = any (private.dna_dimensions())) or private.jtype(v) <> 'number'
       or (v::text)::numeric < 0 or (v::text)::numeric > 7 or ((v::text)::numeric * 2) % 1 <> 0 then
      perform private.fail('invalid_assessment');
    end if;
  end loop;
  if char_length(v_note) > 500 then
    perform private.fail('invalid_assessment');
  end if;

  if exists (select 1 from public.coach_assessments
              where coach_id = v_uid and player_id = p_player and created_at > now() - interval '24 hours') then
    perform private.fail('assessment_too_soon');
  end if;

  select mu into v_mu from public.player_ratings where player_id = p_player;
  insert into public.coach_assessments (coach_id, player_id, scores, player_mu_at, note)
  values (v_uid, p_player, v_scores, v_mu, v_note);

  perform private.recompute_dna(p_player);
  return public.player_profile(p_player);
end;
$$;

-- ---------------------------------------------------------------------------
-- L5. Accounts are created only by the account service
--
-- Public sign-up through GoTrue (/auth/v1/signup) is disabled in the Auth
-- settings. As defense in depth, a new auth.users row must carry
-- app_metadata.padelid_origin = 'account-service'. app_metadata can only be
-- written with the service role, which only the account service holds.
--
-- GoTrue's admin createUser inserts the row with app_metadata
-- {provider, providers} and merges the caller's app_metadata with an UPDATE
-- later in the same transaction (internal/api/admin.go, adminUserCreate), so
-- a BEFORE INSERT check would reject every legitimate sign-up. The check is a
-- deferred constraint trigger instead: it runs at commit and reads the row as
-- it is about to be committed, so no account without the marker is ever
-- stored.
-- ---------------------------------------------------------------------------

create or replace function private.require_account_service_origin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from auth.users u
     where u.id = new.id
       and coalesce(u.raw_app_meta_data ->> 'padelid_origin', '') <> 'account-service'
  ) then
    raise exception using
      errcode = '42501',
      message = 'signup_not_allowed',
      detail = 'Padel ID accounts are created only by the account service.';
  end if;
  return null;
end;
$$;

drop trigger if exists padelid_require_account_service on auth.users;
create constraint trigger padelid_require_account_service
  after insert on auth.users
  deferrable initially deferred
  for each row execute function private.require_account_service_origin();

-- ---------------------------------------------------------------------------
-- F3. Compatibility scoring shared by the profile endpoint and search
-- ---------------------------------------------------------------------------

-- Pure scoring from per-pair inputs. private.compatibility() gathers the inputs
-- for one pair; search_players() gathers them for all candidates at once.
-- Inputs: rating (mu, effective sigma), preferred side, club and city of both
-- players; p_style / p_style_conf are the averages over shared DNA dimensions
-- of |offset difference| and min(1 - sqrt(var) / 0.45) (null without DNA);
-- p_chem_n / p_chem_resid count the pair's rated matches as partners and their
-- average (won - expected_win).
create or replace function private.compatibility_parts(
  p_mu_a double precision, p_sigma_a double precision, p_side_a text, p_club_a bigint, p_city_a integer,
  p_mu_b double precision, p_sigma_b double precision, p_side_b text, p_club_b bigint, p_city_b integer,
  p_style double precision, p_style_conf double precision,
  p_chem_n integer, p_chem_resid double precision,
  out level double precision, out sides double precision,
  out style double precision, out w_style double precision,
  out chem double precision, out w_chem double precision,
  out logistics double precision, out score integer)
language sql
immutable
set search_path = ''
as $$
  select x.level, x.sides, x.style, x.w_style, x.chem, x.w_chem, x.logistics,
         round(100 * ((0.35::double precision * x.level + 0.2::double precision * x.sides + x.w_style * x.style
                       + x.w_chem * x.chem + 0.1::double precision * x.logistics)
                      / (0.35::double precision + 0.2::double precision + x.w_style + x.w_chem + 0.1::double precision)))::integer
    from (
      select
        -- Level fit: partners of similar level form balanced, rating-relevant teams.
        exp(-(abs(p_mu_a - p_mu_b) ^ 2) / (2 * (0.5 ^ 2 + 0.25 * (p_sigma_a ^ 2 + p_sigma_b ^ 2)))) as level,
        -- Court sides: complementary preferences make the pairing work naturally.
        (case
           when p_side_a <> 'both' and p_side_b <> 'both' and p_side_a <> p_side_b then 1.0
           when p_side_a = 'both' and p_side_b = 'both' then 0.8
           when p_side_a = 'both' or p_side_b = 'both' then 0.85
           else 0.35
         end)::double precision as sides,
        -- Style: how well the pair covers each other's weaker dimensions.
        case when p_style is null then 0.5::double precision
             else least(1, 0.5 + p_style * 1.5) end as style,
        case when p_style is null then 0::double precision
             else 0.2::double precision * greatest(0.25, greatest(0, p_style_conf)) end as w_style,
        -- Chemistry: actual results together versus model expectation.
        case when p_chem_n >= 2 then 1 / (1 + exp(-4 * p_chem_resid))
             else 0.5::double precision end as chem,
        case when p_chem_n >= 2 then 0.15::double precision * least(1, p_chem_n / 5.0)
             else 0::double precision end as w_chem,
        -- Logistics: same club or city makes regular games realistic.
        (case
           when p_club_a is not null and p_club_a = p_club_b then 1.0
           when p_city_a is not null and p_city_a = p_city_b then 0.7
           else 0.2
         end)::double precision as logistics
    ) x
$$;

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
  v_style double precision;
  v_style_conf double precision;
  v_chem_n integer;
  v_chem_resid double precision;
  v_together integer;
  w_level double precision := 0.35;
  w_sides double precision := 0.2;
  w_log double precision := 0.1;
  v_reasons jsonb := '[]'::jsonb;
  v_cover jsonb;
  x record;
begin
  select * into a from public.profiles where id = p_a;
  select * into b from public.profiles where id = p_b;
  select * into ra from public.player_ratings where player_id = p_a;
  select * into rb from public.player_ratings where player_id = p_b;
  if a.id is null or b.id is null or ra.player_id is null or rb.player_id is null or p_a = p_b then
    return null;
  end if;

  -- The aggregates are ordered so that search_players(), which computes the
  -- same inputs set-based, gets bit-identical averages.
  select avg(greatest(da.offset_mean, db.offset_mean) - least(da.offset_mean, db.offset_mean) order by da.dimension),
         avg(least(1 - sqrt(da.offset_var) / 0.45, 1 - sqrt(db.offset_var) / 0.45) order by da.dimension)
    into v_style, v_style_conf
    from public.player_dna da
    join public.player_dna db on db.dimension = da.dimension and db.player_id = p_b
   where da.player_id = p_a;

  select count(*),
         avg((case when (ea.details ->> 'won')::boolean then 1 else 0 end) - (ea.details ->> 'expected_win')::double precision
             order by ea.match_id)
    into v_chem_n, v_chem_resid
    from public.rating_events ea
    join public.rating_events eb on eb.match_id = ea.match_id and eb.player_id = p_b
   where ea.player_id = p_a and ea.kind = 'match'
     and (ea.details ->> 'team') = (eb.details ->> 'team');

  select * into x from private.compatibility_parts(
    ra.mu, private.effective_sigma(ra.sigma, coalesce(ra.last_ranked_at, ra.created_at), now()),
    a.preferred_side, a.club_id, a.city_id,
    rb.mu, private.effective_sigma(rb.sigma, coalesce(rb.last_ranked_at, rb.created_at), now()),
    b.preferred_side, b.club_id, b.city_id,
    v_style, v_style_conf, v_chem_n, v_chem_resid);

  v_reasons := v_reasons || jsonb_build_object('code', 'level_gap', 'value', round(abs(ra.mu - rb.mu)::numeric, 2));
  v_reasons := v_reasons || jsonb_build_object('code', 'sides', 'a', a.preferred_side, 'b', b.preferred_side);

  if v_style is not null then
    select jsonb_agg(y.dimension) into v_cover from (
      select da.dimension
        from public.player_dna da
        join public.player_dna db on db.dimension = da.dimension and db.player_id = p_b
       where da.player_id = p_a and da.offset_mean < -0.05 and db.offset_mean > 0.05
       order by db.offset_mean - da.offset_mean desc
       limit 2
    ) y;
    if v_cover is not null then
      v_reasons := v_reasons || jsonb_build_object('code', 'covers_weakness', 'dimensions', v_cover);
    end if;
  end if;

  if v_chem_n >= 2 then
    v_reasons := v_reasons || jsonb_build_object('code', 'chemistry', 'matches', v_chem_n, 'residual', round(v_chem_resid::numeric, 2));
  else
    select count(*) into v_together
      from public.match_players mx
      join public.match_players my on my.match_id = mx.match_id and my.player_id = p_b and my.team = mx.team
      join public.matches m on m.id = mx.match_id and m.status = 'confirmed'
     where mx.player_id = p_a;
    if v_together > 0 then
      v_reasons := v_reasons || jsonb_build_object('code', 'played_together', 'matches', v_together);
    end if;
  end if;

  if a.club_id is not null and a.club_id = b.club_id then
    v_reasons := v_reasons || jsonb_build_object('code', 'same_club');
  elsif a.city_id is not null and a.city_id = b.city_id then
    v_reasons := v_reasons || jsonb_build_object('code', 'same_city');
  end if;

  return jsonb_build_object(
    'score', x.score,
    'components', jsonb_build_array(
      jsonb_build_object('key', 'level', 'value', round(x.level::numeric, 2), 'weight', round(w_level::numeric, 3)),
      jsonb_build_object('key', 'sides', 'value', round(x.sides::numeric, 2), 'weight', round(w_sides::numeric, 3)),
      jsonb_build_object('key', 'style', 'value', round(x.style::numeric, 2), 'weight', round(x.w_style::numeric, 3)),
      jsonb_build_object('key', 'chemistry', 'value', round(x.chem::numeric, 2), 'weight', round(x.w_chem::numeric, 3)),
      jsonb_build_object('key', 'logistics', 'value', round(x.logistics::numeric, 2), 'weight', round(w_log::numeric, 3))
    ),
    'reasons', v_reasons
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- F3. Player search
--
-- * Pair statistics (the viewer's DNA against each candidate, chemistry from
--   the viewer's rated matches) are computed once per request in set-based
--   CTEs and scored with private.compatibility_parts(); the per-pair scans of
--   private.compatibility() no longer run for every candidate.
-- * The text filter uses the expression of profiles_search_trgm
--   ((name_norm || ' ' || username), deleted_at is null) with LIKE and the
--   trigram operator % (pg_trgm.similarity_threshold, default 0.3; equivalent
--   to the previous similarity() > 0.3), both indexable.
-- * plan_cache_mode = force_custom_plan plans each call with the actual
--   values, so an empty query or filter folds away and a text query can use
--   the index; a cached generic plan would keep "v_q = '' or ..." and scan
--   every profile.
-- ---------------------------------------------------------------------------

create or replace function public.search_players(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
set plan_cache_mode = force_custom_plan
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
  v_compat boolean;
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
  v_compat := v_sort = 'compatibility' and v_my_mu is not null;

  with candidates as (
    select pr.id, pr.display_name, pr.preferred_side, pr.club_id, pr.city_id, r.mu, r.last_ranked_at,
           private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now()) as sigma,
           case when v_q = '' then 0 else extensions.similarity(pr.name_norm || ' ' || pr.username, v_q) end as sim
      from public.profiles pr
      join public.player_ratings r on r.player_id = pr.id
     where pr.deleted_at is null
       and pr.id <> v_uid
       and (pr.discoverable or exists (
             select 1 from public.match_players a
               join public.match_players b on b.match_id = a.match_id and b.player_id = pr.id
              where a.player_id = v_uid))
       and (v_q = ''
            or (pr.name_norm || ' ' || pr.username) like '%' || v_q || '%'
            or (pr.name_norm || ' ' || pr.username) operator(extensions.%) v_q)
       and (v_city is null or pr.city_id = v_city)
       and (v_club is null or pr.club_id = v_club)
       and r.mu between v_min and v_max
       and (v_side is null or pr.preferred_side = v_side or (v_side <> 'both' and pr.preferred_side = 'both'))
       and (not v_coaches or pr.is_coach)
  ), filtered as (
    select c.*
      from candidates c
     where not v_reliable or private.reliability(c.sigma) >= 50
  ), me as (
    select pr.preferred_side, pr.club_id, pr.city_id, r.mu,
           private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now()) as sigma
      from public.profiles pr
      join public.player_ratings r on r.player_id = pr.id
     where v_compat and pr.id = v_uid
  ), my_dna as (
    select d.dimension, d.offset_mean, d.offset_var
      from public.player_dna d
     where v_compat and d.player_id = v_uid
  ), style as (
    -- Same aggregates, in the same order, as private.compatibility().
    select db.player_id,
           avg(greatest(da.offset_mean, db.offset_mean) - least(da.offset_mean, db.offset_mean) order by da.dimension) as diff,
           avg(least(1 - sqrt(da.offset_var) / 0.45, 1 - sqrt(db.offset_var) / 0.45) order by da.dimension) as conf
      from filtered f
      join public.player_dna db on db.player_id = f.id
      join my_dna da on da.dimension = db.dimension
     group by db.player_id
  ), chem as (
    -- The viewer's rated matches, grouped by partner: one pass for all candidates.
    select eb.player_id,
           count(*)::integer as n,
           avg((case when (ea.details ->> 'won')::boolean then 1 else 0 end) - (ea.details ->> 'expected_win')::double precision
               order by ea.match_id) as resid
      from public.rating_events ea
      join public.rating_events eb on eb.match_id = ea.match_id and eb.player_id <> ea.player_id
                                   and (eb.details ->> 'team') = (ea.details ->> 'team')
     where v_compat and ea.player_id = v_uid and ea.kind = 'match'
     group by eb.player_id
  ), scored as (
    select f.*,
           case when v_compat then (private.compatibility_parts(
                  me.mu, me.sigma, me.preferred_side, me.club_id, me.city_id,
                  f.mu, f.sigma, f.preferred_side, f.club_id, f.city_id,
                  st.diff, st.conf, coalesce(ch.n, 0), ch.resid)).score end as compat
      from filtered f
      left join me on true
      left join style st on st.player_id = f.id
      left join chem ch on ch.player_id = f.id
  ), ordered as (
    select s.id, s.compat, count(*) over () as total,
           row_number() over (order by
             case when v_q <> '' and v_sort = 'compatibility' then -s.sim end,
             case when v_sort = 'compatibility' then -coalesce(s.compat, 0) end,
             case when v_sort = 'level_desc' then -s.mu end,
             case when v_sort = 'level_asc' then s.mu end,
             case when v_sort = 'recent' then extract(epoch from s.last_ranked_at) end desc nulls last,
             s.display_name, s.id) as rn
      from scored s
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

-- ---------------------------------------------------------------------------
-- F11. Duplicate-match detection through match_players_player_idx
--
-- Unchanged except for the duplicate check: a match with the same four
-- players necessarily contains the first of them, so the check walks that
-- player's matches instead of every match in the time window.
-- ---------------------------------------------------------------------------

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
  -- different participants). Such a match includes v_ids[1], so the search
  -- starts from that player's matches (match_players_player_idx).
  if exists (
    select 1
      from public.match_players p0
      join public.matches m on m.id = p0.match_id
     where p0.player_id = v_ids[1]
       and m.status in ('pending', 'disputed', 'confirmed')
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

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

-- Private helpers: not callable by any API role (the trigger function runs as
-- a trigger and needs no EXECUTE grant).
revoke all on function private.require_visible_player(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.require_account_service_origin() from public, anon, authenticated, service_role;
revoke all on function private.compatibility_parts(double precision, double precision, text, bigint, integer,
                                                   double precision, double precision, text, bigint, integer,
                                                   double precision, double precision, integer, double precision)
  from public, anon, authenticated, service_role;
revoke all on function private.compatibility(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.validate_match_input(jsonb, uuid, uuid) from public, anon, authenticated, service_role;

-- End-user API.
revoke all on function public.regenerate_recovery_key(text) from public, anon, authenticated, service_role;
revoke all on function public.player_profile(uuid) from public, anon, authenticated, service_role;
revoke all on function public.rating_history(uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.player_matches(uuid, timestamptz, integer, text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.compatibility(uuid) from public, anon, authenticated, service_role;
revoke all on function public.player_dna(uuid) from public, anon, authenticated, service_role;
revoke all on function public.submit_coach_assessment(uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.search_players(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.regenerate_recovery_key(text) to authenticated;
grant execute on function public.player_profile(uuid) to authenticated;
grant execute on function public.rating_history(uuid, integer) to authenticated;
grant execute on function public.player_matches(uuid, timestamptz, integer, text, uuid) to authenticated;
grant execute on function public.compatibility(uuid) to authenticated;
grant execute on function public.player_dna(uuid) to authenticated;
grant execute on function public.submit_coach_assessment(uuid, jsonb) to authenticated;
grant execute on function public.search_players(jsonb) to authenticated;

-- Account service only.
revoke all on function public.svc_check_password(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.svc_check_password(uuid, text) to service_role;
