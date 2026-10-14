-- Curated club information; community-created club IDs and existing references stay intact.
-- No synthetic court availability, payment or reservation is created by this migration.
alter table public.clubs
 add column description text not null default '' check(char_length(description)<=2000),
 add column address text check(char_length(address) between 2 and 300),
 add column latitude double precision check(latitude between -90 and 90),
 add column longitude double precision check(longitude between -180 and 180),
 add column photo_urls text[] not null default '{}' check(cardinality(photo_urls)<=12),
 add column amenities text[] not null default '{}' check(cardinality(amenities)<=24),
 add column contact_phone text check(char_length(contact_phone) between 5 and 32 and contact_phone ~ '^[+0-9 ()-]+$'),
 add column website_url text,
 add column booking_url text,
 add column booking_verified_at timestamptz,
 add column metadata_version integer not null default 1 check(metadata_version>0),
 add column updated_at timestamptz not null default now(),
 add constraint clubs_coordinates_pair check((latitude is null)=(longitude is null)),
 add constraint clubs_booking_verification check((booking_url is null)=(booking_verified_at is null));

create table public.club_courts (
 id uuid primary key,
 club_id bigint not null references public.clubs(id),
 name text not null check(char_length(name) between 2 and 80 and name=btrim(name)),
 indoor boolean not null,
 surface text not null default '' check(char_length(surface)<=80),
 description text not null default '' check(char_length(description)<=600),
 is_active boolean not null default true,
 version integer not null default 1 check(version>0),
 updated_at timestamptz not null default now(),
 unique(club_id,name)
);
create index club_courts_club_idx on public.club_courts(club_id,is_active,id);
alter table public.club_courts enable row level security;
revoke all on public.club_courts from public,anon,authenticated,service_role;

create table private.club_metadata_audit (
 id bigint generated always as identity primary key,
 actor_id uuid references public.profiles(id) on delete set null,
 club_id bigint not null references public.clubs(id),
 court_id uuid,
 before_value jsonb,
 after_value jsonb not null,
 reason text not null check(char_length(reason) between 5 and 400),
 created_at timestamptz not null default now()
);
alter table private.club_metadata_audit enable row level security;
revoke all on private.club_metadata_audit from public,anon,authenticated,service_role;

-- URL data is never fetched by a privileged server. Limit links to public HTTPS host names.
create function private.club_public_https(p text) returns boolean language sql immutable set search_path='' as $$
 select p is not null and char_length(p) between 12 and 2048
 and p ~ '^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(/[^[:space:]\\]*)?$'
 and p !~* '^https://([^/]*\.)?(localhost|local|internal|invalid|example|test)(/|$)'
 and p !~ '[[:cntrl:]]'
$$;

create function private.club_json(p_club bigint,p_details boolean default false) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',c.id,'name',c.name,'city_id',c.city_id,'city_name',ct.name,
  'players_count',(select count(*) from public.profiles p where p.club_id=c.id and p.deleted_at is null),
  'description',c.description,'address',c.address,'latitude',c.latitude,'longitude',c.longitude,
  'photo_urls',to_jsonb(c.photo_urls),'amenities',to_jsonb(c.amenities),'contact_phone',c.contact_phone,
  'website_url',c.website_url,'booking_url',c.booking_url,'booking_verified_at',c.booking_verified_at,
  'metadata_version',c.metadata_version,'updated_at',c.updated_at,
  'courts_count',(select count(*) from public.club_courts r where r.club_id=c.id and r.is_active),
  'courts',case when p_details then (select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'club_id',r.club_id,
    'name',r.name,'indoor',r.indoor,'surface',r.surface,'description',r.description,'is_active',r.is_active,
    'version',r.version,'updated_at',r.updated_at) order by r.name,r.id),'[]'::jsonb)
    from public.club_courts r where r.club_id=c.id and r.is_active) else '[]'::jsonb end)
 from public.clubs c join public.cities ct on ct.id=c.city_id where c.id=p_club
$$;

create or replace function public.list_clubs(p_city_id integer,p_query text default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();q text:=private.norm(p_query);
begin
 return (select coalesce(jsonb_agg(private.club_json(x.id) order by x.players desc,x.name,x.id),'[]'::jsonb) from
  (select c.id,c.name,(select count(*) from public.profiles p where p.club_id=c.id and p.deleted_at is null) players
   from public.clubs c where c.city_id=p_city_id and (q='' or c.name_norm like '%'||q||'%' or private.norm(c.address) like '%'||q||'%')
   order by players desc,c.name,c.id limit 100) x);
end $$;

create function public.club_detail(p_club bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();v jsonb;is_admin boolean;
begin
 v:=private.club_json(p_club,true);
 if v is null then perform private.fail('club_not_found');end if;
 is_admin:=exists(select 1 from private.admins where user_id=u);
 if is_admin then
  v:=v||jsonb_build_object('courts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.name,r.id),'[]'::jsonb) from public.club_courts r where r.club_id=p_club));
 end if;
 return v||jsonb_build_object('viewer',jsonb_build_object('can_edit',is_admin));
end $$;

-- Admin reviews source material/club ownership before asserting a booking URL is official.
-- Fresh authorization from private.admins is used, never a mutable user/JWT metadata claim.
create function public.admin_club_update(p_club bigint,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_admin();c public.clubs;old_value jsonb;photos text[];features text[];lat float8;lon float8;v int;reason text;
begin
 if private.jtype(p)<>'object' or exists(select 1 from jsonb_object_keys(p) k where k not in
  ('version','description','address','latitude','longitude','photo_urls','amenities','contact_phone','website_url','booking_url','booking_verified','reason')) then perform private.fail('invalid_request');end if;
 if private.jtype(p->'version')<>'number' or private.jtype(p->'reason')<>'string' then perform private.fail('invalid_request');end if;
 begin v:=(p->>'version')::int;exception when others then perform private.fail('invalid_request');end;
 reason:=btrim(p->>'reason');if char_length(reason) not between 5 and 400 then perform private.fail('invalid_request');end if;
 select * into c from public.clubs where id=p_club for update;
 if not found then perform private.fail('club_not_found');end if;
 if c.metadata_version<>v then perform private.fail('version_conflict');end if;
 old_value:=to_jsonb(c);
 if p?'description' then
  if private.jtype(p->'description')<>'string' or char_length(p->>'description')>2000 then perform private.fail('invalid_request');end if;
  c.description:=btrim(p->>'description');
 end if;
 if p?'address' then
  if private.jtype(p->'address') not in ('null','string') or private.jtype(p->'address')='string' and char_length(btrim(p->>'address')) not between 2 and 300 then perform private.fail('invalid_request');end if;
  c.address:=btrim(p->>'address');
 end if;
 if p?'latitude' or p?'longitude' then
  if not(p?'latitude' and p?'longitude') or private.jtype(p->'latitude') not in ('number','null') or private.jtype(p->'longitude') not in ('number','null') then perform private.fail('invalid_request');end if;
  begin lat:=(p->>'latitude')::float8;lon:=(p->>'longitude')::float8;exception when others then perform private.fail('invalid_request');end;
  if (lat is null)<>(lon is null) or lat not between -90 and 90 or lon not between -180 and 180 then perform private.fail('invalid_request');end if;
  c.latitude:=lat;c.longitude:=lon;
 end if;
 if p?'photo_urls' then
  if private.jtype(p->'photo_urls')<>'array' or jsonb_array_length(p->'photo_urls')>12 then perform private.fail('invalid_request');end if;
  if exists(select 1 from jsonb_array_elements(p->'photo_urls') x where private.jtype(x)<>'string' or not private.club_public_https(x#>>'{}')) then perform private.fail('invalid_request');end if;
  select coalesce(array_agg(x),'{}'::text[]) into photos from jsonb_array_elements_text(p->'photo_urls') x;c.photo_urls:=photos;
 end if;
 if p?'amenities' then
  if private.jtype(p->'amenities')<>'array' or jsonb_array_length(p->'amenities')>24 then perform private.fail('invalid_request');end if;
  if exists(select 1 from jsonb_array_elements(p->'amenities') x where private.jtype(x)<>'string' or char_length(btrim(x#>>'{}')) not between 2 and 60) then perform private.fail('invalid_request');end if;
  select coalesce(array_agg(distinct btrim(x)),'{}'::text[]) into features from jsonb_array_elements_text(p->'amenities') x;c.amenities:=features;
 end if;
 if p?'contact_phone' then
  if private.jtype(p->'contact_phone') not in ('null','string') or private.jtype(p->'contact_phone')='string' and
   (char_length(p->>'contact_phone') not between 5 and 32 or p->>'contact_phone' !~ '^[+0-9 ()-]+$') then perform private.fail('invalid_request');end if;
  c.contact_phone:=p->>'contact_phone';
 end if;
 if p?'website_url' then
  if private.jtype(p->'website_url') not in ('null','string') or private.jtype(p->'website_url')='string' and not private.club_public_https(p->>'website_url') then perform private.fail('invalid_request');end if;
  c.website_url:=p->>'website_url';
 end if;
 if p?'booking_url' then
  if private.jtype(p->'booking_url') not in ('null','string') then perform private.fail('invalid_request');end if;
  c.booking_url:=p->>'booking_url';
  if c.booking_url is not null then
   if not private.club_public_https(c.booking_url) or p->'booking_verified' is distinct from 'true'::jsonb then perform private.fail('invalid_request');end if;
   c.booking_verified_at:=now();
  else c.booking_verified_at:=null;end if;
 elsif p?'booking_verified' then perform private.fail('invalid_request');end if;
 update public.clubs set description=c.description,address=c.address,latitude=c.latitude,longitude=c.longitude,
  photo_urls=c.photo_urls,amenities=c.amenities,contact_phone=c.contact_phone,website_url=c.website_url,
  booking_url=c.booking_url,booking_verified_at=c.booking_verified_at,metadata_version=metadata_version+1,updated_at=now() where id=p_club;
 insert into private.club_metadata_audit(actor_id,club_id,before_value,after_value,reason)
 values(u,p_club,old_value,(select to_jsonb(x) from public.clubs x where id=p_club),reason);
 return public.club_detail(p_club);
end $$;

create function public.admin_court_put(p_club bigint,p_court uuid,p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_admin();r public.club_courts;old_value jsonb;v int;reason text;
begin
 if private.jtype(p)<>'object' or exists(select 1 from jsonb_object_keys(p) k where k not in ('version','name','indoor','surface','description','is_active','reason'))
  or private.jtype(p->'version')<>'number' or private.jtype(p->'name')<>'string' or private.jtype(p->'indoor')<>'boolean'
  or private.jtype(p->'surface')<>'string' or private.jtype(p->'description')<>'string' or private.jtype(p->'is_active')<>'boolean'
  or private.jtype(p->'reason')<>'string' or char_length(btrim(p->>'name')) not between 2 and 80 or char_length(p->>'surface')>80
  or char_length(p->>'description')>600 or char_length(btrim(p->>'reason')) not between 5 and 400 then perform private.fail('invalid_request');end if;
 begin v:=(p->>'version')::int;exception when others then perform private.fail('invalid_request');end;
 if v<0 or p_court is null then perform private.fail('invalid_request');end if;
 -- Serialize creation/updates within a club to guard unique names and absent-row races.
 perform 1 from public.clubs where id=p_club for update;
 if not found then perform private.fail('club_not_found');end if;
 select * into r from public.club_courts where id=p_court for update;
 if found then
  if r.club_id<>p_club then perform private.fail('not_found');end if;
  if v=0 and r.version=1 and r.name=btrim(p->>'name') and r.indoor=(p->>'indoor')::boolean and r.surface=btrim(p->>'surface')
   and r.description=btrim(p->>'description') and r.is_active=(p->>'is_active')::boolean then return to_jsonb(r);end if;
  if r.version<>v then perform private.fail('version_conflict');end if;
  old_value:=to_jsonb(r);
  update public.club_courts set name=btrim(p->>'name'),indoor=(p->>'indoor')::boolean,surface=btrim(p->>'surface'),
   description=btrim(p->>'description'),is_active=(p->>'is_active')::boolean,version=version+1,updated_at=now() where id=p_court;
 else
  if v<>0 then perform private.fail('version_conflict');end if;
  insert into public.club_courts(id,club_id,name,indoor,surface,description,is_active)
  values(p_court,p_club,btrim(p->>'name'),(p->>'indoor')::boolean,btrim(p->>'surface'),btrim(p->>'description'),(p->>'is_active')::boolean);
 end if;
 insert into private.club_metadata_audit(actor_id,club_id,court_id,before_value,after_value,reason)
 values(u,p_club,p_court,old_value,(select to_jsonb(x) from public.club_courts x where id=p_court),btrim(p->>'reason'));
 return (select to_jsonb(x) from public.club_courts x where id=p_court);
exception when unique_violation then perform private.fail('version_conflict');
end $$;

-- Same event visibility/consent rules apply while filtering by a real club.
create or replace function public.events_catalog(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();v_city integer;v_club bigint;v_kind text;v_scope text;v_limit int;v_offset int;items jsonb;more boolean;
begin
 perform private.require_active_player(u);
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 begin v_city:=(p->>'city_id')::integer;v_club:=(p->>'club_id')::bigint;v_kind:=p->>'kind';v_scope:=coalesce(p->>'scope','upcoming');
  v_limit:=coalesce((p->>'limit')::int,30);v_offset:=coalesce((p->>'offset')::int,0);
 exception when others then perform private.fail('invalid_request');end;
 if v_kind is not null and v_kind not in ('training','tournament') or v_scope not in ('mine','upcoming') or v_limit not between 1 and 50 or v_offset not between 0 and 1000 or v_club<=0 then perform private.fail('invalid_request');end if;
 with rows as(select e.id,row_number() over(order by e.starts_at,e.id) rn from public.sports_events e
  where private.event_access(e.id,u) and (v_city is null or e.city_id=v_city) and (v_club is null or e.club_id=v_club) and (v_kind is null or e.kind=v_kind)
   and case when v_scope='upcoming' then e.status='open' and e.starts_at>now()
    else e.organizer_id=u or exists(select 1 from public.event_registrations r where r.event_id=e.id and r.player_id=u) end)
 select coalesce(jsonb_agg(private.event_json(id,u,false) order by rn) filter(where rn<=v_offset+v_limit),'[]'::jsonb),
  coalesce(bool_or(rn>v_offset+v_limit),false) into items,more from rows where rn>v_offset and rn<=v_offset+v_limit+1;
 return jsonb_build_object('items',items,'next_offset',case when more then v_offset+v_limit end);
end $$;
create index sports_events_club_catalog_idx on public.sports_events(club_id,starts_at,id) where club_id is not null;

do $$ declare f record;begin
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private'
  and p.proname=any(array['club_public_https','club_json']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
 end loop;
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname=any(array['club_detail','admin_club_update','admin_court_put']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
  execute format('grant execute on function %s to authenticated',f.sig);
 end loop;
end $$;

-- Preserve exact upcoming-game access/sort contract; filter club before pagination.
CREATE OR REPLACE FUNCTION public.scheduled_matches(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := private.require_uid(); v_scope text := coalesce(p ->> 'scope', 'open');
  v_city integer; v_club bigint; v_limit integer; v_offset integer; v_items jsonb; v_more boolean; v_accepted boolean := false;
begin
  perform private.require_active_player(v_uid);
  if p is null or private.jtype(p) <> 'object' or v_scope not in ('open', 'mine') then perform private.fail('invalid_request'); end if;
  if p ? 'accepted_only' and private.jtype(p -> 'accepted_only') <> 'boolean' then perform private.fail('invalid_request'); end if;
  v_accepted := coalesce((p ->> 'accepted_only')::boolean, false);
  if v_accepted and v_scope <> 'mine' then perform private.fail('invalid_request'); end if;
  begin
    v_city := (p ->> 'city_id')::integer;
    if p ? 'club_id' and private.jtype(p -> 'club_id') not in ('number','null') then perform private.fail('invalid_request');end if;
    v_club := (p ->> 'club_id')::bigint;
    if v_club<=0 then perform private.fail('invalid_request');end if;
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
      and (v_club is null or m.club_id=v_club)
      and private.scheduled_access(m.id,v_uid)
      and case when v_scope = 'mine' then m.organizer_id = v_uid or exists (
        select 1 from public.scheduled_match_players sp where sp.match_id = m.id and sp.player_id = v_uid
          and (sp.status = 'accepted' or (sp.status in ('pending','invited','waitlisted') and not v_accepted)))
      else m.visibility = 'public' and m.cancelled_at is null and m.result_match_id is null and m.starts_at > now() end
  ) select coalesce(jsonb_agg(private.scheduled_json(id, v_uid) order by rn) filter (where rn <= v_offset + v_limit), '[]'::jsonb),
      coalesce(bool_or(rn > v_offset + v_limit), false) into v_items, v_more
    from candidates where rn > v_offset and rn <= v_offset + v_limit + 1;
  return jsonb_build_object('items', v_items, 'next_offset', case when v_more then v_offset + v_limit end);
end;
$function$;
