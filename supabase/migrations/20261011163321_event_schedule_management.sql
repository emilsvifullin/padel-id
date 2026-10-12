-- Open sports-event metadata can change without destroying enrollment or
-- altering the sporting format, scoring rules, level eligibility or ratings.
alter table public.sports_events add column metadata_version integer not null default 1 check(metadata_version>=1);

create or replace function private.event_json(p_event uuid,u uuid,details boolean default true) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',e.id,'kind',e.kind,'format',e.format,'title',e.title,'description',e.description,
  'organizer',private.event_card(p_event,u,e.organizer_id),'starts_at',e.starts_at,'duration_minutes',e.duration_minutes,
  'city',jsonb_build_object('id',c.id,'name',c.name),'club',case when cl.id is not null then jsonb_build_object('id',cl.id,'name',cl.name) end,
  'location',e.location,'capacity',e.capacity,'min_level',e.min_level,'max_level',e.max_level,
  'specialization',e.specialization,'price_rub',e.price_rub,'round_count',e.round_count,'points_per_game',e.points_per_game,
  'metadata_version',e.metadata_version,'current_round',e.current_round,'status',e.status,'registered_count',(select count(*) from public.event_registrations r where r.event_id=e.id),
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
create or replace function public.events_catalog(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();v_city integer;v_club bigint;v_organizer uuid;v_kind text;v_scope text;v_upcoming boolean;v_limit int;v_offset int;items jsonb;more boolean;
begin
 perform private.require_active_player(u);
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 begin v_city:=(p->>'city_id')::integer;v_club:=(p->>'club_id')::bigint;v_organizer:=(p->>'organizer_id')::uuid;v_kind:=p->>'kind';v_scope:=coalesce(p->>'scope','upcoming');v_upcoming:=coalesce((p->>'upcoming_only')::boolean,false);
  v_limit:=coalesce((p->>'limit')::int,30);v_offset:=coalesce((p->>'offset')::int,0);
 exception when others then perform private.fail('invalid_request');end;
 if p ? 'upcoming_only' and private.jtype(p->'upcoming_only')<>'boolean' or v_upcoming and v_scope<>'mine' then perform private.fail('invalid_request');end if;
 if v_kind is not null and v_kind not in ('training','tournament') or v_scope not in ('mine','upcoming') or v_limit not between 1 and 50 or v_offset not between 0 and 1000 or v_club<=0 then perform private.fail('invalid_request');end if;
 with rows as(select e.id,row_number() over(order by e.starts_at,e.id) rn from public.sports_events e
  where private.event_access(e.id,u) and (v_city is null or e.city_id=v_city) and (v_club is null or e.club_id=v_club) and (v_kind is null or e.kind=v_kind) and (v_organizer is null or e.organizer_id=v_organizer)
   and (not v_upcoming or (e.status='open' and e.starts_at>now() and (e.organizer_id=u or exists(select 1 from public.event_registrations r where r.event_id=e.id and r.player_id=u and r.status='accepted'))))
   and case when v_scope='upcoming' then e.status='open' and e.starts_at>now()
    else e.organizer_id=u or exists(select 1 from public.event_registrations r where r.event_id=e.id and r.player_id=u) end)
 select coalesce(jsonb_agg(private.event_json(id,u,false) order by rn) filter(where rn<=v_offset+v_limit),'[]'::jsonb),
  coalesce(bool_or(rn>v_offset+v_limit),false) into items,more from rows where rn>v_offset and rn<=v_offset+v_limit+1;
 return jsonb_build_object('items',items,'next_offset',case when more then v_offset+v_limit end);
end $$;

create function public.event_update(p_event uuid,p jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
<<event_values>>
declare u uuid:=private.require_uid();e public.sports_events;version int;city int;club bigint;starts timestamptz;duration int;price int;
 title text;description text;location text;specialty text;candidate jsonb;current_value jsonb;member uuid;
begin
 perform private.lock_event_actor(p_event,u);
 select * into e from public.sports_events where id=p_event for update;
 if e.organizer_id<>u then perform private.fail('organizer_required');end if;
 if e.status<>'open' or e.starts_at<=now() then perform private.fail('event_roster_locked');end if;
 if e.kind='training' then perform private.event_coach(u);end if;
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 if exists(select 1 from jsonb_object_keys(p) k where k not in('version','title','description','starts_at','duration_minutes','city_id','club_id','location','specialization','price_rub')) then perform private.fail('invalid_request');end if;
 begin
  version:=(p->>'version')::int;city:=(p->>'city_id')::int;club:=(p->>'club_id')::bigint;starts:=(p->>'starts_at')::timestamptz;
  duration:=(p->>'duration_minutes')::int;price:=(p->>'price_rub')::int;
 exception when others then perform private.fail('invalid_request');end;
 title:=btrim(p->>'title');description:=btrim(p->>'description');location:=btrim(p->>'location');specialty:=nullif(btrim(p->>'specialization'),'');
 if version is null or version<1 or city is null or starts is null or duration is null
  or starts<=now() or starts>now()+interval '180 days' or duration not between 30 and 240
  or coalesce(char_length(title),0) not between 2 and 100 or private.jtype(p->'description')<>'string' or char_length(description)>1200
  or coalesce(char_length(location),0) not between 2 and 160 or char_length(specialty)>160 or price not between 0 and 100000
  or (e.kind='tournament' and specialty is not null)
 then perform private.fail('invalid_request');end if;
 if not exists(select 1 from public.cities where id=city) then perform private.fail('city_not_found');end if;
 if club is not null and not exists(select 1 from public.clubs where id=club and city_id=city) then perform private.fail('club_not_found');end if;
 candidate:=jsonb_build_object('title',title,'description',description,'starts_at',starts,'duration',duration,'city',city,'club',club,'location',location,'specialization',specialty,'price',price);
 current_value:=jsonb_build_object('title',e.title,'description',e.description,'starts_at',e.starts_at,'duration',e.duration_minutes,'city',e.city_id,'club',e.club_id,'location',e.location,'specialization',e.specialization,'price',e.price_rub);
 -- Replay after a lost response is safe only for this exact prior version and
 -- canonical payload. A divergent stale update is never allowed to overwrite it.
 if version<>e.metadata_version then
  if e.metadata_version-1=version and candidate=current_value then return private.event_json(p_event,u);end if;
  perform private.fail('event_version_conflict');
 end if;
 if candidate=current_value then return private.event_json(p_event,u);end if;
 if not private.hit_rate_limit('event_edit:'||u,60,3600) then perform private.fail('rate_limited');end if;
 update public.sports_events set title=event_values.title,description=event_values.description,starts_at=starts,duration_minutes=duration,city_id=city,club_id=club,
  location=event_values.location,specialization=specialty,price_rub=price,metadata_version=metadata_version+1 where id=p_event;
 for member in select player_id from public.event_registrations where event_id=p_event loop
  perform private.notify_social(member,u,'event','Обновлены условия события',p_event);
 end loop;
 return private.event_json(p_event,u);
end $$;
revoke all on function public.event_update(uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.event_update(uuid,jsonb) to authenticated;
