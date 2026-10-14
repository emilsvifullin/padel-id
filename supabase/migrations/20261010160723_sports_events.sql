-- Sports events are independent from canonical matches and the rating engine.
-- Tournament point scores become standings only after all four players confirm.
create table public.sports_events (
 id uuid primary key default gen_random_uuid(), organizer_id uuid not null references public.profiles(id),
 client_id uuid not null, creation_payload jsonb not null,
 kind text not null check(kind in ('training','tournament')),
 format text not null check(format in ('individual','group','americano','mexicano','king_court','round_robin')),
 title text not null check(char_length(title) between 2 and 100), description text not null check(char_length(description)<=1200),
 starts_at timestamptz not null, duration_minutes integer not null check(duration_minutes between 30 and 240),
 city_id integer not null references public.cities(id), club_id bigint references public.clubs(id),
 location text not null check(char_length(location) between 2 and 160),
 capacity integer not null check(capacity between 1 and 16),min_level numeric not null check(min_level between 0 and 7),
 max_level numeric not null check(max_level between 0 and 7 and max_level>=min_level),
 specialization text check(char_length(specialization)<=160), price_rub integer check(price_rub between 0 and 100000),
 round_count integer not null check(round_count between 1 and 16), points_per_game integer not null check(points_per_game between 8 and 64),
 current_round integer not null default 0, status text not null default 'open' check(status in ('open','running','completed','cancelled')),
 created_at timestamptz not null default now(),unique(organizer_id,client_id),
 check((kind='training' and ((format='individual' and capacity=1) or (format='group' and capacity>=2)))
   or (kind='tournament' and format in ('americano','mexicano','king_court','round_robin') and capacity in (4,8,12,16)
     and (format<>'americano' or capacity in (4,8))))
);
create index sports_events_catalog_idx on public.sports_events(city_id,kind,starts_at,id);
create index sports_events_organizer_idx on public.sports_events(organizer_id,created_at desc);
create table public.event_registrations (
 event_id uuid not null references public.sports_events(id) on delete cascade,player_id uuid not null references public.profiles(id),
 team_id uuid not null default gen_random_uuid(),status text not null check(status in ('invited','accepted')),
 joined_at timestamptz not null default now(),primary key(event_id,player_id)
);
create index event_registrations_player_idx on public.event_registrations(player_id,event_id);
create index event_registrations_team_idx on public.event_registrations(event_id,team_id);
create table public.event_rounds (
 event_id uuid not null references public.sports_events(id) on delete cascade,number integer not null,
 created_at timestamptz not null default now(), primary key(event_id,number)
);
create table public.event_games (
 id uuid primary key default gen_random_uuid(),event_id uuid not null,round_number integer not null,court integer not null,
 player1 uuid not null references public.profiles(id),player2 uuid not null references public.profiles(id),
 player3 uuid not null references public.profiles(id),player4 uuid not null references public.profiles(id),
 points1 integer,points2 integer,version integer not null default 1,confirmed_at timestamptz,
 foreign key(event_id,round_number) references public.event_rounds(event_id,number) on delete cascade,
 unique(event_id,round_number,court),
 check(player1<>player2 and player1<>player3 and player1<>player4 and player2<>player3 and player2<>player4 and player3<>player4),
 check((points1 is null)=(points2 is null)),check(points1 between 0 and 64 and points2 between 0 and 64),
 check(confirmed_at is null or points1 is not null)
);
create index event_games_player1_idx on public.event_games(player1);
create index event_games_player2_idx on public.event_games(player2);
create index event_games_player3_idx on public.event_games(player3);
create index event_games_player4_idx on public.event_games(player4);
create table public.event_game_confirmations (
 game_id uuid not null references public.event_games(id) on delete cascade,player_id uuid not null references public.profiles(id),
 version integer not null,confirmed_at timestamptz not null default now(),primary key(game_id,player_id)
);
create index event_game_confirmations_player_idx on public.event_game_confirmations(player_id);
do $$ declare t text;begin foreach t in array array['sports_events','event_registrations','event_rounds','event_games','event_game_confirmations'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy "no direct access" on public.%I as restrictive for all to anon,authenticated using(false) with check(false)',t);
 execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
end loop;end $$;

create function private.event_access(p_event uuid,u uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.sports_events e join public.profiles pr on pr.id=e.organizer_id
  where e.id=p_event and pr.deleted_at is null and not private.blocked(u,e.organizer_id))
$$;
create function private.require_event(p_event uuid,u uuid) returns void language plpgsql stable set search_path='' as $$
begin if not private.event_access(p_event,u) then perform private.fail('event_not_found');end if;end $$;
-- Player/profile locks always precede the event row lock, matching account cleanup.
create function private.lock_event_actor(p_event uuid,u uuid,other uuid default null) returns void language plpgsql set search_path='' as $$
declare owner uuid;
begin
 perform private.require_event(p_event,u);
 select organizer_id into owner from public.sports_events where id=p_event;
 perform private.lock_active_social_players(array_remove(array[u,owner,other],null));
 perform private.require_event(p_event,u);
end $$;
create function private.event_coach(owner uuid) returns void language plpgsql stable set search_path='' as $$
begin if not exists(select 1 from public.coach_applications c join public.profiles pr on pr.id=c.player_id
 where c.player_id=owner and c.status='approved' and pr.is_coach and pr.deleted_at is null) then perform private.fail('event_coach_required');end if;end $$;

-- Hidden players are revealed only to their organizer/accepted co-participants;
-- an invitation does not grant public or shared-event profile visibility.
create function private.event_card(p_event uuid,u uuid,p_player uuid) returns jsonb language sql stable set search_path='' as $$
 select private.visible_card(u,p_player,exists(select 1 from public.sports_events e where e.id=p_event and
  ((e.organizer_id=u and exists(select 1 from public.event_registrations r where r.event_id=p_event and r.player_id=p_player and r.status='accepted'))
   or (exists(select 1 from public.event_registrations v where v.event_id=p_event and v.player_id=u and v.status='accepted')
    and (e.organizer_id=p_player or exists(select 1 from public.event_registrations r where r.event_id=p_event and r.player_id=p_player and r.status='accepted'))))))
$$;
create function private.event_standings(p_event uuid,u uuid) returns jsonb language sql stable set search_path='' as $$
 with e as(select * from public.sports_events where id=p_event),
 contributions as(
  select g.*,v.player,v.points_for,v.points_against from public.event_games g,
  lateral(values(g.player1,g.points1,g.points2),(g.player2,g.points1,g.points2),
    (g.player3,g.points2,g.points1),(g.player4,g.points2,g.points1)) v(player,points_for,points_against)
  where g.event_id=p_event and g.confirmed_at is not null
 ), individual as(
  select r.player_id,r.team_id,coalesce(sum(c.points_for),0)::integer points,
   count(c.id)::integer played,count(c.id) filter(where c.points_for>c.points_against)::integer wins,
   coalesce(sum(c.points_for-c.points_against),0)::integer difference,
   min(case when c.round_number=(select coalesce(max(r.number),0) from public.event_rounds r where r.event_id=p_event and not exists(select 1 from public.event_games pending where pending.event_id=p_event and pending.round_number=r.number and pending.confirmed_at is null)) then c.court*2+case when c.points_for>c.points_against then 0 else 1 end end) final_court
  from public.event_registrations r left join contributions c on c.player=r.player_id
  where r.event_id=p_event and r.status='accepted' group by r.player_id,r.team_id
 ), entries as(
  select case when (select format from e)='round_robin' then team_id else player_id end entry_id,
   array_agg(player_id order by player_id) players,
   case when (select format from e)='round_robin' then sum(points)/2 else sum(points) end points,
   case when (select format from e)='round_robin' then sum(played)/2 else sum(played) end played,
   case when (select format from e)='round_robin' then sum(wins)/2 else sum(wins) end wins,
   case when (select format from e)='round_robin' then sum(difference)/2 else sum(difference) end difference,min(final_court) final_court
  from individual group by case when (select format from e)='round_robin' then team_id else player_id end
 ), ranked as(select *,dense_rank() over(order by
  case when (select format from e)='king_court' then final_court end asc nulls last,
  points desc,wins desc,difference desc) position from entries)
 select coalesce(jsonb_agg(jsonb_build_object('id',entry_id,'rank',position,'points',points,'played',played,'wins',wins,
  'point_difference',difference,'players',(select jsonb_agg(private.event_card(p_event,u,p) order by p) from unnest(players) p))
  order by position,entry_id),'[]'::jsonb) from ranked
$$;
create function private.event_json(p_event uuid,u uuid,details boolean default true) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',e.id,'kind',e.kind,'format',e.format,'title',e.title,'description',e.description,
  'organizer',private.event_card(p_event,u,e.organizer_id),'starts_at',e.starts_at,'duration_minutes',e.duration_minutes,
  'city',jsonb_build_object('id',c.id,'name',c.name),'club',case when cl.id is not null then jsonb_build_object('id',cl.id,'name',cl.name) end,
  'location',e.location,'capacity',e.capacity,'min_level',e.min_level,'max_level',e.max_level,
  'specialization',e.specialization,'price_rub',e.price_rub,'round_count',e.round_count,'points_per_game',e.points_per_game,
  'current_round',e.current_round,'status',e.status,'registered_count',(select count(*) from public.event_registrations r where r.event_id=e.id),
  'viewer',jsonb_build_object('is_organizer',e.organizer_id=u,'registration',(select status from public.event_registrations where event_id=e.id and player_id=u)),
  'registrations',case when details then(select coalesce(jsonb_agg(jsonb_build_object('player',private.event_card(p_event,u,r.player_id),
    'team_id',r.team_id,'status',r.status) order by r.joined_at,r.player_id),'[]'::jsonb) from public.event_registrations r where r.event_id=e.id) else '[]'::jsonb end,
  'games',case when details then(select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'round',g.round_number,'court',g.court,
   'team1',jsonb_build_array(private.event_card(p_event,u,g.player1),private.event_card(p_event,u,g.player2)),
   'team2',jsonb_build_array(private.event_card(p_event,u,g.player3),private.event_card(p_event,u,g.player4)),
   'points1',g.points1,'points2',g.points2,'version',g.version,'confirmed',g.confirmed_at is not null,
   'confirmations',(select coalesce(jsonb_agg(player_id order by player_id),'[]'::jsonb) from public.event_game_confirmations where game_id=g.id and version=g.version))
   order by g.round_number,g.court),'[]'::jsonb) from public.event_games g where g.event_id=e.id) else '[]'::jsonb end,
  'standings',case when details and e.kind='tournament' then private.event_standings(e.id,u) else '[]'::jsonb end)
 from public.sports_events e join public.cities c on c.id=e.city_id left join public.clubs cl on cl.id=e.club_id where e.id=p_event
$$;
create function public.event_detail(p_event uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin perform private.require_active_player(u);perform private.require_event(p_event,u);return private.event_json(p_event,u);end $$;
create function public.events_catalog(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();v_city integer;v_kind text;v_scope text;v_limit int;v_offset int;items jsonb;more boolean;
begin
 perform private.require_active_player(u);
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 begin v_city:=(p->>'city_id')::integer;v_kind:=p->>'kind';v_scope:=coalesce(p->>'scope','upcoming');
  v_limit:=coalesce((p->>'limit')::int,30);v_offset:=coalesce((p->>'offset')::int,0);
 exception when others then perform private.fail('invalid_request');end;
 if v_kind is not null and v_kind not in ('training','tournament') or v_scope not in ('mine','upcoming') or v_limit not between 1 and 50 or v_offset not between 0 and 1000 then perform private.fail('invalid_request');end if;
 with rows as(select e.id,row_number() over(order by e.starts_at,e.id) rn from public.sports_events e
  where private.event_access(e.id,u) and (v_city is null or e.city_id=v_city) and (v_kind is null or e.kind=v_kind)
   and case when v_scope='upcoming' then e.status='open' and e.starts_at>now()
    else e.organizer_id=u or exists(select 1 from public.event_registrations r where r.event_id=e.id and r.player_id=u) end)
 select coalesce(jsonb_agg(private.event_json(id,u,false) order by rn) filter(where rn<=v_offset+v_limit),'[]'::jsonb),
  coalesce(bool_or(rn>v_offset+v_limit),false) into items,more from rows where rn>v_offset and rn<=v_offset+v_limit+1;
 return jsonb_build_object('items',items,'next_offset',case when more then v_offset+v_limit end);
end $$;

create function public.create_event(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();e public.sports_events;client uuid;city integer;club bigint;starts timestamptz;duration int;
 kind text;fmt text;cap int;rounds int;target int;lo numeric;hi numeric;price int;specialty text;
begin
 perform private.lock_active_social_players(array[u]);
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 begin
  client:=(p->>'client_id')::uuid;city:=(p->>'city_id')::integer;club:=(p->>'club_id')::bigint;starts:=(p->>'starts_at')::timestamptz;
  duration:=(p->>'duration_minutes')::integer;cap:=(p->>'capacity')::integer;lo:=(p->>'min_level')::numeric;hi:=(p->>'max_level')::numeric;
  rounds:=coalesce((p->>'round_count')::int,5);target:=coalesce((p->>'points_per_game')::int,32);price:=(p->>'price_rub')::int;
 exception when others then perform private.fail('invalid_request');end;
 if client is null then perform private.fail('invalid_request');end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text||':'||client::text,0));
 select * into e from public.sports_events where organizer_id=u and client_id=client;
 if found then
  if e.creation_payload<>p then perform private.fail('event_version_conflict');end if;
  return private.event_json(e.id,u);
 end if;
 kind:=p->>'kind';fmt:=p->>'format';specialty:=nullif(btrim(p->>'specialization'),'');
 if client is null or city is null or starts is null or duration is null or cap is null or lo is null or hi is null
  or starts<=now() or starts>now()+interval '180 days' or duration not between 30 and 240
  or cap not between 1 and 16 or lo not between 0 and 7 or hi not between lo and 7 or rounds not between 1 and 16 or target not between 8 and 64
  or coalesce(char_length(btrim(p->>'title')),0) not between 2 and 100 or private.jtype(p->'description')<>'string'
  or char_length(p->>'description')>1200 or coalesce(char_length(btrim(p->>'location')),0) not between 2 and 160
  or char_length(specialty)>160 or price not between 0 and 100000
  or kind is null or kind not in ('training','tournament') or fmt is null
 then perform private.fail('invalid_request');end if;
 if kind='training' then
  perform private.event_coach(u);
  if not ((fmt='individual' and cap=1) or (fmt='group' and cap>=2)) then perform private.fail('invalid_request');end if;
  rounds:=1;
 else
  if fmt not in ('americano','mexicano','king_court','round_robin') or cap not in (4,8,12,16)
   or fmt='americano' and cap not in (4,8) then perform private.fail('event_format_roster');end if;
  if fmt='americano' then rounds:=cap-1;elsif fmt='round_robin' then rounds:=cap/2-1;end if;
 end if;
 if not exists(select 1 from public.cities where id=city) then perform private.fail('city_not_found');end if;
 if club is not null and not exists(select 1 from public.clubs where id=club and city_id=city) then perform private.fail('club_not_found');end if;
 if not private.hit_rate_limit('event_create:'||u,20,86400) then perform private.fail('rate_limited');end if;
 insert into public.sports_events(organizer_id,client_id,creation_payload,kind,format,title,description,starts_at,duration_minutes,city_id,club_id,
  location,capacity,min_level,max_level,specialization,price_rub,round_count,points_per_game)
 values(u,client,p,kind,fmt,btrim(p->>'title'),p->>'description',starts,duration,city,club,btrim(p->>'location'),cap,lo,hi,specialty,price,rounds,target) returning * into e;
 return private.event_json(e.id,u);
end $$;

create function public.event_register(p_event uuid,p_partner uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();e public.sports_events;r public.event_registrations;counted int;team uuid:=gen_random_uuid();rating_mu float;reliable int;ranked int;
begin
 perform private.lock_event_actor(p_event,u,p_partner);
 select * into e from public.sports_events where id=p_event for update;
 if e.status<>'open' then perform private.fail('event_closed');end if;
 if e.starts_at<=now() then perform private.fail('event_roster_locked');end if;
 if e.kind='training' then perform private.event_coach(e.organizer_id);end if;
 if u=e.organizer_id and e.kind='training' then perform private.fail('forbidden');end if;
 select * into r from public.event_registrations where event_id=p_event and player_id=u;
 if found then
  if p_partner is not null then
   if not exists(select 1 from public.event_registrations where event_id=p_event and player_id=p_partner and team_id=r.team_id) then perform private.fail('event_partner_unavailable');end if;
  end if;
  if r.status='invited' then
   if exists(select 1 from public.event_registrations peer where peer.event_id=p_event and peer.team_id=r.team_id and private.blocked(u,peer.player_id)) then perform private.fail('event_partner_unavailable');end if;
   select pr.mu,private.reliability(private.effective_sigma(pr.sigma,coalesce(pr.last_ranked_at,pr.created_at),now())),pr.ranked_matches into rating_mu,reliable,ranked from public.player_ratings pr where pr.player_id=u;
   if reliable>=70 and ranked>=5 and (rating_mu<e.min_level or rating_mu>e.max_level) then perform private.fail('level_out_of_range');end if;
   update public.event_registrations set status='accepted' where event_id=p_event and player_id=u;
  end if;
  return private.event_json(p_event,u);
 end if;
 select pr.mu,private.reliability(private.effective_sigma(pr.sigma,coalesce(pr.last_ranked_at,pr.created_at),now())),pr.ranked_matches into rating_mu,reliable,ranked from public.player_ratings pr where pr.player_id=u;
 if reliable>=70 and ranked>=5 and (rating_mu<e.min_level or rating_mu>e.max_level) then perform private.fail('level_out_of_range');end if;
 select count(*) into counted from public.event_registrations where event_id=p_event;
 if e.format='round_robin' then
  if p_partner is null or p_partner=u or p_partner=e.organizer_id and e.kind='training' then perform private.fail('event_partner_unavailable');end if;
  if not private.socially_visible(u,p_partner) or private.blocked(e.organizer_id,p_partner) or exists(select 1 from public.event_registrations where event_id=p_event and player_id=p_partner) then perform private.fail('event_partner_unavailable');end if;
  if counted+2>e.capacity then perform private.fail('event_full');end if;
  insert into public.event_registrations(event_id,player_id,team_id,status) values(p_event,u,team,'accepted'),(p_event,p_partner,team,'invited');
  perform private.notify_social(p_partner,u,'event','Приглашение в пару на турнир',p_event);
 else
  if p_partner is not null then perform private.fail('invalid_request');end if;
  if counted>=e.capacity then perform private.fail('event_full');end if;
  insert into public.event_registrations(event_id,player_id,team_id,status) values(p_event,u,team,'accepted');
 end if;
 perform private.notify_social(e.organizer_id,u,'event','Новая запись на событие',p_event);
 return private.event_json(p_event,u);
end $$;

create function public.event_manage(p_event uuid,p_action text,p_player uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();e public.sports_events;team uuid;member uuid;
begin
 perform private.lock_event_actor(p_event,u);
 select * into e from public.sports_events where id=p_event for update;
 if p_action not in ('leave','remove','cancel','complete') or p_action is null then perform private.fail('invalid_request');end if;
 if p_action<>'leave' and e.organizer_id<>u then perform private.fail('organizer_required');end if;
 if p_action='cancel' then
  if e.status='completed' then perform private.fail('event_closed');end if;
  if e.status<>'cancelled' then
   update public.sports_events set status='cancelled' where id=p_event;
   for member in select player_id from public.event_registrations where event_id=p_event loop
    perform private.notify_social(member,u,'event','Событие отменено',p_event);
   end loop;
  end if;
 elsif p_action='complete' then
  if e.kind<>'training' or e.status not in ('open','completed') then perform private.fail('event_closed');end if;
  if e.starts_at+make_interval(mins=>e.duration_minutes)>now() then perform private.fail('event_not_started');end if;
  update public.sports_events set status='completed' where id=p_event;
 else
  if e.status<>'open' or e.starts_at<=now() then perform private.fail('event_roster_locked');end if;
  member:=case when p_action='leave' then u else p_player end;
  if member is null then perform private.fail('invalid_request');end if;
  select team_id into team from public.event_registrations where event_id=p_event and player_id=member;
  if team is not null then
   for member in select player_id from public.event_registrations where event_id=p_event and
     (player_id=member or (e.format='round_robin' and team_id=team)) loop
    perform private.notify_social(member,u,'event','Запись на событие отменена',p_event);
   end loop;
   delete from public.event_registrations where event_id=p_event and (player_id=case when p_action='leave' then u else p_player end or (e.format='round_robin' and team_id=team));
  end if;
 end if;
 return private.event_json(p_event,u);
end $$;

-- Proven whist schedules: every partnership appears once and every opposing
-- pair twice across the complete 4/8-player Americano. Other sizes are rejected.
create function private.americano_schedule(n integer) returns jsonb language plpgsql immutable set search_path='' as $$
begin
 if n=4 then return '[[[0,1,2,3]],[[0,2,1,3]],[[0,3,1,2]]]'::jsonb;end if;
 if n=8 then return '[[[0,1,2,3],[4,5,6,7]],[[0,4,2,6],[1,5,3,7]],[[0,3,5,6],[1,2,4,7]],[[0,2,5,7],[1,3,4,6]],[[0,6,1,7],[2,4,3,5]],[[0,5,1,4],[2,7,3,6]],[[0,7,3,4],[1,6,2,5]]]'::jsonb;end if;
 perform private.fail('event_format_roster');return null;
end $$;
create function private.event_add_game(p_event uuid,r integer,c integer,players uuid[]) returns void language plpgsql set search_path='' as $$
begin
 if cardinality(players)<>4 or (select count(distinct x) from unnest(players) x)<>4 then perform private.fail('event_format_roster');end if;
 insert into public.event_games(event_id,round_number,court,player1,player2,player3,player4) values(p_event,r,c,players[1],players[2],players[3],players[4]);
end $$;
create function public.event_generate_round(p_event uuid,p_expected_round integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();e public.sports_events;roster uuid[];teams uuid[];rotated uuid[];pairs uuid[];
 r int;n int;c int;i int;nt int;idx jsonb;g public.event_games;ranked jsonb;target int;winner uuid[];loser uuid[];
begin
 perform private.lock_event_actor(p_event,u);
 select * into e from public.sports_events where id=p_event for update;
 if e.organizer_id<>u then perform private.fail('organizer_required');end if;
 if e.kind<>'tournament' or e.status not in ('open','running') then perform private.fail('event_closed');end if;
 if e.starts_at>now() then perform private.fail('event_not_started');end if;
 if p_expected_round is null or p_expected_round<>e.current_round then perform private.fail('event_version_conflict');end if;
 if e.current_round>=e.round_count then perform private.fail('event_closed');end if;
 if exists(select 1 from public.event_games where event_id=p_event and round_number=e.current_round and confirmed_at is null) then perform private.fail('event_round_pending');end if;
 select array_agg(r.player_id order by r.joined_at,r.player_id) into roster from public.event_registrations r join public.profiles pr on pr.id=r.player_id
 where r.event_id=p_event and r.status='accepted' and pr.deleted_at is null;
 n:=cardinality(roster);
 if n is null or n<>e.capacity or n%4<>0 or exists(select 1 from public.event_registrations where event_id=p_event and status<>'accepted') then perform private.fail('event_format_roster');end if;
 r:=e.current_round+1;
 insert into public.event_rounds(event_id,number) values(p_event,r);
 if e.format='americano' then
  c:=0;
  for idx in select value from jsonb_array_elements(private.americano_schedule(n)->(r-1)) loop
   c:=c+1;perform private.event_add_game(p_event,r,c,array[roster[(idx->>0)::int+1],roster[(idx->>1)::int+1],roster[(idx->>2)::int+1],roster[(idx->>3)::int+1]]);
  end loop;
 elsif e.format='round_robin' then
  select array_agg(team_id order by joined,team_id) into teams from(select team_id,min(joined_at) joined,count(*) amount from public.event_registrations where event_id=p_event group by team_id) t;
  if exists(select 1 from public.event_registrations where event_id=p_event group by team_id having count(*)<>2) then perform private.fail('event_format_roster');end if;
  nt:=cardinality(teams);rotated:=teams;
  if r>1 then for i in 2..r loop rotated:=array[rotated[1],rotated[nt]]||rotated[2:nt-1];end loop;end if;
  for c in 1..nt/2 loop
   select array_agg(player_id order by team_slot,player_id) into pairs from(
    select player_id,case when team_id=rotated[c] then 1 else 2 end team_slot from public.event_registrations
    where event_id=p_event and team_id in (rotated[c],rotated[nt+1-c])) p;
   perform private.event_add_game(p_event,r,c,pairs);
  end loop;
 elsif e.format='king_court' and r>1 then
  -- Winners move one court towards court 1, losers one away. Boundary pairs
  -- remain at the boundary; every court still has exactly two fixed pairs.
  for c in 1..n/4 loop
   pairs:='{}';
   for g in select * from public.event_games where event_id=p_event and round_number=r-1 order by court loop
    winner:=case when g.points1>g.points2 then array[g.player1,g.player2] else array[g.player3,g.player4] end;
    loser:=case when g.points1>g.points2 then array[g.player3,g.player4] else array[g.player1,g.player2] end;
    if greatest(1,g.court-1)=c then pairs:=pairs||winner;end if;
    if least(n/4,g.court+1)=c then pairs:=pairs||loser;end if;
   end loop;
   perform private.event_add_game(p_event,r,c,pairs);
  end loop;
 else
  if e.format='mexicano' and r>1 then
   ranked:=private.event_standings(p_event,u);
   select array_agg((x.value->'players'->0->>'id')::uuid order by x.ord) into roster from jsonb_array_elements(ranked) with ordinality x(value,ord);
  end if;
  for c in 1..n/4 loop
   i:=(c-1)*4;
   -- Mexicano balances the leading and trailing player of each ranking group.
   if e.format='mexicano' then pairs:=array[roster[i+1],roster[i+4],roster[i+2],roster[i+3]];
   else pairs:=roster[i+1:i+4];end if;
   perform private.event_add_game(p_event,r,c,pairs);
  end loop;
 end if;
 update public.sports_events set current_round=r,status='running' where id=p_event;
 return private.event_json(p_event,u);
end $$;

create function public.event_game_score(p_event uuid,p_game uuid,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();e public.sports_events;g public.event_games;a int;b int;v int;player uuid;
begin
 perform private.lock_event_actor(p_event,u);
 select * into e from public.sports_events where id=p_event for update;
 if e.status<>'running' then perform private.fail('event_closed');end if;
 select * into g from public.event_games where id=p_game and event_id=p_event for update;
 if not found then perform private.fail('event_not_found');end if;
 if u<>e.organizer_id and not u=any(array[g.player1,g.player2,g.player3,g.player4]) then perform private.fail('event_not_participant');end if;
 if g.confirmed_at is not null then perform private.fail('event_game_confirmed');end if;
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 begin a:=(p->>'points1')::int;b:=(p->>'points2')::int;v:=(p->>'version')::int;exception when others then perform private.fail('event_invalid_points');end;
 if a is null or b is null or a<0 or b<0 or a+b<>e.points_per_game or e.format='king_court' and a=b then perform private.fail('event_invalid_points');end if;
 -- A replay of the identical score after an uncertain response is safe.
 if g.points1=a and g.points2=b and (v=g.version or v=g.version-1) then return private.event_json(p_event,u);end if;
 if v is null or v<>g.version then perform private.fail('event_version_conflict');end if;
 delete from public.event_game_confirmations where game_id=p_game;
 update public.event_games set points1=a,points2=b,version=version+1 where id=p_game;
 foreach player in array array[g.player1,g.player2,g.player3,g.player4] loop
  perform private.notify_social(player,u,'event','Подтвердите счёт раунда турнира',p_event);
 end loop;
 return private.event_json(p_event,u);
end $$;
create function public.event_game_confirm(p_event uuid,p_game uuid,p_version integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();e public.sports_events;g public.event_games;
begin
 perform private.lock_event_actor(p_event,u);
 select * into e from public.sports_events where id=p_event for update;
 if e.status not in ('running','completed') then perform private.fail('event_closed');end if;
 select * into g from public.event_games where id=p_game and event_id=p_event for update;
 if not found then perform private.fail('event_not_found');end if;
 if not u=any(array[g.player1,g.player2,g.player3,g.player4]) then perform private.fail('event_not_participant');end if;
 if p_version is null or p_version<>g.version then perform private.fail('event_version_conflict');end if;
 if g.points1 is null then perform private.fail('event_invalid_points');end if;
 insert into public.event_game_confirmations(game_id,player_id,version) values(p_game,u,p_version) on conflict do nothing;
 if (select count(*) from public.event_game_confirmations where game_id=p_game and version=g.version)=4 then
  update public.event_games set confirmed_at=coalesce(confirmed_at,now()) where id=p_game;
  if e.current_round=e.round_count and not exists(select 1 from public.event_games where event_id=p_event and confirmed_at is null) then
   update public.sports_events set status='completed' where id=p_event;
  end if;
 end if;
 return private.event_json(p_event,u);
end $$;

create function private.anonymize_event_data() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.deleted_at is null and new.deleted_at is not null then
  update public.sports_events set status='cancelled',title='Событие отменено',description='',specialization=null,location='Место удалено',creation_payload='{}'
   where organizer_id=new.id;
  update public.sports_events set status='cancelled' where status='running' and id in(select event_id from public.event_registrations where player_id=new.id);
  delete from public.event_registrations r using public.sports_events e where r.event_id=e.id and e.status='open' and
   (r.player_id=new.id or e.format='round_robin' and exists(select 1 from public.event_registrations p where p.event_id=r.event_id and p.player_id=new.id and p.team_id=r.team_id));
 elsif old.is_coach and not new.is_coach then
  update public.sports_events set status='cancelled' where organizer_id=new.id and kind='training' and status in ('open','running');
 end if;
 return new;
end $$;
create trigger profiles_events_anonymize after update of deleted_at,is_coach on public.profiles for each row execute function private.anonymize_event_data();

do $$ declare f record;begin
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private'
  and p.proname=any(array['event_access','require_event','lock_event_actor','event_coach','event_card','event_standings','event_json','americano_schedule','event_add_game','anonymize_event_data']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
 end loop;
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname=any(array['events_catalog','event_detail','create_event','event_register','event_manage','event_generate_round','event_game_score','event_game_confirm']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
  execute format('grant execute on function %s to authenticated',f.sig);
 end loop;
end $$;
