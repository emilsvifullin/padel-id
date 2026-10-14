-- APNs foundation is disabled until the owner provisions a real Apple topic/key
-- and dedicated worker secret. No historical inbox notifications are backfilled.
create table private.push_config (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false,
 environment text not null default 'production' check(environment in ('sandbox','production')),
 topic text not null default 'app.padelid.ios' check(topic ~ '^[A-Za-z0-9.-]{3,200}$'),
 worker_secret_hash bytea check(worker_secret_hash is null or octet_length(worker_secret_hash)=32),
 check(not enabled or worker_secret_hash is not null)
);
insert into private.push_config(singleton) values(true);
create table private.push_devices (
 id uuid primary key default gen_random_uuid(),
 installation_id uuid not null,
 player_id uuid not null references public.profiles(id),
 session_id uuid not null references auth.sessions(id) on delete cascade,
 environment text not null check(environment in ('sandbox','production')),
 topic text not null,
 device_token text not null check(device_token ~ '^[0-9a-f]+$' and length(device_token) between 2 and 1024 and length(device_token)%2=0),
 enabled boolean not null default true,
 generation bigint not null default 1 check(generation>0),
 registered_at timestamptz not null default clock_timestamp(),
 unique(environment,topic,player_id,installation_id),unique(environment,topic,device_token)
);
create index push_devices_player_idx on private.push_devices(player_id,enabled);
create table private.push_deliveries (
 id uuid primary key default gen_random_uuid(),
 notification_id uuid not null references public.social_notifications(id) on delete cascade,
 device_id uuid not null references private.push_devices(id) on delete cascade,
 device_generation bigint not null,
 status text not null default 'pending' check(status in ('pending','leased','accepted','cancelled','failed')),
 attempts integer not null default 0 check(attempts between 0 and 8),
 available_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '24 hours',
 lease_id uuid,lease_until timestamptz,
 last_reason text check(char_length(last_reason)<=80),
 accepted_at timestamptz,
 unique(notification_id,device_id),
 check((status='leased')=(lease_id is not null and lease_until is not null))
);
create index push_deliveries_ready_idx on private.push_deliveries(available_at,id) where status in ('pending','leased');
-- Canonical played-match actions were formerly local-notification only.
-- Versioned source keys also prevent mutation retries from duplicating alerts.
create table private.push_match_events (
 match_id uuid not null references public.matches(id) on delete cascade,
 match_version integer not null,
 player_id uuid not null references public.profiles(id),
 action text not null check(action in ('confirmation','dispute')),
 notification_id uuid not null unique references public.social_notifications(id) on delete cascade,
 primary key(match_id,match_version,player_id,action)
);
do $$ declare t text;begin
 foreach t in array array['push_config','push_devices','push_deliveries','push_match_events'] loop
  execute format('alter table private.%I enable row level security',t);
  execute format('revoke all on private.%I from public,anon,authenticated,service_role',t);
 end loop;
end $$;

-- Supabase expires time-boxed sessions through not_after before asynchronously
-- deleting rows. The local Auth shim mirrors this nullable platform column.
create function private.push_session_live(p_session uuid,p_player uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from auth.sessions s where s.id=p_session and s.user_id=p_player
  and (s.not_after is null or s.not_after>clock_timestamp()))
$$;

-- Preserve the existing UID/JWT UUID validation; expired-but-not-yet-deleted
-- Auth rows must be rejected by every existing RPC as well as push workers.
create or replace function private.require_uid() returns uuid language plpgsql stable set search_path='' as $$
declare v uuid:=auth.uid();v_claims jsonb:=nullif(current_setting('request.jwt.claims',true),'')::jsonb;v_session uuid;
begin
 if v is null then perform private.fail('not_authenticated');end if;
 begin v_session:=nullif(v_claims->>'session_id','')::uuid;exception when others then v_session:=null;end;
 if v_session is null or not private.push_session_live(v_session,v) then perform private.fail('session_expired');end if;
 return v;
end $$;
revoke all on function private.require_uid() from public,anon,authenticated,service_role;

create function public.register_push_device(p_installation uuid,p_token text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();session uuid;config private.push_config;d private.push_devices;
begin
 perform private.lock_active_social_players(array[u]);
 if p_installation is null or p_token is null or p_token !~ '^[A-Fa-f0-9]+$' or length(p_token) not between 2 and 1024 or length(p_token)%2<>0 or p_enabled is null then perform private.fail('invalid_request');end if;
 select * into config from private.push_config where singleton;
 if not config.enabled then perform private.fail('service_unavailable');end if;
 session:=(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'session_id')::uuid;
 -- Keep the currently validated session alive until registration commits.
 perform 1 from auth.sessions where id=session and user_id=u for share;
 if not found or not private.push_session_live(session,u) then perform private.fail('session_expired');end if;
 -- Token/installation registration is rare; one scoped advisory lock prevents
 -- duplicate-token and crossed-installation races without leaking another UID.
 perform pg_advisory_xact_lock(hashtextextended('push-register:'||config.environment||':'||config.topic,0));
 delete from private.push_devices where environment=config.environment and topic=config.topic and device_token=lower(p_token) and (installation_id<>p_installation or player_id<>u);
 select * into d from private.push_devices where environment=config.environment and topic=config.topic and player_id=u and installation_id=p_installation for update;
 if found then
  if d.player_id is distinct from u or d.session_id is distinct from session or d.device_token is distinct from lower(p_token) or d.enabled is distinct from p_enabled then
   update private.push_deliveries set status='cancelled',lease_id=null,lease_until=null,last_reason='registration_changed' where device_id=d.id and status in ('pending','leased');
   d.generation:=d.generation+1;
  end if;
  update private.push_devices set player_id=u,session_id=session,device_token=lower(p_token),enabled=p_enabled,generation=d.generation,registered_at=clock_timestamp() where id=d.id returning * into d;
 else
  if (select count(*) from private.push_devices where player_id=u and environment=config.environment and topic=config.topic)>=20 then perform private.fail('rate_limited');end if;
  insert into private.push_devices(installation_id,player_id,session_id,environment,topic,device_token,enabled)
   values(p_installation,u,session,config.environment,config.topic,lower(p_token),p_enabled) returning * into d;
 end if;
 return jsonb_build_object('installation_id',d.installation_id,'enabled',d.enabled,'environment',d.environment,'topic',d.topic,'generation',d.generation,'registered_at',d.registered_at);
end $$;

create function public.revoke_push_device(p_installation uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();session uuid;
begin
 if p_installation is null then perform private.fail('invalid_request');end if;
 session:=(nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'session_id')::uuid;
 -- An old account/session logout must not delete a newer registration.
 delete from private.push_devices where installation_id=p_installation and player_id=u and session_id=session;
 return jsonb_build_object('ok',true);
end $$;

create function private.push_worker_authorize(p_secret text) returns void language plpgsql stable set search_path='' as $$
begin
 if length(coalesce(p_secret,''))<32 or not exists(select 1 from private.push_config where singleton and enabled and worker_secret_hash=extensions.digest(p_secret,'sha256')) then perform private.fail('forbidden');end if;
end $$;

create function private.push_allowed(p_job uuid) returns boolean language sql stable set search_path='' as $$
 select coalesce((select d.enabled and d.generation=q.device_generation and cfg.enabled and cfg.environment=d.environment and cfg.topic=d.topic
  and private.push_session_live(d.session_id,d.player_id)
  and pr.deleted_at is null and n.player_id=d.player_id and n.read_at is null and q.expires_at>now()
  and (n.actor_id is null or exists(select 1 from public.profiles a where a.id=n.actor_id and a.deleted_at is null) and not private.blocked(d.player_id,n.actor_id))
  and case when n.kind='message' then coalesce((select notify_messages from public.social_settings where player_id=d.player_id),true)
   else coalesce((select notify_activity from public.social_settings where player_id=d.player_id),true) end
  and case
   when n.kind='message' then private.conversation_access(n.resource_id,d.player_id) and exists(select 1 from public.conversation_messages m where m.conversation_id=n.resource_id and m.sender_id=n.actor_id and m.deleted_at is null and m.created_at>=n.created_at)
   when n.kind='comment' then private.post_visible(n.resource_id,d.player_id) and exists(select 1 from public.social_comments c where c.post_id=n.resource_id and c.author_id=n.actor_id and c.deleted_at is null and c.created_at>=n.created_at)
   when n.kind in ('friend_request','friend_accepted') then private.socially_visible(d.player_id,n.actor_id)
   when n.kind like 'game_%' then private.scheduled_access(n.resource_id,d.player_id)
   when n.kind='event' then private.event_access(n.resource_id,d.player_id)
   when n.kind='match' then exists(select 1 from public.matches m join public.match_players mp on mp.match_id=m.id and mp.player_id=d.player_id
    join private.push_match_events k on k.notification_id=n.id and k.match_id=m.id and k.match_version=m.version
    where m.id=n.resource_id and m.status in ('pending','disputed') and (mp.response='pending' or m.status='disputed' and m.created_by=d.player_id))
   else false end
  from private.push_deliveries q join private.push_devices d on d.id=q.device_id join public.social_notifications n on n.id=q.notification_id
  join public.profiles pr on pr.id=d.player_id cross join private.push_config cfg where q.id=p_job and cfg.singleton),false)
$$;

create function private.enqueue_push_notification() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from private.push_config where singleton and enabled) then return new;end if;
 insert into private.push_deliveries(notification_id,device_id,device_generation)
  select new.id,d.id,d.generation from private.push_devices d join auth.sessions s on s.id=d.session_id and s.user_id=d.player_id
  join private.push_config c on c.singleton and c.enabled and c.environment=d.environment and c.topic=d.topic
  where d.player_id=new.player_id and d.enabled and private.push_session_live(d.session_id,d.player_id) on conflict(notification_id,device_id) do nothing;
 return new;
end $$;
create trigger social_notifications_push after insert on public.social_notifications for each row execute function private.enqueue_push_notification();

create function public.claim_push_deliveries(p_secret text,p_limit integer default 10) returns jsonb language plpgsql security definer set search_path='' as $$
declare job private.push_deliveries;items jsonb:='[]';lease uuid;
begin
 perform private.push_worker_authorize(p_secret);
 if p_limit is null or p_limit not between 1 and 50 then perform private.fail('invalid_request');end if;
 for job in select * from private.push_deliveries where (status='pending' and available_at<=now() or status='leased' and lease_until<=now())
  order by available_at,id limit p_limit for update skip locked loop
  if job.attempts>=8 or job.expires_at<=now() then
   update private.push_deliveries set status='failed',lease_id=null,lease_until=null,last_reason='expired_or_attempt_limit' where id=job.id;
  elsif not private.push_allowed(job.id) then
   update private.push_deliveries set status='cancelled',lease_id=null,lease_until=null,last_reason='access_revoked' where id=job.id;
  else
   lease:=gen_random_uuid();
   update private.push_deliveries set status='leased',attempts=attempts+1,lease_id=lease,lease_until=now()+interval '120 seconds' where id=job.id;
   items:=items||jsonb_build_array(jsonb_build_object('id',job.id,'lease_id',lease));
  end if;
 end loop;
 return jsonb_build_object('items',items);
end $$;

create function public.authorize_push_delivery(p_secret text,p_job uuid,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare q private.push_deliveries;d private.push_devices;
begin
 perform private.push_worker_authorize(p_secret);
 select * into q from private.push_deliveries where id=p_job for update;
 if not found or q.status<>'leased' or q.lease_id is distinct from p_lease or q.lease_until<=clock_timestamp() then return null;end if;
 if not private.push_allowed(q.id) then
  update private.push_deliveries set status='cancelled',lease_id=null,lease_until=null,last_reason='access_revoked' where id=q.id;return null;
 end if;
 update private.push_deliveries set lease_until=clock_timestamp()+interval '120 seconds' where id=q.id;
 select * into d from private.push_devices where id=q.device_id;
 return jsonb_build_object('id',q.id,'notification_id',q.notification_id,'device_token',d.device_token,'environment',d.environment,'topic',d.topic,'expires_at',q.expires_at);
end $$;

create function public.finish_push_delivery(p_secret text,p_job uuid,p_lease uuid,p_outcome text,p_reason text default null,p_invalidated_at_ms bigint default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare q private.push_deliveries;d private.push_devices;delay_seconds int;
begin
 perform private.push_worker_authorize(p_secret);
 if p_outcome not in ('accepted','retry','dead_token','permanent','provider_error') or p_outcome is null or char_length(coalesce(p_reason,''))>80
  or p_reason is not null and p_reason !~ '^[A-Za-z0-9_]+$' or p_invalidated_at_ms<0 then perform private.fail('invalid_request');end if;
 select * into q from private.push_deliveries where id=p_job;
 if not found then return jsonb_build_object('updated',false);end if;
 -- Registration/logout acquire device before delivery locks; retain that order.
 select * into d from private.push_devices where id=q.device_id for update;
 select * into q from private.push_deliveries where id=p_job for update;
 if not found or q.status<>'leased' or q.lease_id is distinct from p_lease or q.lease_until<=clock_timestamp() then return jsonb_build_object('updated',false);end if;
 if d.generation is distinct from q.device_generation or not private.push_allowed(q.id) then
  update private.push_deliveries set status='cancelled',lease_id=null,lease_until=null,last_reason='access_revoked' where id=q.id;
 elsif p_outcome='accepted' then
  update private.push_deliveries set status='accepted',accepted_at=now(),lease_id=null,lease_until=null,last_reason=null where id=q.id;
 elsif p_outcome='dead_token' then
  -- Apple 410 timestamps refer to a past invalidation. A subsequently refreshed
  -- registration must survive an old failure response.
  if p_invalidated_at_ms is null or to_timestamp(p_invalidated_at_ms/1000.0)>=d.registered_at then
   update private.push_devices set enabled=false,generation=generation+1 where id=d.id;
   update private.push_deliveries set status='cancelled',lease_id=null,lease_until=null,last_reason='dead_token' where device_id=d.id and status in ('pending','leased');
  else update private.push_deliveries set status='cancelled',lease_id=null,lease_until=null,last_reason='old_invalidation' where id=q.id;end if;
 elsif p_outcome='permanent' or q.attempts>=8 or q.expires_at<=now() then
  update private.push_deliveries set status='failed',lease_id=null,lease_until=null,last_reason=coalesce(p_reason,'permanent') where id=q.id;
 else
  -- Apple's current response guide says retry 5xx after 15 minutes; use that
  -- lower bound for every transient response, with bounded exponential backoff.
  delay_seconds:=case when p_outcome='provider_error' then 3600 else least(21600,900*(2^(q.attempts-1))::int) end;
  update private.push_deliveries set status='pending',lease_id=null,lease_until=null,available_at=now()+make_interval(secs=>delay_seconds),last_reason=coalesce(p_reason,'transient') where id=q.id;
 end if;
 return jsonb_build_object('updated',true);
end $$;

create function private.clear_push_for_deleted_player() returns trigger language plpgsql security definer set search_path='' as $$
begin if old.deleted_at is null and new.deleted_at is not null then delete from private.push_devices where player_id=new.id;end if;return new;end $$;
create trigger profiles_push_cleanup after update of deleted_at on public.profiles for each row execute function private.clear_push_for_deleted_player();

create function private.notify_played_match_action(p_match uuid,p_version integer,p_player uuid,p_actor uuid,p_action text)
returns void language plpgsql set search_path='' as $$
declare notification uuid:=gen_random_uuid();inserted uuid;
begin
 if p_player=p_actor or private.blocked(p_player,p_actor) or not exists(select 1 from public.profiles where id=p_player and deleted_at is null)
  or not coalesce((select notify_activity from public.social_settings where player_id=p_player),true)
  or exists(select 1 from private.push_match_events where match_id=p_match and match_version=p_version and player_id=p_player and action=p_action) then return;end if;
 insert into public.social_notifications(id,player_id,actor_id,kind,title,resource_id)
  values(notification,p_player,p_actor,'match',case when p_action='confirmation' then 'Подтвердите результат матча' else 'Проверьте оспоренный результат' end,p_match);
 insert into private.push_match_events(match_id,match_version,player_id,action,notification_id)
  values(p_match,p_version,p_player,p_action,notification) on conflict do nothing returning notification_id into inserted;
 if inserted is null then delete from public.social_notifications where id=notification;end if;
end $$;
create function private.notify_played_participant() returns trigger language plpgsql security definer set search_path='' as $$
declare m public.matches;
begin
 select * into m from public.matches where id=new.match_id;
 if m.status not in ('pending','disputed') then return new;end if;
 if tg_op='INSERT' and new.response='pending' and new.player_id<>m.created_by then
  perform private.notify_played_match_action(m.id,m.version,new.player_id,m.created_by,'confirmation');
 elsif tg_op='UPDATE' and new.response='disputed' and old.response is distinct from new.response then
  perform private.notify_played_match_action(m.id,m.version,m.created_by,new.player_id,'dispute');
 end if;return new;
end $$;
create trigger match_players_push_source after insert or update of response on public.match_players for each row execute function private.notify_played_participant();
create function private.notify_played_version() returns trigger language plpgsql security definer set search_path='' as $$
declare player uuid;
begin
 if new.version is distinct from old.version and new.status='pending' then
  for player in select player_id from public.match_players where match_id=new.id and response='pending' and player_id<>new.created_by loop
   perform private.notify_played_match_action(new.id,new.version,player,new.created_by,'confirmation');
  end loop;
 end if;return new;
end $$;
create trigger matches_push_source after update of version on public.matches for each row execute function private.notify_played_version();

do $$ declare f record;begin
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private'
  and p.proname=any(array['push_session_live','push_worker_authorize','push_allowed','enqueue_push_notification','clear_push_for_deleted_player','notify_played_match_action','notify_played_participant','notify_played_version']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
 end loop;
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname=any(array['register_push_device','revoke_push_device','claim_push_deliveries','authorize_push_delivery','finish_push_delivery']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);
  if f.sig::text like '%register_push_device%' or f.sig::text like '%revoke_push_device%' then execute format('grant execute on function %s to authenticated',f.sig);
  else execute format('grant execute on function %s to anon',f.sig);end if;
 end loop;
end $$;
