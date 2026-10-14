-- Extend authoritative future games without touching sports ratings/results.
alter table public.scheduled_matches add column visibility text not null default 'public' check(visibility in ('public','private'));
alter table public.scheduled_matches add column series_id uuid;
alter table public.scheduled_matches add column occurrence integer check(occurrence between 1 and 12);
alter table public.scheduled_match_players drop constraint scheduled_match_players_status_check;
alter table public.scheduled_match_players add constraint scheduled_match_players_status_check check(status in ('pending','accepted','rejected','withdrawn','invited','waitlisted'));
alter table public.scheduled_match_players add column invited_at timestamptz;
alter table public.scheduled_match_players add column closed_snapshot jsonb;
create table private.scheduled_creation_inputs (
 organizer_id uuid not null references public.profiles(id),client_id uuid not null,input jsonb not null,
 match_id uuid not null references public.scheduled_matches(id) on delete cascade,primary key(organizer_id,client_id)
);
create table public.scheduled_series (
 id uuid primary key default gen_random_uuid(),organizer_id uuid not null references public.profiles(id),client_id uuid not null,input jsonb not null,
 occurrences integer not null check(occurrences between 2 and 12),interval_weeks integer not null check(interval_weeks between 1 and 4),
 time_zone text not null,created_at timestamptz not null default now(),unique(organizer_id,client_id)
);
alter table public.scheduled_matches add constraint scheduled_matches_series_fk foreign key(series_id) references public.scheduled_series(id);
create unique index scheduled_matches_occurrence_idx on public.scheduled_matches(series_id,occurrence) where series_id is not null;
alter table private.scheduled_creation_inputs enable row level security;
alter table public.scheduled_series enable row level security;
create policy "no direct access" on public.scheduled_series as restrictive for all to anon,authenticated using(false) with check(false);
revoke all on private.scheduled_creation_inputs,public.scheduled_series from public,anon,authenticated,service_role;

create function private.scheduled_access(p_match uuid,u uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.scheduled_matches m where m.id=p_match and (m.organizer_id=u or (not private.blocked(u,m.organizer_id) and
 ((m.visibility='public' and (m.cancelled_at is null or exists(select 1 from public.scheduled_match_players old_relation where old_relation.match_id=m.id and old_relation.player_id=u))) or exists(select 1 from public.scheduled_match_players sp where sp.match_id=m.id and sp.player_id=u and sp.status in ('accepted','pending','invited','waitlisted'))))))
$$;
create function private.require_scheduled_access(p_match uuid,u uuid) returns void language plpgsql stable set search_path='' as $$
begin if not private.scheduled_access(p_match,u) then perform private.fail('scheduled_match_not_found');end if;end $$;
alter function private.scheduled_json(uuid,uuid) rename to scheduled_json_before_visibility;
create function private.scheduled_json(p_match uuid,p_viewer uuid) returns jsonb language sql stable set search_path='' as $$
 select private.scheduled_json_before_visibility(p_match,p_viewer)||jsonb_build_object('visibility',m.visibility,'series_id',m.series_id,'occurrence',m.occurrence,
 'viewer',(private.scheduled_json_before_visibility(p_match,p_viewer)->'viewer')||jsonb_build_object(
 'can_join',private.scheduled_access(m.id,p_viewer) and m.cancelled_at is null and m.result_match_id is null and m.starts_at>now() and seats.n<4
 and coalesce(mine.status,'none') not in ('accepted','pending') and private.scheduled_admission(m.id,p_viewer)<>'out_of_range'
 and not exists(select 1 from public.scheduled_match_players sp where sp.match_id=m.id and sp.status='accepted' and private.blocked(p_viewer,sp.player_id)),
 'can_waitlist',private.scheduled_access(m.id,p_viewer) and m.cancelled_at is null and m.result_match_id is null and m.starts_at>now() and seats.n=4 and coalesce(mine.status,'none') not in ('accepted','pending','waitlisted'),
 'can_invite',m.organizer_id=p_viewer and m.cancelled_at is null and m.result_match_id is null and m.starts_at>now()))
 from public.scheduled_matches m left join public.scheduled_match_players mine on mine.match_id=m.id and mine.player_id=p_viewer
 cross join lateral(select count(*)::int n from public.scheduled_match_players where match_id=m.id and status='accepted') seats where m.id=p_match
$$;
create or replace function private.scheduled_card(p_match uuid,p_viewer uuid,p_player uuid) returns jsonb language sql stable set search_path='' as $$
 select private.visible_card(p_viewer,p_player,exists(select 1 from public.scheduled_matches m join public.scheduled_match_players sp on sp.match_id=m.id
 where m.id=p_match and m.organizer_id=p_viewer and m.cancelled_at is null and sp.player_id=p_player and sp.status in ('pending','accepted','invited','waitlisted')))
$$;
create or replace function public.scheduled_match(p_match uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin perform private.require_active_player(u);perform private.require_scheduled_access(p_match,u);return private.scheduled_json(p_match,u);end $$;
-- Preserve the feed's existing sorting/admission fields; filter before paging.
do $$ declare d text;marker text:='from public.scheduled_matches m where (v_city is null or m.city_id = v_city)';begin
 select pg_get_functiondef('public.scheduled_matches(jsonb)'::regprocedure) into d;
 if position(marker in d)=0 then raise exception 'scheduled visibility migration precondition failed';end if;
 d:=replace(d,marker,marker||chr(10)||'      and private.scheduled_access(m.id,v_uid)');
 d:=replace(d,$old$else m.cancelled_at is null and m.result_match_id is null and m.starts_at > now() end$old$,$new$else m.visibility = 'public' and m.cancelled_at is null and m.result_match_id is null and m.starts_at > now() end$new$);
 d:=replace(d,$old$(sp.status = 'pending' and not v_accepted)$old$,$new$(sp.status in ('pending','invited','waitlisted') and not v_accepted)$new$);execute d;
end $$;

alter function public.create_scheduled_match(jsonb) set schema private;
alter function private.create_scheduled_match(jsonb) rename to create_scheduled_before_visibility;
create function public.create_scheduled_match(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();key uuid;v_id uuid;vis text:=coalesce(p->>'visibility','public');input jsonb;saved jsonb;v jsonb;begin
 perform private.lock_active_social_players(array[u]);
 if private.jtype(p)<>'object' or (p?'visibility' and (private.jtype(p->'visibility')<>'string' or vis not in ('public','private'))) then perform private.fail('invalid_scheduled_match');end if;
 begin key:=(p->>'client_id')::uuid;exception when others then perform private.fail('idempotency_key_required');end;
 if key is null then perform private.fail('idempotency_key_required');end if;
 input:=(p-'client_id')||jsonb_build_object('visibility',vis);
 perform pg_advisory_xact_lock(hashtextextended('create_scheduled_match:'||u,0));
 select x.input,x.match_id into saved,v_id from private.scheduled_creation_inputs x where x.organizer_id=u and x.client_id=key;
 if v_id is not null then if saved is distinct from input then perform private.fail('version_conflict');end if;return private.scheduled_json(v_id,u);end if;
 -- Earlier released games lack creation fingerprints. Keep their retry behavior.
 if exists(select 1 from public.scheduled_matches m where m.organizer_id=u and m.client_id=key) then return private.create_scheduled_before_visibility(p);end if;
 v:=private.create_scheduled_before_visibility(p);v_id:=(v->>'id')::uuid;
 update public.scheduled_matches set visibility=vis where public.scheduled_matches.id=v_id;
 insert into private.scheduled_creation_inputs(organizer_id,client_id,input,match_id) values(u,key,input,v_id);
 return private.scheduled_json(v_id,u);
end $$;
create function public.create_scheduled_series(p jsonb,p_client_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();n int;weeks int;tz text:=coalesce(p->>'time_zone','Europe/Moscow');local_start timestamp;starts timestamptz;
 s public.scheduled_series%rowtype;game uuid;input jsonb;items jsonb;begin
 perform private.lock_active_social_players(array[u]);
 if p_client_id is null then perform private.fail('idempotency_key_required');end if;
 if private.jtype(p)<>'object' or private.jtype(p->'match')<>'object' or private.jtype(p->'occurrences')<>'number' or private.jtype(p->'interval_weeks')<>'number'
 or (p?'time_zone' and private.jtype(p->'time_zone')<>'string') or (p->'match')?'client_id' then perform private.fail('invalid_request');end if;
 begin n:=(p->>'occurrences')::int;weeks:=(p->>'interval_weeks')::int;starts:=(p->'match'->>'starts_at')::timestamptz;exception when others then perform private.fail('invalid_request');end;
 if n not between 2 and 12 or weeks not between 1 and 4 or not exists(select 1 from pg_timezone_names where name=tz) or starts is null or not isfinite(starts) then perform private.fail('invalid_request');end if;
 input:=p||jsonb_build_object('time_zone',tz);
 perform pg_advisory_xact_lock(hashtextextended('scheduled-series:'||u||':'||p_client_id,0));
 select * into s from public.scheduled_series where organizer_id=u and client_id=p_client_id;
 if s.id is not null then if s.input is distinct from input then perform private.fail('version_conflict');end if;
 else
 insert into public.scheduled_series(organizer_id,client_id,input,occurrences,interval_weeks,time_zone) values(u,p_client_id,input,n,weeks,tz) returning * into s;
 local_start:=starts at time zone tz;
 for i in 1..n loop
 starts:=(local_start+(i-1)*weeks*interval '1 week') at time zone tz;
 game:=(public.create_scheduled_match((p->'match')||jsonb_build_object('client_id',gen_random_uuid(),'starts_at',starts))->>'id')::uuid;
 update public.scheduled_matches set series_id=s.id,occurrence=i where id=game;
 end loop;end if;
 select coalesce(jsonb_agg(private.scheduled_json(id,u) order by occurrence),'[]'::jsonb) into items from public.scheduled_matches where series_id=s.id;
 return jsonb_build_object('series_id',s.id,'items',items);
end $$;

create function public.invite_scheduled_player(p_match uuid,p_player uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();m public.scheduled_matches%rowtype;v_status text;begin
 if p_player=u then perform private.fail('invalid_request');end if;
 perform private.lock_active_social_players(array[u,p_player]);perform private.require_unblocked(u,p_player);
 select * into m from public.scheduled_matches where id=p_match for update;
 if m.id is null then perform private.fail('scheduled_match_not_found');end if;
 if m.organizer_id<>u then perform private.fail('organizer_required');end if;
 if m.cancelled_at is not null or m.result_match_id is not null then perform private.fail('scheduled_match_closed');end if;
 if m.starts_at<=now() then perform private.fail('scheduled_match_started');end if;
 if private.friendship_status(u,p_player)<>'accepted' then perform private.fail('friendship_not_accepted');end if;
 select sp.status into v_status from public.scheduled_match_players sp where match_id=p_match and player_id=p_player;
 if v_status in ('invited','accepted','pending','waitlisted') then return private.scheduled_json(p_match,u);end if;
 if not private.hit_rate_limit('game-invite:'||u,60,86400) then perform private.fail('rate_limited');end if;
 insert into public.scheduled_match_players(match_id,player_id,status,invited_at) values(p_match,p_player,'invited',now()) on conflict(match_id,player_id)
 do update set status='invited',invited_at=now(),joined_at=null,decided_at=null,requested_at=now(),closed_snapshot=null;
 perform private.notify_social(p_player,u,'game_invitation','Приглашение на игру',p_match);return private.scheduled_json(p_match,u);
end $$;
create function public.respond_scheduled_invitation(p_match uuid,p_decision text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();m public.scheduled_matches%rowtype;sp public.scheduled_match_players%rowtype;ids uuid[];begin
 if p_decision is null or p_decision not in ('accepted','declined') then perform private.fail('invalid_request');end if;
 select array_agg(player_id) into ids from public.scheduled_match_players where match_id=p_match and status='accepted';
 perform private.lock_active_social_players(array_append(coalesce(ids,'{}'),u));
 select * into m from public.scheduled_matches where id=p_match for update;if m.id is null then perform private.fail('scheduled_match_not_found');end if;
 perform private.require_unblocked(u,m.organizer_id);
 select * into sp from public.scheduled_match_players where match_id=p_match and player_id=u;
 if (p_decision='accepted' and sp.status='accepted') then return private.scheduled_json(p_match,u);end if;
 if p_decision='declined' and sp.status='rejected' and sp.invited_at is not null then return coalesce(sp.closed_snapshot,private.scheduled_json(p_match,u));end if;
 if sp.invited_at is null or sp.status not in ('invited','waitlisted') or sp.status is null then perform private.fail('invitation_not_pending');end if;
 if m.cancelled_at is not null or m.result_match_id is not null then perform private.fail('scheduled_match_closed');end if;
 if m.starts_at<=now() then perform private.fail('scheduled_match_started');end if;
 if p_decision='accepted' then
 if (select count(*) from public.scheduled_match_players where match_id=p_match and status='accepted')>=4 then perform private.fail('scheduled_match_full');end if;
 if exists(select 1 from public.scheduled_match_players where match_id=p_match and status='accepted' and private.blocked(u,player_id)) then perform private.fail('social_blocked');end if;
 if private.scheduled_admission(p_match,u)='out_of_range' then perform private.fail('level_out_of_range');end if;
 end if;
 update public.scheduled_match_players set status=case when p_decision='accepted' then 'accepted' else 'rejected' end,joined_at=case when p_decision='accepted' then now() end,decided_at=now() where match_id=p_match and player_id=u;
 if p_decision='declined' and m.visibility='private' then update public.scheduled_match_players set closed_snapshot=private.scheduled_json(p_match,u) where match_id=p_match and player_id=u;end if;
 return private.scheduled_json(p_match,u);
end $$;
create function public.waitlist_scheduled_match(p_match uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();m public.scheduled_matches%rowtype;v_status text;begin
 perform private.lock_active_social_players(array[u]);select * into m from public.scheduled_matches where id=p_match for update;
 if m.id is null then perform private.fail('scheduled_match_not_found');end if;perform private.require_scheduled_access(p_match,u);
 if m.cancelled_at is not null or m.result_match_id is not null then perform private.fail('scheduled_match_closed');end if;
 if m.starts_at<=now() then perform private.fail('scheduled_match_started');end if;
 select sp.status into v_status from public.scheduled_match_players sp where match_id=p_match and player_id=u;
 if v_status in ('accepted','pending','waitlisted') then return private.scheduled_json(p_match,u);end if;
 if (select count(*) from public.scheduled_match_players where match_id=p_match and status='accepted')<>4 then perform private.fail('invalid_request');end if;
 if exists(select 1 from public.scheduled_match_players where match_id=p_match and status='accepted' and private.blocked(u,player_id)) then perform private.fail('social_blocked');end if;
 if private.scheduled_admission(p_match,u)='out_of_range' then perform private.fail('level_out_of_range');end if;
 if not private.hit_rate_limit('game-waitlist:'||u,100,86400) then perform private.fail('rate_limited');end if;
 insert into public.scheduled_match_players(match_id,player_id,status) values(p_match,u,'waitlisted') on conflict(match_id,player_id) do update set status='waitlisted',requested_at=now(),joined_at=null,decided_at=null;
 perform private.notify_social(m.organizer_id,u,'game_waitlist','Новый участник листа ожидания',p_match);return private.scheduled_json(p_match,u);
end $$;

alter function public.join_scheduled_match(uuid) set schema private;
alter function private.join_scheduled_match(uuid) rename to join_scheduled_before_waitlist;
create function public.join_scheduled_match(p_match uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.require_active_player(u);perform private.require_scheduled_access(p_match,u);
 if exists(select 1 from public.scheduled_match_players where match_id=p_match and player_id=u and invited_at is not null and status in ('invited','waitlisted')) then return public.respond_scheduled_invitation(p_match,'accepted');end if;
 return private.join_scheduled_before_waitlist(p_match);
end $$;
alter function public.leave_scheduled_match(uuid) set schema private;
alter function private.leave_scheduled_match(uuid) rename to leave_scheduled_before_waitlist;
create function public.leave_scheduled_match(p_match uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();v jsonb;target uuid;before_status text;begin
 perform private.lock_active_social_players(array[u]);
 -- Retried withdrawal has no resource disclosure to unrelated callers.
 if exists(select 1 from public.scheduled_matches where id=p_match and visibility='private') and exists(select 1 from public.scheduled_match_players where match_id=p_match and player_id=u and status='withdrawn') then
 return (select closed_snapshot from public.scheduled_match_players where match_id=p_match and player_id=u);end if;
 perform private.require_scheduled_access(p_match,u);select status into before_status from public.scheduled_match_players where match_id=p_match and player_id=u;
 v:=private.leave_scheduled_before_waitlist(p_match);
 if v->>'visibility'='private' then update public.scheduled_match_players set closed_snapshot=v where match_id=p_match and player_id=u;end if;
 if before_status='accepted' and v->>'status'='open' then for target in select player_id from public.scheduled_match_players where match_id=p_match and status='waitlisted' order by requested_at,player_id loop
 perform private.notify_social(target,u,'game_spot_available','В игре освободилось место',p_match);end loop;end if;
 return v;
end $$;
-- Owner may admit a waitlist candidate using the same capacity/admission locks.
alter function public.review_scheduled_application(uuid,uuid,text) set schema private;
alter function private.review_scheduled_application(uuid,uuid,text) rename to review_scheduled_before_waitlist;
create function public.review_scheduled_application(p_match uuid,p_player uuid,p_decision text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();m public.scheduled_matches%rowtype;begin
 perform private.lock_active_social_players(array[u,p_player]);select * into m from public.scheduled_matches where id=p_match for update;
 if m.id is null then perform private.fail('scheduled_match_not_found');end if;
 if m.organizer_id<>u then perform private.fail('organizer_required');end if;
 if exists(select 1 from public.scheduled_match_players where match_id=p_match and player_id=p_player and status in ('waitlisted','invited')) then
 update public.scheduled_match_players set status='pending' where match_id=p_match and player_id=p_player;end if;
 return private.review_scheduled_before_waitlist(p_match,p_player,p_decision);
end $$;

create function private.anonymize_upcoming_extension() returns trigger language plpgsql security definer set search_path='' as $$
begin if old.deleted_at is null and new.deleted_at is not null then
 delete from private.scheduled_creation_inputs where organizer_id=new.id;
 update public.scheduled_match_players set closed_snapshot=null where player_id=new.id;
 update public.scheduled_match_players set closed_snapshot=closed_snapshot||jsonb_build_object('organizer',private.player_card(new.id),'note',null)
 where closed_snapshot->'organizer'->>'id'=new.id::text;
 update public.scheduled_match_players sp set closed_snapshot=sp.closed_snapshot||jsonb_build_object(
 'participants',(select coalesce(jsonb_agg(case when row->'player'->>'id'=new.id::text then row||jsonb_build_object('player',private.player_card(new.id)) else row end),'[]'::jsonb) from jsonb_array_elements(sp.closed_snapshot->'participants') row),
 'applications',(select coalesce(jsonb_agg(case when row->'player'->>'id'=new.id::text then row||jsonb_build_object('player',private.player_card(new.id)) else row end),'[]'::jsonb) from jsonb_array_elements(sp.closed_snapshot->'applications') row))
 where sp.closed_snapshot is not null;
 update public.scheduled_matches set note=null where organizer_id=new.id;
 update public.scheduled_series set input=jsonb_build_object('deleted',true) where organizer_id=new.id;
 update public.scheduled_match_players sp set status='withdrawn',joined_at=null,decided_at=now() from public.scheduled_matches m where m.id=sp.match_id and sp.player_id=new.id and sp.status in ('invited','waitlisted') and m.result_match_id is null;
 end if;return new;end $$;
create trigger profiles_upcoming_anonymize after update of deleted_at on public.profiles for each row execute function private.anonymize_upcoming_extension();

do $$ declare f record;begin
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' and p.proname=any(array['scheduled_access','require_scheduled_access','scheduled_json','scheduled_json_before_visibility','create_scheduled_before_visibility','join_scheduled_before_waitlist','leave_scheduled_before_waitlist','review_scheduled_before_waitlist','anonymize_upcoming_extension']) loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);end loop;
 for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(array['scheduled_match','create_scheduled_match','create_scheduled_series','invite_scheduled_player','respond_scheduled_invitation','waitlist_scheduled_match','join_scheduled_match','leave_scheduled_match','review_scheduled_application']) loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);execute format('grant execute on function %s to authenticated',f.sig);end loop;
end $$;

-- Every invited/waiting participant is informed about cancellation too.
create or replace function private.notify_game_cancellation() returns trigger language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();target uuid;begin
 if actor is not null and old.cancelled_at is null and new.cancelled_at is not null then
 for target in select player_id from public.scheduled_match_players where match_id=new.id and status in ('pending','accepted','invited','waitlisted') loop perform private.notify_social(target,actor,'game_cancelled','Игра отменена',new.id);end loop;end if;return new;end $$;
