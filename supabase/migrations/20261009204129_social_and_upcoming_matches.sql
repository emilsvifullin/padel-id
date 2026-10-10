-- Mutual friendships and future games. Existing scored-match APIs and rating
-- mathematics remain unchanged. All mutations serialize the relationship/game
-- before checking state; API roles have no direct access to the underlying rows.

create table public.friendships (
  player_low uuid not null references public.profiles(id),
  player_high uuid not null references public.profiles(id),
  requested_by uuid not null references public.profiles(id),
  status text not null check (status in ('pending', 'accepted', 'rejected', 'cancelled', 'removed')),
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (player_low, player_high),
  check (player_low < player_high),
  check (requested_by in (player_low, player_high))
);
create index friendships_high_idx on public.friendships (player_high, status, requested_at desc);
create index friendships_requester_idx on public.friendships (requested_by);
create trigger friendships_touch before update on public.friendships
  for each row execute function private.touch_updated_at();

create table public.scheduled_matches (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null,
  organizer_id uuid not null references public.profiles(id),
  starts_at timestamptz not null,
  city_id integer not null references public.cities(id),
  club_id bigint references public.clubs(id) on delete set null,
  location text not null check (char_length(location) between 2 and 160),
  match_type text not null check (match_type in ('ranked', 'friendly')),
  min_level numeric not null check (min_level between 0 and 7),
  max_level numeric not null check (max_level between 0 and 7 and max_level >= min_level),
  note text check (char_length(note) <= 500),
  cancelled_at timestamptz,
  result_match_id uuid unique references public.matches(id),
  result_input jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organizer_id, client_id),
  check ((result_match_id is null) = (result_input is null)),
  check (cancelled_at is null or result_match_id is null)
);
create index scheduled_matches_feed_idx on public.scheduled_matches (city_id, starts_at, id)
  where cancelled_at is null and result_match_id is null;
create index scheduled_matches_starts_idx on public.scheduled_matches (starts_at, id);
create index scheduled_matches_club_idx on public.scheduled_matches (club_id);
create trigger scheduled_matches_touch before update on public.scheduled_matches
  for each row execute function private.touch_updated_at();

-- One row per game/player also holds an applicant's decision, so repeated
-- joins cannot produce duplicate seats or duplicate applications.
create table public.scheduled_match_players (
  match_id uuid not null references public.scheduled_matches(id) on delete cascade,
  player_id uuid not null references public.profiles(id),
  status text not null check (status in ('pending', 'accepted', 'rejected', 'withdrawn')),
  requested_at timestamptz not null default now(),
  joined_at timestamptz,
  decided_at timestamptz,
  primary key (match_id, player_id),
  check ((status = 'accepted') = (joined_at is not null))
);
create index scheduled_match_players_player_idx on public.scheduled_match_players (player_id, status, match_id);

alter table public.friendships enable row level security;
alter table public.scheduled_matches enable row level security;
alter table public.scheduled_match_players enable row level security;
create policy "no direct access" on public.friendships as restrictive for all to anon, authenticated using (false) with check (false);
create policy "no direct access" on public.scheduled_matches as restrictive for all to anon, authenticated using (false) with check (false);
create policy "no direct access" on public.scheduled_match_players as restrictive for all to anon, authenticated using (false) with check (false);
revoke all on public.friendships, public.scheduled_matches, public.scheduled_match_players from public, anon, authenticated, service_role;

-- A mutation may wait on a relationship/game lock after checking its player.
-- Hold profile rows in UUID order so account anonymization cannot finish its
-- cleanup and then be followed by a waiting mutation admitting a deleted user.
create or replace function private.lock_active_social_players(p_players uuid[])
returns void language plpgsql set search_path = '' as $$
declare v_player uuid;
begin
  perform id from public.profiles where id = any(p_players) order by id for share;
  foreach v_player in array p_players loop
    perform private.require_active_player(v_player);
  end loop;
end;
$$;

create or replace function private.socially_visible(p_viewer uuid, p_player uuid)
returns boolean language sql stable set search_path = '' as $$
  select p_viewer = p_player
    or exists (select 1 from public.profiles where id = p_player and discoverable and deleted_at is null)
    or exists (select 1 from private.admins where user_id = p_viewer)
    or exists (select 1 from public.match_players a join public.match_players b on b.match_id = a.match_id and b.player_id = p_player where a.player_id = p_viewer)
    -- Sending a request voluntarily lets its recipient inspect the requester;
    -- it does not expose a hidden recipient to an unrelated requester.
    or exists (select 1 from public.friendships f
      where f.player_low = least(p_viewer, p_player) and f.player_high = greatest(p_viewer, p_player)
        and (f.status = 'accepted' or (f.status = 'pending' and f.requested_by = p_player)))
    or exists (select 1 from public.scheduled_match_players a
      join public.scheduled_match_players b on b.match_id = a.match_id and b.player_id = p_player and b.status = 'accepted'
      join public.scheduled_matches m on m.id = a.match_id and m.cancelled_at is null
      where a.player_id = p_viewer and a.status = 'accepted')
$$;

create or replace function private.require_visible_player(p_viewer uuid, p_player uuid)
returns void language plpgsql stable set search_path = '' as $$
begin
  if not private.socially_visible(p_viewer, p_player) then
    perform private.fail('player_not_found', p_player::text);
  end if;
end;
$$;

create or replace function private.friendship_status(p_viewer uuid, p_player uuid)
returns text language sql stable set search_path = '' as $$
  select coalesce((select case when status = 'accepted' then 'accepted'
     when status = 'pending' and requested_by = p_viewer then 'outgoing'
     when status = 'pending' then 'incoming' else 'none' end
    from public.friendships where player_low = least(p_viewer, p_player) and player_high = greatest(p_viewer, p_player)), 'none')
$$;

create or replace function private.visible_card(p_viewer uuid, p_player uuid, p_allowed boolean default false)
returns jsonb language sql stable set search_path = '' as $$
  select case when p_allowed or private.socially_visible(p_viewer, p_player) then private.player_card(p_player)
    else jsonb_build_object('id', p_player, 'username', null, 'display_name', 'Скрытый игрок', 'deleted', false,
      'avatar_path', null, 'city', null, 'club', null, 'preferred_side', null, 'is_coach', false, 'level', null, 'reliability', null) end
$$;

create or replace function public.friendship_status(p_player uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid();
begin
  perform private.require_active_player(v_uid);
  perform private.require_active_player(p_player);
  perform private.require_visible_player(v_uid, p_player);
  return jsonb_build_object('player_id', p_player, 'status', private.friendship_status(v_uid, p_player));
end;
$$;

create or replace function public.friendships()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_out jsonb;
begin
  perform private.require_active_player(v_uid);
  with relations as (
    select f.requested_at, case when f.player_low = v_uid then f.player_high else f.player_low end as other,
      case when f.status = 'accepted' then 'accepted' when f.requested_by = v_uid then 'outgoing' else 'incoming' end as category
    from public.friendships f where v_uid in (f.player_low, f.player_high) and f.status in ('pending', 'accepted')
  ), cards as (
    select r.*, jsonb_build_object('player', private.visible_card(v_uid, r.other), 'status', r.category, 'requested_at', r.requested_at) as card
    from relations r join public.profiles pr on pr.id = r.other and pr.deleted_at is null
  )
  select jsonb_build_object(
    'accepted', coalesce(jsonb_agg(card order by requested_at desc, other) filter (where category = 'accepted'), '[]'::jsonb),
    'incoming', coalesce(jsonb_agg(card order by requested_at desc, other) filter (where category = 'incoming'), '[]'::jsonb),
    'outgoing', coalesce(jsonb_agg(card order by requested_at desc, other) filter (where category = 'outgoing'), '[]'::jsonb)) into v_out from cards;
  return v_out;
end;
$$;

create or replace function public.friendship_action(p_player uuid, p_action text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); f public.friendships%rowtype;
begin
  perform private.lock_active_social_players(array[v_uid,p_player]);
  if v_uid = p_player then perform private.fail('friendship_self'); end if;
  if p_action is null or p_action not in ('request', 'accept', 'reject', 'cancel', 'remove') then perform private.fail('friendship_action_invalid'); end if;
  -- Pair lock exists even before its first row; opposing requests use the same
  -- canonical key and never create asymmetric relations.
  perform pg_advisory_xact_lock(hashtextextended('friendship:' || least(v_uid, p_player)::text || ':' || greatest(v_uid, p_player)::text, 0));
  select * into f from public.friendships where player_low = least(v_uid, p_player) and player_high = greatest(v_uid, p_player) for update;
  if p_action = 'request' then
    if f.status in ('accepted', 'pending') then
      return jsonb_build_object('player_id', p_player, 'status', private.friendship_status(v_uid, p_player));
    end if;
    perform private.require_visible_player(v_uid, p_player);
    if not private.hit_rate_limit('friend_request:' || v_uid, 60, 86400) then perform private.fail('rate_limited'); end if;
    insert into public.friendships (player_low, player_high, requested_by, status)
      values (least(v_uid, p_player), greatest(v_uid, p_player), v_uid, 'pending')
      on conflict (player_low, player_high) do update set requested_by = excluded.requested_by, status = 'pending', requested_at = now();
  elsif p_action = 'accept' then
    if f.status = 'accepted' then null;
    elsif f.status <> 'pending' or f.status is null then perform private.fail('friendship_not_pending');
    elsif f.requested_by = v_uid then perform private.fail('friendship_not_incoming');
    else update public.friendships set status = 'accepted' where player_low = f.player_low and player_high = f.player_high; end if;
  elsif p_action = 'reject' then
    if f.status = 'pending' and f.requested_by = v_uid then perform private.fail('friendship_not_incoming'); end if;
    if f.status = 'pending' then update public.friendships set status = 'rejected' where player_low = f.player_low and player_high = f.player_high; end if;
  elsif p_action = 'cancel' then
    if f.status = 'pending' and f.requested_by <> v_uid then perform private.fail('friendship_not_outgoing'); end if;
    if f.status = 'pending' then update public.friendships set status = 'cancelled' where player_low = f.player_low and player_high = f.player_high; end if;
  else
    update public.friendships set status = case when status = 'accepted' then 'removed' when requested_by = v_uid then 'cancelled' else 'rejected' end
      where player_low = f.player_low and player_high = f.player_high and status in ('pending', 'accepted');
  end if;
  return jsonb_build_object('player_id', p_player, 'status', private.friendship_status(v_uid, p_player));
end;
$$;

-- Admission uses the existing effective uncertainty (including inactivity),
-- not a new rating formula. 70% is the existing analytics reliability target.
-- At least five ranked games prevents an initial self-assessment from getting
-- automatic admission. Any uncertain player may apply, even outside the band.
create or replace function private.scheduled_admission(p_match uuid, p_player uuid)
returns text language sql stable set search_path = '' as $$
  select case when r.ranked_matches >= 5 and private.reliability(private.effective_sigma(r.sigma, coalesce(r.last_ranked_at, r.created_at), now())) >= 70
    then case when r.mu between m.min_level and m.max_level then 'auto' else 'out_of_range' end else 'approval' end
  from public.scheduled_matches m join public.player_ratings r on r.player_id = p_player where m.id = p_match
$$;

create or replace function private.scheduled_card(p_match uuid, p_viewer uuid, p_player uuid)
returns jsonb language sql stable set search_path = '' as $$
  select private.visible_card(p_viewer, p_player,
    exists (select 1 from public.scheduled_matches m join public.scheduled_match_players sp on sp.match_id = m.id
      where m.id = p_match and m.organizer_id = p_viewer and m.cancelled_at is null
        and sp.player_id = p_player and sp.status in ('pending', 'accepted')))
$$;

create or replace function private.scheduled_json(p_match uuid, p_viewer uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id', m.id, 'client_id', m.client_id, 'organizer', private.scheduled_card(m.id, p_viewer, m.organizer_id),
    'starts_at', m.starts_at, 'city', jsonb_build_object('id', c.id, 'name', c.name),
    'club', case when cl.id is not null then jsonb_build_object('id', cl.id, 'name', cl.name) end,
    'location', m.location, 'match_type', m.match_type, 'min_level', m.min_level, 'max_level', m.max_level, 'note', m.note,
    'status', case when m.cancelled_at is not null then 'cancelled'
       when result.status = 'confirmed' then 'completed'
       when m.result_match_id is not null then 'result_pending'
       when m.starts_at <= now() then 'awaiting_result'
       when seats.n = 4 then 'full' else 'open' end,
    'participants', coalesce((select jsonb_agg(jsonb_build_object('player', private.scheduled_card(m.id, p_viewer, sp.player_id), 'joined_at', sp.joined_at)
       order by sp.player_id <> m.organizer_id, sp.joined_at, sp.player_id) from public.scheduled_match_players sp where sp.match_id = m.id and sp.status = 'accepted'), '[]'::jsonb),
    'applications', coalesce((select jsonb_agg(jsonb_build_object('player', private.scheduled_card(m.id, p_viewer, sp.player_id), 'status', sp.status, 'requested_at', sp.requested_at)
       order by sp.requested_at, sp.player_id) from public.scheduled_match_players sp
       where sp.match_id = m.id and sp.player_id <> m.organizer_id and (m.organizer_id = p_viewer or sp.player_id = p_viewer)), '[]'::jsonb),
    'spots_left', 4 - seats.n, 'admission', jsonb_build_object('min_reliability', 70, 'minimum_ranked_matches', 5),
    'viewer', jsonb_build_object('is_organizer', m.organizer_id = p_viewer, 'participation', coalesce(mine.status, 'none'),
       'can_join', m.cancelled_at is null and m.result_match_id is null and m.starts_at > now() and seats.n < 4
          and coalesce(mine.status, 'none') not in ('accepted', 'pending') and private.scheduled_admission(m.id, p_viewer) <> 'out_of_range',
       'admission', private.scheduled_admission(m.id, p_viewer)),
    'result_match_id', m.result_match_id, 'result_status', result.status)
  from public.scheduled_matches m join public.cities c on c.id = m.city_id
  left join public.clubs cl on cl.id = m.club_id left join public.matches result on result.id = m.result_match_id
  left join public.scheduled_match_players mine on mine.match_id = m.id and mine.player_id = p_viewer
  cross join lateral (select count(*)::integer as n from public.scheduled_match_players sp where sp.match_id = m.id and sp.status = 'accepted') seats
  where m.id = p_match
$$;

create or replace function public.scheduled_match(p_match uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v jsonb;
begin
  perform private.require_active_player(v_uid);
  select private.scheduled_json(m.id, v_uid) into v from public.scheduled_matches m
    where m.id = p_match and (m.cancelled_at is null or m.organizer_id = v_uid
      or exists (select 1 from public.scheduled_match_players where match_id = m.id and player_id = v_uid));
  if v is null then perform private.fail('scheduled_match_not_found'); end if;
  return v;
end;
$$;

create or replace function public.scheduled_matches(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_scope text := coalesce(p ->> 'scope', 'open');
  v_city integer; v_limit integer; v_offset integer; v_items jsonb; v_more boolean; v_accepted boolean := false;
begin
  perform private.require_active_player(v_uid);
  if p is null or private.jtype(p) <> 'object' or v_scope not in ('open', 'mine') then perform private.fail('invalid_request'); end if;
  if p ? 'accepted_only' and private.jtype(p -> 'accepted_only') <> 'boolean' then perform private.fail('invalid_request'); end if;
  v_accepted := coalesce((p ->> 'accepted_only')::boolean, false);
  if v_accepted and v_scope <> 'mine' then perform private.fail('invalid_request'); end if;
  begin
    v_city := (p ->> 'city_id')::integer;
    v_limit := greatest(1, least(coalesce((p ->> 'limit')::integer, 20), 50));
    v_offset := greatest(0, least(coalesce((p ->> 'offset')::integer, 0), 1000));
  exception when invalid_text_representation or numeric_value_out_of_range then perform private.fail('invalid_request'); end;
  with candidates as (
    select m.id, m.starts_at, row_number() over (order by
      case when m.cancelled_at is null and m.result_match_id is null and m.starts_at > now() then 0
           when m.cancelled_at is null and m.result_match_id is null then 1 else 2 end,
      case when m.cancelled_at is null and m.result_match_id is null then m.starts_at end,
      m.starts_at desc, m.id) as rn
    from public.scheduled_matches m where (v_city is null or m.city_id = v_city)
      and case when v_scope = 'mine' then m.organizer_id = v_uid or exists (
        select 1 from public.scheduled_match_players sp where sp.match_id = m.id and sp.player_id = v_uid
          and (sp.status = 'accepted' or (sp.status = 'pending' and not v_accepted)))
      else m.cancelled_at is null and m.result_match_id is null and m.starts_at > now() end
  ) select coalesce(jsonb_agg(private.scheduled_json(id, v_uid) order by rn) filter (where rn <= v_offset + v_limit), '[]'::jsonb),
      coalesce(bool_or(rn > v_offset + v_limit), false) into v_items, v_more
    from candidates where rn > v_offset and rn <= v_offset + v_limit + 1;
  return jsonb_build_object('items', v_items, 'next_offset', case when v_more then v_offset + v_limit end);
end;
$$;

create or replace function public.create_scheduled_match(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_id uuid; v_client uuid; v_starts timestamptz;
  v_city integer; v_club bigint; v_min numeric; v_max numeric; v_location text; v_note text;
begin
  perform private.lock_active_social_players(array[v_uid]);
  if p is null or private.jtype(p) <> 'object' then perform private.fail('invalid_scheduled_match'); end if;
  if private.jtype(p -> 'client_id') <> 'string' then perform private.fail('idempotency_key_required'); end if;
  begin v_client := (p ->> 'client_id')::uuid; exception when invalid_text_representation then perform private.fail('idempotency_key_required'); end;
  if v_client is null then perform private.fail('idempotency_key_required'); end if;
  perform pg_advisory_xact_lock(hashtextextended('create_scheduled_match:' || v_uid::text, 0));
  select id into v_id from public.scheduled_matches where organizer_id = v_uid and client_id = v_client;
  if v_id is not null then return private.scheduled_json(v_id, v_uid); end if;
  if private.jtype(p -> 'starts_at') <> 'string' or private.jtype(p -> 'city_id') <> 'number'
    or private.jtype(p -> 'min_level') <> 'number' or private.jtype(p -> 'max_level') <> 'number'
    or private.jtype(p -> 'location') <> 'string' or private.jtype(p -> 'match_type') <> 'string'
    or (p ? 'club_id' and private.jtype(p -> 'club_id') not in ('number', 'null'))
    or (p ? 'note' and private.jtype(p -> 'note') not in ('string', 'null')) then perform private.fail('invalid_scheduled_match'); end if;
  begin
    v_starts := (p ->> 'starts_at')::timestamptz; v_city := (p ->> 'city_id')::integer;
    v_club := (p ->> 'club_id')::bigint; v_min := (p ->> 'min_level')::numeric; v_max := (p ->> 'max_level')::numeric;
  exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then perform private.fail('invalid_scheduled_match'); end;
  v_location := btrim(coalesce(p ->> 'location', '')); v_note := nullif(btrim(coalesce(p ->> 'note', '')), '');
  if v_starts is null or not isfinite(v_starts) or v_starts <= now() or v_starts > now() + interval '180 days'
    or v_city is null or not exists (select 1 from public.cities where id = v_city)
    or (v_club is not null and not exists (select 1 from public.clubs where id = v_club and city_id = v_city))
    or v_min is null or v_max is null or not (v_min between 0 and 7 and v_max between v_min and 7)
    or coalesce(p ->> 'match_type', '') not in ('ranked', 'friendly')
    or char_length(v_location) not between 2 and 160 or char_length(v_note) > 500 then perform private.fail('invalid_scheduled_match'); end if;
  if not private.hit_rate_limit('create_scheduled_match:' || v_uid, 20, 86400) then perform private.fail('rate_limited'); end if;
  insert into public.scheduled_matches (client_id, organizer_id, starts_at, city_id, club_id, location, match_type, min_level, max_level, note)
    values (v_client, v_uid, v_starts, v_city, v_club, v_location, p ->> 'match_type', v_min, v_max, v_note) returning id into v_id;
  insert into public.scheduled_match_players (match_id, player_id, status, joined_at, decided_at) values (v_id, v_uid, 'accepted', now(), now());
  return private.scheduled_json(v_id, v_uid);
end;
$$;

create or replace function public.join_scheduled_match(p_match uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); m public.scheduled_matches%rowtype; v_status text; v_admission text;
begin
  perform private.lock_active_social_players(array[v_uid]);
  select * into m from public.scheduled_matches where id = p_match for update;
  if not found then perform private.fail('scheduled_match_not_found'); end if;
  select status into v_status from public.scheduled_match_players where match_id = p_match and player_id = v_uid;
  if v_status in ('accepted', 'pending') then return private.scheduled_json(p_match, v_uid); end if;
  if m.cancelled_at is not null or m.result_match_id is not null then perform private.fail('scheduled_match_closed'); end if;
  if m.starts_at <= now() then perform private.fail('scheduled_match_started'); end if;
  if (select count(*) from public.scheduled_match_players where match_id = p_match and status = 'accepted') >= 4 then perform private.fail('scheduled_match_full'); end if;
  v_admission := private.scheduled_admission(p_match, v_uid);
  if v_admission = 'out_of_range' then perform private.fail('level_out_of_range'); end if;
  if not private.hit_rate_limit('join_scheduled_match:' || v_uid, 100, 86400) then perform private.fail('rate_limited'); end if;
  insert into public.scheduled_match_players (match_id, player_id, status, joined_at, decided_at)
    values (p_match, v_uid, case when v_admission = 'auto' then 'accepted' else 'pending' end,
      case when v_admission = 'auto' then now() end, case when v_admission = 'auto' then now() end)
    on conflict (match_id, player_id) do update set status = excluded.status, requested_at = now(), joined_at = excluded.joined_at, decided_at = excluded.decided_at;
  return private.scheduled_json(p_match, v_uid);
end;
$$;

create or replace function public.review_scheduled_application(p_match uuid, p_player uuid, p_decision text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); m public.scheduled_matches%rowtype; v_status text;
begin
  perform private.lock_active_social_players(array[v_uid,p_player]);
  select * into m from public.scheduled_matches where id = p_match for update;
  if not found then perform private.fail('scheduled_match_not_found'); end if;
  if m.organizer_id <> v_uid then perform private.fail('organizer_required'); end if;
  if p_decision is null or p_decision not in ('accepted', 'rejected') then perform private.fail('invalid_request'); end if;
  select status into v_status from public.scheduled_match_players where match_id = p_match and player_id = p_player;
  if v_status = p_decision then return private.scheduled_json(p_match, v_uid); end if;
  if m.cancelled_at is not null or m.result_match_id is not null then perform private.fail('scheduled_match_closed'); end if;
  if m.starts_at <= now() then perform private.fail('scheduled_match_started'); end if;
  if v_status is null then perform private.fail('application_not_found'); end if;
  if v_status <> 'pending' then perform private.fail('application_not_pending'); end if;
  perform private.require_active_player(p_player);
  if p_decision = 'accepted' and (select count(*) from public.scheduled_match_players where match_id = p_match and status = 'accepted') >= 4 then perform private.fail('scheduled_match_full'); end if;
  update public.scheduled_match_players set status = p_decision, decided_at = now(), joined_at = case when p_decision = 'accepted' then now() end
    where match_id = p_match and player_id = p_player;
  return private.scheduled_json(p_match, v_uid);
end;
$$;

create or replace function public.leave_scheduled_match(p_match uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); m public.scheduled_matches%rowtype; v_status text;
begin
  perform private.lock_active_social_players(array[v_uid]);
  select * into m from public.scheduled_matches where id = p_match for update;
  if not found then perform private.fail('scheduled_match_not_found'); end if;
  if m.organizer_id = v_uid then perform private.fail('organizer_cannot_leave'); end if;
  select status into v_status from public.scheduled_match_players where match_id = p_match and player_id = v_uid;
  if v_status is null or v_status in ('withdrawn', 'rejected') or m.cancelled_at is not null then return private.scheduled_json(p_match, v_uid); end if;
  if m.result_match_id is not null then perform private.fail('scheduled_match_closed'); end if;
  if m.starts_at <= now() then perform private.fail('scheduled_match_started'); end if;
  update public.scheduled_match_players set status = 'withdrawn', joined_at = null, decided_at = now() where match_id = p_match and player_id = v_uid;
  return private.scheduled_json(p_match, v_uid);
end;
$$;

create or replace function public.cancel_scheduled_match(p_match uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); m public.scheduled_matches%rowtype;
begin
  perform private.lock_active_social_players(array[v_uid]);
  select * into m from public.scheduled_matches where id = p_match for update;
  if not found then perform private.fail('scheduled_match_not_found'); end if;
  if m.organizer_id <> v_uid then perform private.fail('organizer_required'); end if;
  if m.cancelled_at is not null then return private.scheduled_json(p_match, v_uid); end if;
  if m.result_match_id is not null then perform private.fail('scheduled_match_closed'); end if;
  update public.scheduled_matches set cancelled_at = now() where id = p_match;
  return private.scheduled_json(p_match, v_uid);
end;
$$;

create or replace function public.submit_scheduled_result(p_match uuid, p jsonb, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); m public.scheduled_matches%rowtype;
  v_ids uuid[]; v_locked uuid[]; v_submitted uuid[]; v_input jsonb; v_result jsonb; v_existing uuid;
begin
  -- Lock admitted profiles before the game row (the same order as account
  -- deletion). For a linked replay, deleted teammates must remain valid
  -- tombstones, so only the live caller needs the active-player lock.
  select result_match_id into v_existing from public.scheduled_matches where id=p_match;
  if v_existing is null then
    select coalesce(array_agg(player_id order by player_id),'{}') into v_ids
      from public.scheduled_match_players where match_id=p_match and status='accepted';
    v_locked := v_ids;
    perform private.lock_active_social_players(array[v_uid] || v_ids);
  else
    perform private.lock_active_social_players(array[v_uid]);
  end if;
  if p_idempotency_key is null then perform private.fail('idempotency_key_required'); end if;
  select * into m from public.scheduled_matches where id = p_match for update;
  if not found or not exists (select 1 from public.scheduled_match_players where match_id = p_match and player_id = v_uid and status = 'accepted') then perform private.fail('scheduled_match_not_found'); end if;
  if m.cancelled_at is not null then perform private.fail('scheduled_match_closed'); end if;
  if m.result_match_id is not null then
    -- A lost-response replay must keep working after date/frequency windows
    -- have moved or another participant has deleted their account. Compare
    -- only static canonical input; never re-run mutable admission/date rules.
    begin
      v_input := jsonb_build_object('match_type', p ->> 'match_type', 'format', p ->> 'format',
        'played_at', (p ->> 'played_at')::timestamptz, 'club_id', (p ->> 'club_id')::bigint,
        'players', (select jsonb_agg(jsonb_build_object('player_id', (x ->> 'player_id')::uuid,
          'team', (x ->> 'team')::smallint, 'court_side', x ->> 'court_side') order by (x ->> 'player_id')::uuid)
          from jsonb_array_elements(p -> 'players') x),
        'score', private.validate_score(p ->> 'format', p -> 'sets'));
    exception when others then perform private.fail('scheduled_result_mismatch'); end;
    if v_input is distinct from m.result_input then perform private.fail('scheduled_result_mismatch'); end if;
    return private.match_json(m.result_match_id, v_uid);
  end if;
  if m.starts_at > now() then perform private.fail('scheduled_match_not_started'); end if;
  select array_agg(player_id order by player_id) into v_ids from public.scheduled_match_players where match_id = p_match and status = 'accepted';
  if cardinality(v_ids) <> 4 then perform private.fail('scheduled_match_not_full'); end if;
  -- A join/review begun before starts_at may have waited on the same game row.
  -- Never publish against an admitted profile not included in our ordered
  -- pre-lock set. A refreshed retry can use the new complete lineup.
  if v_ids is distinct from v_locked then perform private.fail('scheduled_lineup_mismatch'); end if;
  begin
    select array_agg((x ->> 'player_id')::uuid order by (x ->> 'player_id')::uuid) into v_submitted from jsonb_array_elements(p -> 'players') x;
  exception when invalid_text_representation or invalid_parameter_value then perform private.fail('scheduled_lineup_mismatch'); end;
  if v_ids is distinct from v_submitted then perform private.fail('scheduled_lineup_mismatch'); end if;
  if p ->> 'match_type' is distinct from m.match_type or (p ->> 'club_id')::bigint is distinct from m.club_id then perform private.fail('scheduled_result_mismatch'); end if;
  -- Existing validator protects format, score, dates, frequency and line-up.
  -- The linked id is excluded from its duplicate check for safe retries.
  v_input := private.validate_match_input(p, v_uid, m.result_match_id);
  if (v_input ->> 'played_at')::timestamptz < m.starts_at then perform private.fail('scheduled_result_mismatch'); end if;
  -- Canonical player ordering makes JSON equality independent of body order.
  v_input := jsonb_set(v_input, '{players}', (select jsonb_agg(jsonb_build_object('player_id', (x ->> 'player_id')::uuid,
    'team', (x ->> 'team')::smallint, 'court_side', x ->> 'court_side') order by (x ->> 'player_id')::uuid)
    from jsonb_array_elements(v_input -> 'players') x));
  -- Reject a header already used for another scored match. Never silently bind
  -- a prior create_match result with an unrelated line-up or score.
  select id into v_existing from public.matches where created_by = v_uid and idempotency_key = p_idempotency_key;
  if v_existing is not null then perform private.fail('scheduled_result_mismatch'); end if;
  v_result := public.create_match(p, p_idempotency_key);
  -- Another simultaneous create using this header may have won the per-user
  -- lock. Verify that return value before binding it to this game.
  if not exists (select 1 from public.matches r where r.id = (v_result ->> 'id')::uuid
      and r.match_type = v_input ->> 'match_type' and r.format = v_input ->> 'format'
      and r.played_at = (v_input ->> 'played_at')::timestamptz and r.club_id is not distinct from (v_input ->> 'club_id')::bigint
      and r.score = v_input -> 'score' -> 'sets')
    or v_ids is distinct from (select array_agg(player_id order by player_id) from public.match_players where match_id = (v_result ->> 'id')::uuid)
    or v_input -> 'players' is distinct from (select jsonb_agg(jsonb_build_object('player_id', player_id, 'team', team, 'court_side', court_side) order by player_id)
      from public.match_players where match_id = (v_result ->> 'id')::uuid)
    or exists (select 1 from public.scheduled_matches where result_match_id = (v_result ->> 'id')::uuid) then
    perform private.fail('scheduled_result_mismatch');
  end if;
  update public.scheduled_matches set result_match_id = (v_result ->> 'id')::uuid, result_input = v_input where id = p_match;
  return private.match_json((v_result ->> 'id')::uuid, v_uid);
end;
$$;

-- Optional metadata lets the new scored-match editor preserve the game's
-- fixed participants/type/club and earliest date. Released clients ignore the
-- added keys; the original serializer and privacy rules remain in place.
do $$
declare v_definition text; v_marker text := '    ''id'', m.id,';
begin
  select pg_get_functiondef('private.match_json(uuid,uuid)'::regprocedure) into v_definition;
  if position(v_marker in v_definition)=0 then raise exception 'scheduled result metadata migration precondition failed'; end if;
  v_definition := replace(v_definition, v_marker,
    v_marker || chr(10) || '    ''scheduled_match_id'', (select sm.id from public.scheduled_matches sm where sm.result_match_id=m.id),' || chr(10) ||
    '    ''scheduled_starts_at'', (select sm.starts_at from public.scheduled_matches sm where sm.result_match_id=m.id),');
  if position('''scheduled_match_id''' in v_definition)=0 then raise exception 'scheduled result metadata migration precondition failed'; end if;
  execute v_definition;
end;
$$;

-- Search retains its set-based compatibility math; new relationships simply
-- extend the previous hidden-profile visibility predicate.
do $$
declare v_definition text;
begin
  select pg_get_functiondef('public.search_players(jsonb)'::regprocedure) into v_definition;
  v_definition := replace(v_definition,
    'and (pr.discoverable or exists (' || chr(10) ||
    '             select 1 from public.match_players a' || chr(10) ||
    '               join public.match_players b on b.match_id = a.match_id and b.player_id = pr.id' || chr(10) ||
    '              where a.player_id = v_uid))',
    'and private.socially_visible(v_uid, pr.id)');
  if position('and private.socially_visible(v_uid, pr.id)' in v_definition) = 0 then
    raise exception 'search visibility migration precondition failed';
  end if;
  execute v_definition;
end;
$$;

-- Defense in depth: deferred constraint catches accidental internal writes too.
create or replace function private.check_scheduled_lineup()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid; m public.scheduled_matches%rowtype;
begin
  v_id := case when tg_table_name = 'scheduled_matches' then (to_jsonb(new) ->> 'id')::uuid
    when tg_op = 'DELETE' then (to_jsonb(old) ->> 'match_id')::uuid else (to_jsonb(new) ->> 'match_id')::uuid end;
  select * into m from public.scheduled_matches where id = v_id;
  if not found then return null; end if;
  if (select count(*) from public.scheduled_match_players where match_id = v_id and status = 'accepted') > 4
    or not exists (select 1 from public.scheduled_match_players where match_id = v_id and player_id = m.organizer_id and status = 'accepted') then
    raise exception using errcode = '23514', message = 'scheduled_lineup_invalid';
  end if;
  if m.result_match_id is not null and (select array_agg(player_id order by player_id) from public.scheduled_match_players where match_id = v_id and status = 'accepted')
    is distinct from (select array_agg(player_id order by player_id) from public.match_players where match_id = m.result_match_id) then
    raise exception using errcode = '23514', message = 'scheduled_lineup_invalid';
  end if;
  return null;
end;
$$;
create constraint trigger scheduled_lineup_check after insert or update on public.scheduled_matches deferrable initially deferred
  for each row execute function private.check_scheduled_lineup();
create constraint trigger scheduled_players_lineup_check after insert or update or delete on public.scheduled_match_players deferrable initially deferred
  for each row execute function private.check_scheduled_lineup();

-- The existing scored-match editor can change teams/positions and correct the
-- score, but cannot substitute a scheduled game's admitted participants.
create or replace function private.check_scheduled_result()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid; m public.scheduled_matches%rowtype;
begin
  v_id := case when tg_table_name = 'matches' then (to_jsonb(new) ->> 'id')::uuid
    when tg_op = 'DELETE' then (to_jsonb(old) ->> 'match_id')::uuid else (to_jsonb(new) ->> 'match_id')::uuid end;
  select * into m from public.scheduled_matches where result_match_id = v_id;
  if not found then return null; end if;
  if (select array_agg(player_id order by player_id) from public.scheduled_match_players where match_id = m.id and status = 'accepted')
      is distinct from (select array_agg(player_id order by player_id) from public.match_players where match_id = v_id)
    or exists (select 1 from public.matches where id = v_id and (match_type <> m.match_type or club_id is distinct from m.club_id or played_at < m.starts_at)) then
    raise exception using errcode = '23514', message = 'scheduled_lineup_invalid';
  end if;
  return null;
end;
$$;
create constraint trigger scheduled_result_check after update on public.matches deferrable initially deferred
  for each row execute function private.check_scheduled_result();
create constraint trigger scheduled_result_players_check after insert or update or delete on public.match_players deferrable initially deferred
  for each row execute function private.check_scheduled_result();

-- Return domain errors during edits as well as enforcing the deferred database
-- constraint. Older clients use update_match and therefore need this check in
-- the shared validator, rather than only in the new scheduled-result RPC.
create or replace function private.validate_scheduled_result_input(p_existing uuid, p jsonb)
returns void language plpgsql stable set search_path = '' as $$
declare m public.scheduled_matches%rowtype; v_ids uuid[];
begin
  select * into m from public.scheduled_matches where result_match_id = p_existing;
  if not found then return; end if;
  select array_agg((x ->> 'player_id')::uuid order by (x ->> 'player_id')::uuid) into v_ids from jsonb_array_elements(p -> 'players') x;
  if v_ids is distinct from (select array_agg(player_id order by player_id) from public.scheduled_match_players where match_id = m.id and status = 'accepted') then
    perform private.fail('scheduled_lineup_mismatch');
  end if;
  if p ->> 'match_type' is distinct from m.match_type or (p ->> 'club_id')::bigint is distinct from m.club_id
    or (p ->> 'played_at')::timestamptz < m.starts_at then perform private.fail('scheduled_result_mismatch'); end if;
end;
$$;
do $$
declare v_definition text;
begin
  select pg_get_functiondef('private.validate_match_input(jsonb,uuid,uuid)'::regprocedure) into v_definition;
  v_definition := replace(v_definition, '  v_score := private.validate_score(v_format, p -> ''sets'');',
    '  perform private.validate_scheduled_result_input(p_existing, p);' || chr(10) || '  v_score := private.validate_score(v_format, p -> ''sets'');');
  if position('private.validate_scheduled_result_input(p_existing, p)' in v_definition) = 0 then raise exception 'match validator migration precondition failed'; end if;
  execute v_definition;
end;
$$;

-- Account deletion must release future seats and close invitations too. A
-- linked played result retains its tombstone participants and confirmations.
create or replace function private.anonymize_social_data()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.deleted_at is null and new.deleted_at is not null then
    -- The service's earlier pending-match cleanup can precede a wait on the
    -- profile lock held by an in-flight result submission. Catch any linked
    -- unconfirmed result that committed during that wait; confirmed history
    -- remains intact with tombstone participants.
    update public.matches r set status='cancelled', closed_at=now()
      where r.status in ('pending','disputed') and exists (
        select 1 from public.scheduled_matches m
          join public.scheduled_match_players sp on sp.match_id=m.id and sp.player_id=new.id
        where m.result_match_id=r.id);
    update public.friendships set status = 'removed' where new.id in (player_low, player_high) and status in ('accepted', 'pending');
    update public.scheduled_matches set cancelled_at = now() where organizer_id = new.id and result_match_id is null and cancelled_at is null;
    update public.scheduled_match_players sp set status = 'withdrawn', joined_at = null, decided_at = now()
      from public.scheduled_matches m where m.id = sp.match_id and sp.player_id = new.id and m.organizer_id <> new.id
        and m.result_match_id is null and sp.status in ('accepted', 'pending');
  end if;
  return new;
end;
$$;
create trigger profiles_social_anonymize after update of deleted_at on public.profiles
  for each row execute function private.anonymize_social_data();

revoke all on function private.socially_visible(uuid, uuid), private.require_visible_player(uuid, uuid), private.friendship_status(uuid, uuid),
  private.scheduled_admission(uuid, uuid), private.scheduled_card(uuid, uuid, uuid), private.scheduled_json(uuid, uuid), private.check_scheduled_lineup(),
  private.check_scheduled_result(), private.anonymize_social_data(), private.visible_card(uuid, uuid, boolean), private.validate_scheduled_result_input(uuid, jsonb),
  private.lock_active_social_players(uuid[])
  from public, anon, authenticated, service_role;
revoke all on function public.friendships(), public.friendship_status(uuid), public.friendship_action(uuid, text), public.scheduled_match(uuid),
  public.scheduled_matches(jsonb), public.create_scheduled_match(jsonb), public.join_scheduled_match(uuid), public.review_scheduled_application(uuid, uuid, text),
  public.leave_scheduled_match(uuid), public.cancel_scheduled_match(uuid), public.submit_scheduled_result(uuid, jsonb, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.friendships(), public.friendship_status(uuid), public.friendship_action(uuid, text), public.scheduled_match(uuid),
  public.scheduled_matches(jsonb), public.create_scheduled_match(jsonb), public.join_scheduled_match(uuid), public.review_scheduled_application(uuid, uuid, text),
  public.leave_scheduled_match(uuid), public.cancel_scheduled_match(uuid), public.submit_scheduled_result(uuid, jsonb, uuid) to authenticated;
