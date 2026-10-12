-- Social content is accessible exclusively through live-session RPCs.
create table public.social_settings (
 player_id uuid primary key references public.profiles(id),
 messages_from text not null default 'friends' check (messages_from in ('friends','everyone','nobody')),
 notify_messages boolean not null default true, notify_activity boolean not null default true
);
create table public.player_blocks (
 blocker_id uuid not null references public.profiles(id), blocked_id uuid not null references public.profiles(id),
 created_at timestamptz not null default now(), primary key(blocker_id,blocked_id),check(blocker_id<>blocked_id)
);
create index player_blocks_target_idx on public.player_blocks(blocked_id,blocker_id);
create table public.player_follows (
 follower_id uuid not null references public.profiles(id), followed_id uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),primary key(follower_id,followed_id),check(follower_id<>followed_id)
);
create index player_follows_target_idx on public.player_follows(followed_id,follower_id);
create table public.conversations (
 id uuid primary key default gen_random_uuid(),owner_id uuid not null references public.profiles(id),client_id uuid not null,
 creation_input jsonb not null,kind text not null check(kind in ('direct','group','game')),title text check(char_length(title) between 2 and 80),
 description text check(char_length(description)<=500),visibility text not null default 'private' check(visibility in ('public','private')),
 direct_low uuid references public.profiles(id),direct_high uuid references public.profiles(id),
 game_id uuid unique references public.scheduled_matches(id),city_id integer references public.cities(id),club_id bigint references public.clubs(id),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(owner_id,client_id),unique(direct_low,direct_high),
 check((kind='direct')=(direct_low is not null and direct_high is not null)),
 check(direct_low<direct_high),check((kind='game')=(game_id is not null)),check(kind='group' or visibility='private')
);
create index conversations_feed_idx on public.conversations(updated_at desc,id);
create index conversations_city_idx on public.conversations(city_id) where kind='group' and visibility='public';
create table private.conversation_creation_keys (player_id uuid not null references public.profiles(id),client_id uuid not null,input jsonb not null,conversation_id uuid not null references public.conversations(id) on delete cascade,primary key(player_id,client_id));
alter table private.conversation_creation_keys enable row level security;
revoke all on private.conversation_creation_keys from public,anon,authenticated,service_role;
create table public.conversation_members (
 conversation_id uuid not null references public.conversations(id) on delete cascade,player_id uuid not null references public.profiles(id),
 role text not null default 'member' check(role in ('owner','member')),joined_at timestamptz not null default now(),last_read_id bigint not null default 0,
 primary key(conversation_id,player_id)
);
create index conversation_members_player_idx on public.conversation_members(player_id,conversation_id);
create table public.conversation_messages (
 id bigint generated always as identity primary key,conversation_id uuid not null references public.conversations(id) on delete cascade,
 sender_id uuid not null references public.profiles(id),client_id uuid not null,body text not null check(char_length(body) between 1 and 4000),
 created_at timestamptz not null default now(),deleted_at timestamptz,unique(sender_id,client_id)
);
create index conversation_messages_page_idx on public.conversation_messages(conversation_id,id desc);
create table public.social_posts (
 id uuid primary key default gen_random_uuid(),author_id uuid not null references public.profiles(id),client_id uuid not null,
 body text not null check(char_length(body) between 1 and 4000),visibility text not null default 'public' check(visibility in ('public','friends')),
 group_id uuid references public.conversations(id),club_id bigint references public.clubs(id),created_at timestamptz not null default now(),deleted_at timestamptz,
 unique(author_id,client_id)
);
create index social_posts_feed_idx on public.social_posts(created_at desc,id) where deleted_at is null;
create index social_posts_author_idx on public.social_posts(author_id,created_at desc);
create index social_posts_group_idx on public.social_posts(group_id);
create index social_posts_club_idx on public.social_posts(club_id);
create table public.social_comments (
 id uuid primary key default gen_random_uuid(),post_id uuid not null references public.social_posts(id),author_id uuid not null references public.profiles(id),
 client_id uuid not null,body text not null check(char_length(body) between 1 and 1000),created_at timestamptz not null default now(),deleted_at timestamptz,
 unique(author_id,client_id)
);
create index social_comments_post_idx on public.social_comments(post_id,created_at,id) where deleted_at is null;
create index social_comments_author_idx on public.social_comments(author_id);
create table public.social_reactions (
 post_id uuid not null references public.social_posts(id),player_id uuid not null references public.profiles(id),
 reaction text not null check(reaction in ('like','celebrate','support')),primary key(post_id,player_id)
);
create index social_reactions_player_idx on public.social_reactions(player_id);
create table public.social_notifications (
 id uuid primary key default gen_random_uuid(),player_id uuid not null references public.profiles(id),actor_id uuid references public.profiles(id),
 kind text not null,title text not null,resource_id uuid,created_at timestamptz not null default now(),read_at timestamptz
);
create index social_notifications_player_idx on public.social_notifications(player_id,created_at desc,id);
create index social_notifications_actor_idx on public.social_notifications(actor_id);
create table public.content_reports (
 id uuid primary key default gen_random_uuid(),reporter_id uuid not null references public.profiles(id),client_id uuid not null,
 target_type text not null check(target_type in ('player','message','post','comment')),target_id text not null,
 reason text not null check(reason in ('spam','harassment','inappropriate','other')),detail text check(char_length(detail)<=500),
 status text not null default 'pending' check(status in ('pending','dismissed','hidden')),created_at timestamptz not null default now(),
 reviewed_by uuid references public.profiles(id),reviewed_at timestamptz,unique(reporter_id,client_id)
);
create index content_reports_pending_idx on public.content_reports(created_at,id) where status='pending';
create index content_reports_reviewer_idx on public.content_reports(reviewed_by);

do $$ declare t text; begin
 foreach t in array array['social_settings','player_blocks','player_follows','conversations','conversation_members','conversation_messages','social_posts','social_comments','social_reactions','social_notifications','content_reports'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('create policy "no direct access" on public.%I as restrictive for all to anon, authenticated using (false) with check (false)',t);
 execute format('revoke all on public.%I from public, anon, authenticated, service_role',t);
 end loop;
end $$;
revoke all on sequence public.conversation_messages_id_seq from public,anon,authenticated,service_role;

create function private.blocked(a uuid,b uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.player_blocks where (blocker_id=a and blocked_id=b) or (blocker_id=b and blocked_id=a))
$$;
create function private.require_unblocked(a uuid,b uuid) returns void language plpgsql stable set search_path='' as $$
begin if private.blocked(a,b) then perform private.fail('social_blocked'); end if; end $$;
-- Preserve existing visibility, adding a bilateral block before any exception.
alter function private.socially_visible(uuid,uuid) rename to socially_visible_before_blocks;
create function private.socially_visible(p_viewer uuid,p_player uuid) returns boolean language sql stable set search_path='' as $$
 select not private.blocked(p_viewer,p_player) and private.socially_visible_before_blocks(p_viewer,p_player)
$$;
create or replace function private.visible_card(p_viewer uuid,p_player uuid,p_allowed boolean default false)
returns jsonb language sql stable set search_path='' as $$
 select case when not private.blocked(p_viewer,p_player) and (p_allowed or private.socially_visible(p_viewer,p_player)) then private.player_card(p_player)
 else jsonb_build_object('id',p_player,'username',null,'display_name','Скрытый игрок','deleted',false,'avatar_path',null,'city',null,'club',null,'preferred_side',null,'is_coach',false,'level',null,'reliability',null) end
$$;
alter function public.friendship_action(uuid,text) set schema private;
alter function private.friendship_action(uuid,text) rename to friendship_action_before_blocks;
create function public.friendship_action(p_player uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid(); begin
 perform private.lock_active_social_players(array[u,p_player]); perform private.require_unblocked(u,p_player);
 return private.friendship_action_before_blocks(p_player,p_action);
end $$;

create function public.social_settings() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid(); v jsonb; begin
 perform private.require_active_player(u);
 select to_jsonb(s)-'player_id' into v from public.social_settings s where player_id=u;
 return coalesce(v,jsonb_build_object('messages_from','friends','notify_messages',true,'notify_activity',true));
end $$;
create function public.update_social_settings(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid(); begin
 perform private.lock_active_social_players(array[u]);
 if private.jtype(p)<>'object' or exists(select 1 from jsonb_object_keys(p) k where k not in ('messages_from','notify_messages','notify_activity'))
 or (p?'messages_from' and (private.jtype(p->'messages_from')<>'string' or p->>'messages_from' not in ('friends','everyone','nobody')))
 or (p?'notify_messages' and private.jtype(p->'notify_messages')<>'boolean') or (p?'notify_activity' and private.jtype(p->'notify_activity')<>'boolean') then perform private.fail('invalid_request'); end if;
 insert into public.social_settings(player_id) values(u) on conflict do nothing;
 update public.social_settings set messages_from=coalesce(p->>'messages_from',messages_from),notify_messages=coalesce((p->>'notify_messages')::boolean,notify_messages),notify_activity=coalesce((p->>'notify_activity')::boolean,notify_activity) where player_id=u;
 return public.social_settings();
end $$;
create function public.blocked_players() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid(); begin
 perform private.require_active_player(u);
 return jsonb_build_object('items',coalesce((select jsonb_agg(private.player_card(blocked_id) order by created_at desc) from public.player_blocks where blocker_id=u),'[]'::jsonb),'next_offset',null);
end $$;
create function public.block_player(p_player uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid(); begin
 if u=p_player then perform private.fail('invalid_request'); end if;
 -- Exclusive profile locks serialize with message/send/share locks and deletion.
 perform id from public.profiles where id=any(array[u,p_player]) order by id for update;
 perform private.require_active_player(u);perform private.require_active_player(p_player);
 if not exists(select 1 from public.player_blocks where blocker_id=u and blocked_id=p_player) then
 perform private.require_visible_player(u,p_player);
 insert into public.player_blocks(blocker_id,blocked_id) values(u,p_player) on conflict do nothing; end if;
 update public.friendships set status='removed' where player_low=least(u,p_player) and player_high=greatest(u,p_player);
 delete from public.player_follows where (follower_id=u and followed_id=p_player) or (follower_id=p_player and followed_id=u);
 delete from public.social_notifications where (player_id=u and actor_id=p_player) or (player_id=p_player and actor_id=u);
 return jsonb_build_object('player_id',p_player,'blocked',true);
end $$;
create function public.unblock_player(p_player uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid(); begin
 perform private.lock_active_social_players(array[u]);delete from public.player_blocks where blocker_id=u and blocked_id=p_player;
 return jsonb_build_object('player_id',p_player,'blocked',false);
end $$;
create function public.follow_player(p_player uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid(); begin
 if u=p_player then perform private.fail('invalid_request');end if;
 perform private.lock_active_social_players(array[u,p_player]);perform private.require_visible_player(u,p_player);perform private.require_unblocked(u,p_player);
 if not exists(select 1 from public.player_follows where follower_id=u and followed_id=p_player) then
 if not private.hit_rate_limit('follow:'||u,100,86400) then perform private.fail('rate_limited');end if;
 insert into public.player_follows(follower_id,followed_id) values(u,p_player) on conflict do nothing;end if;
 return jsonb_build_object('player_id',p_player,'following',true);
end $$;
create function public.unfollow_player(p_player uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.lock_active_social_players(array[u]);delete from public.player_follows where follower_id=u and followed_id=p_player;
 return jsonb_build_object('player_id',p_player,'following',false);
end $$;
create function public.following_players() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.require_active_player(u);
 return jsonb_build_object('items',coalesce((select jsonb_agg(private.player_card(followed_id) order by created_at desc) from public.player_follows where follower_id=u and private.socially_visible(u,followed_id)),'[]'::jsonb),'next_offset',null);
end $$;

create function private.conversation_access(c uuid,u uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.conversations x where x.id=c and
 (case when x.kind='game' then exists(select 1 from public.scheduled_match_players sp where sp.match_id=x.game_id and sp.player_id=u and sp.status='accepted')
 else exists(select 1 from public.conversation_members cm where cm.conversation_id=x.id and cm.player_id=u) end)
 and (x.kind<>'direct' or not private.blocked(x.direct_low,x.direct_high)))
$$;
create function private.require_conversation(c uuid,u uuid) returns void language plpgsql stable set search_path='' as $$
begin if not private.conversation_access(c,u) then perform private.fail('conversation_not_found'); end if;end $$;
create function private.message_json(m bigint,u uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',id,'conversation_id',conversation_id,'sender',private.visible_card(u,sender_id,true),'body',case when deleted_at is not null then 'Сообщение удалено' else body end,'created_at',created_at,'client_id',client_id,'deleted',deleted_at is not null)
 from public.conversation_messages where id=m
$$;
create function private.conversation_json(c uuid,u uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',x.id,'kind',x.kind,'title',case when x.kind='direct' then (private.visible_card(u,case when x.direct_low=u then x.direct_high else x.direct_low end,true)->>'display_name') when x.kind='game' then 'Чат игры' else x.title end,
 'description',x.description,'visibility',x.visibility,'game_id',x.game_id,'city_id',x.city_id,'club_id',x.club_id,'owner_id',x.owner_id,'created_at',x.created_at,'updated_at',x.updated_at,
 'members',case when x.kind='game' then coalesce((select jsonb_agg(jsonb_build_object('player',private.visible_card(u,sp.player_id,true),'role',case when sp.player_id=x.owner_id then 'owner' else 'member' end) order by sp.player_id) from public.scheduled_match_players sp where sp.match_id=x.game_id and sp.status='accepted'),'[]'::jsonb)
 else coalesce((select jsonb_agg(jsonb_build_object('player',private.visible_card(u,cm.player_id,true),'role',cm.role) order by cm.joined_at,cm.player_id) from public.conversation_members cm where cm.conversation_id=x.id),'[]'::jsonb) end,
 'unread_count',(select count(*) from public.conversation_messages m where m.conversation_id=x.id and m.id>coalesce((select last_read_id from public.conversation_members where conversation_id=x.id and player_id=u),0) and m.sender_id<>u and m.deleted_at is null and not private.blocked(u,m.sender_id)),
 'latest_message',(select private.message_json(m.id,u) from public.conversation_messages m where m.conversation_id=x.id and not private.blocked(u,m.sender_id) order by m.id desc limit 1))
 from public.conversations x where x.id=c
$$;
create function public.conversation(p_conversation uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin perform private.require_active_player(u);perform private.require_conversation(p_conversation,u);return private.conversation_json(p_conversation,u);end $$;
create function public.conversations(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;begin
 perform private.require_active_player(u);
 with rows as(select c.id,c.updated_at,row_number() over(order by c.updated_at desc,c.id) rn from public.conversations c where private.conversation_access(c.id,u))
 select coalesce(jsonb_agg(private.conversation_json(id,u) order by rn) filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;
create function public.create_conversation(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();k text:=p->>'kind';key uuid;peer uuid;g uuid;c uuid;x public.conversations%rowtype;ids uuid[];s text;other uuid;input jsonb;saved_input jsonb;begin
 if private.jtype(p)<>'object' or private.jtype(p->'client_id')<>'string' then perform private.fail('idempotency_key_required');end if;
 begin key:=(p->>'client_id')::uuid;peer:=(p->>'player_id')::uuid;g:=(p->>'game_id')::uuid;
 select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(coalesce(p->'player_ids','[]'::jsonb));
 exception when others then perform private.fail('invalid_request');end;
 input:=(p-'client_id') || case when k='group' then jsonb_build_object('title',btrim(p->>'title'),'description',p->>'description','visibility',coalesce(p->>'visibility','private'),'player_ids',(select coalesce(jsonb_agg(v order by v),'[]'::jsonb) from (select distinct unnest(ids) v) z),'city_id',p->'city_id','club_id',p->'club_id') else '{}'::jsonb end;
 if key is null or k is null or k not in ('direct','group','game') or cardinality(ids)>30 then perform private.fail('invalid_request');end if;
 if k='direct' then if peer is null or peer=u then perform private.fail('invalid_request');end if;ids:=array[peer];end if;
 if k='game' then select array_agg(player_id) into ids from public.scheduled_match_players where match_id=g and status='accepted';if not u=any(coalesce(ids,'{}'::uuid[])) then perform private.fail('conversation_not_found');end if;end if;
 perform private.lock_active_social_players(array_append(ids,u));
 perform pg_advisory_xact_lock(hashtextextended('conversation-create:'||u||':'||key,0));
 select conversation_id,private.conversation_creation_keys.input into c,saved_input from private.conversation_creation_keys where player_id=u and client_id=key;
 if c is not null then if saved_input is distinct from input then perform private.fail('version_conflict');end if;perform private.require_conversation(c,u);return private.conversation_json(c,u);end if;
 select * into x from public.conversations where owner_id=u and client_id=key;
 if x.id is not null then
 if x.creation_input is distinct from input then perform private.fail('version_conflict');end if;
 perform private.require_conversation(x.id,u);return private.conversation_json(x.id,u);end if;
 foreach other in array ids loop
 perform private.require_unblocked(u,other);
 if k='direct' then
 perform private.require_visible_player(u,other);
 select messages_from into s from public.social_settings where player_id=other;s:=coalesce(s,'friends');
 if s='nobody' or (s='friends' and private.friendship_status(u,other)<>'accepted') then perform private.fail('messages_not_allowed');end if;
 elsif k='group' and other<>u and private.friendship_status(u,other)<>'accepted' then perform private.fail('messages_not_allowed');end if;
 end loop;
 if k='direct' then
 perform pg_advisory_xact_lock(hashtextextended('conversation-direct:'||least(u,peer)||':'||greatest(u,peer),0));
 select id into c from public.conversations where direct_low=least(u,peer) and direct_high=greatest(u,peer);
 elsif k='game' then
 perform pg_advisory_xact_lock(hashtextextended('conversation-game:'||g,0));select id into c from public.conversations where game_id=g;
 end if;
 if c is not null then insert into private.conversation_creation_keys(player_id,client_id,input,conversation_id) values(u,key,input,c);return private.conversation_json(c,u);end if;
 if k='group' and (char_length(btrim(coalesce(p->>'title',''))) not between 2 and 80 or char_length(coalesce(p->>'description',''))>500 or coalesce(p->>'visibility','private') not in ('public','private')) then perform private.fail('invalid_request');end if;
 if not private.hit_rate_limit('conversation-create:'||u,30,86400) then perform private.fail('rate_limited');end if;
 insert into public.conversations(owner_id,client_id,creation_input,kind,title,description,visibility,direct_low,direct_high,game_id,city_id,club_id)
 values(case when k='game' then (select organizer_id from public.scheduled_matches where id=g) else u end,key,input,k,case when k='group' then btrim(p->>'title') end,p->>'description',case when k='group' then coalesce(p->>'visibility','private') else 'private' end,
 case when k='direct' then least(u,peer) end,case when k='direct' then greatest(u,peer) end,case when k='game' then g end,(p->>'city_id')::int,(p->>'club_id')::bigint) returning id into c;
 insert into public.conversation_members(conversation_id,player_id,role) select c,t,case when t=u then 'owner' else 'member' end from(select distinct unnest(array_append(ids,u)) t) z;
 insert into private.conversation_creation_keys(player_id,client_id,input,conversation_id) values(u,key,input,c);
 return private.conversation_json(c,u);
end $$;
create function public.conversation_member_action(p_conversation uuid,p_player uuid,p_action text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();target uuid:=coalesce(p_player,u);c public.conversations%rowtype;begin
 perform private.lock_active_social_players(array[u,target]);select * into c from public.conversations where id=p_conversation for update;
 if c.id is null or c.kind<>'group' then perform private.fail('conversation_not_found');end if;
 if p_action='join' then
 if target<>u or c.visibility<>'public' then perform private.fail('forbidden');end if;perform private.require_unblocked(u,c.owner_id);
 elsif p_action='leave' then
 if target<>u then perform private.fail('forbidden');end if;
 elsif p_action='transfer_owner' then
 if target=c.owner_id then perform private.require_conversation(c.id,u);return private.conversation_json(c.id,u);end if;
 if c.owner_id<>u then perform private.fail('conversation_owner_required');end if;
 perform private.require_unblocked(u,target);
 if not exists(select 1 from public.conversation_members where conversation_id=c.id and player_id=target) then perform private.fail('conversation_not_found');end if;
 update public.conversation_members set role=case when player_id=target then 'owner' else 'member' end where conversation_id=c.id and player_id in (u,target);
 update public.conversations set owner_id=target,updated_at=now() where id=c.id;
 return private.conversation_json(c.id,u);
 elsif p_action in ('add','remove') then
 if c.owner_id<>u then perform private.fail('conversation_owner_required');end if;
 if p_action='add' then perform private.require_unblocked(u,target);if target<>u and private.friendship_status(u,target)<>'accepted' then perform private.fail('messages_not_allowed');end if;end if;
 else perform private.fail('invalid_request');end if;
 if p_action in ('join','add') then
 if (select count(*) from public.conversation_members where conversation_id=c.id)>=100 and not exists(select 1 from public.conversation_members where conversation_id=c.id and player_id=target) then perform private.fail('invalid_request');end if;
 insert into public.conversation_members(conversation_id,player_id) values(c.id,target) on conflict do nothing;
 else
 if target=c.owner_id then perform private.fail('conversation_owner_cannot_leave');end if;
 delete from public.conversation_members where conversation_id=c.id and player_id=target;
 end if;
 if p_action='leave' then return jsonb_build_object('ok',true);end if;return private.conversation_json(c.id,u);
end $$;
create function public.conversation_messages(p_conversation uuid,p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,30),1),50);bef bigint:=(p->>'before_id')::bigint;aft bigint:=(p->>'after_id')::bigint;v jsonb;n int;first_id bigint;latest bigint;begin
 perform private.require_active_player(u);perform private.require_conversation(p_conversation,u);
 if bef is not null and aft is not null then perform private.fail('invalid_request');end if;
 with rows as(select id from public.conversation_messages where conversation_id=p_conversation and (bef is null or id<bef) and (aft is null or id>aft) and not private.blocked(u,sender_id) order by case when aft is not null then id end asc,case when aft is null then id end desc limit lim+1),page as(select id,row_number() over(order by case when aft is not null then id end asc,case when aft is null then id end desc) rn from rows)
 select coalesce(jsonb_agg(private.message_json(id,u) order by id) filter(where rn<=lim),'[]'::jsonb),count(*),min(id) filter(where rn<=lim),max(id) filter(where rn<=lim) into v,n,first_id,latest from page;
 return jsonb_build_object('items',v,'next_before',case when aft is null and n>lim then first_id end,'latest_id',latest);
end $$;
create function private.notify_social(u uuid,actor uuid,k text,t text,r uuid) returns void language plpgsql set search_path='' as $$
begin
 if u=actor or private.blocked(u,actor) then return;end if;
 if (k='message' and not coalesce((select notify_messages from public.social_settings where player_id=u),true)) or (k<>'message' and not coalesce((select notify_activity from public.social_settings where player_id=u),true)) then return;end if;
 insert into public.social_notifications(player_id,actor_id,kind,title,resource_id) values(u,actor,k,t,r);
end $$;
create function public.send_message(p_conversation uuid,p_body text,p_client_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();c public.conversations%rowtype;ids uuid[];other uuid;m public.conversation_messages%rowtype;s text;begin
 if p_client_id is null then perform private.fail('idempotency_key_required');end if;
 if char_length(btrim(coalesce(p_body,''))) not between 1 and 4000 then perform private.fail('invalid_request');end if;
 select * into c from public.conversations where id=p_conversation;
 if c.id is null then perform private.fail('conversation_not_found');end if;
 if c.kind='game' then select array_agg(player_id) into ids from public.scheduled_match_players where match_id=c.game_id and status='accepted';else select array_agg(player_id) into ids from public.conversation_members where conversation_id=c.id;end if;
 perform private.lock_active_social_players(array_append(coalesce(ids,'{}'),u));
 select * into c from public.conversations where id=p_conversation for update;perform private.require_conversation(c.id,u);
 if c.kind='game' then perform id from public.scheduled_matches where id=c.game_id for share;perform private.require_conversation(c.id,u);select array_agg(player_id) into ids from public.scheduled_match_players where match_id=c.game_id and status='accepted';end if;
 if c.kind='direct' then
 other:=case when c.direct_low=u then c.direct_high else c.direct_low end;perform private.require_unblocked(u,other);
 select messages_from into s from public.social_settings where player_id=other;
 if coalesce(s,'friends')='nobody' or (coalesce(s,'friends')='friends' and private.friendship_status(u,other)<>'accepted') then perform private.fail('messages_not_allowed');end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('message:'||u||':'||p_client_id,0));
 select * into m from public.conversation_messages where sender_id=u and client_id=p_client_id;
 if m.id is not null then if m.conversation_id<>c.id or m.body<>btrim(p_body) then perform private.fail('version_conflict');end if;return private.message_json(m.id,u);end if;
 if not private.hit_rate_limit('message:'||u,60,60) then perform private.fail('rate_limited');end if;
 insert into public.conversation_messages(conversation_id,sender_id,client_id,body) values(c.id,u,p_client_id,btrim(p_body)) returning * into m;
 update public.conversations set updated_at=now() where id=c.id;
 insert into public.conversation_members(conversation_id,player_id,last_read_id) values(c.id,u,m.id) on conflict(conversation_id,player_id) do update set last_read_id=greatest(public.conversation_members.last_read_id,m.id);
 foreach other in array coalesce(ids,'{}') loop perform private.notify_social(other,u,'message','Новое сообщение',c.id);end loop;
 return private.message_json(m.id,u);
end $$;
create function public.mark_conversation_read(p_conversation uuid,p_message bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.lock_active_social_players(array[u]);perform private.require_conversation(p_conversation,u);
 if not exists(select 1 from public.conversation_messages where id=p_message and conversation_id=p_conversation and not private.blocked(u,sender_id)) then perform private.fail('invalid_request');end if;
 insert into public.conversation_members(conversation_id,player_id,last_read_id) values(p_conversation,u,p_message) on conflict(conversation_id,player_id) do update set last_read_id=greatest(public.conversation_members.last_read_id,p_message);
 update public.social_notifications set read_at=coalesce(read_at,now()) where player_id=u and resource_id=p_conversation and kind='message';return jsonb_build_object('ok',true);
end $$;
create function public.social_groups(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;begin
 perform private.require_active_player(u);
 with rows as(select c.id,row_number() over(order by c.created_at desc,c.id) rn from public.conversations c where c.kind='group' and (c.visibility='public' or private.conversation_access(c.id,u)) and not private.blocked(u,c.owner_id) and exists(select 1 from public.profiles where id=c.owner_id and deleted_at is null) and (p->>'city_id' is null or c.city_id=(p->>'city_id')::int) and (p->>'query' is null or private.norm(c.title) like '%'||private.norm(p->>'query')||'%'))
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'title',c.title,'description',c.description,'visibility',c.visibility,'city_id',c.city_id,'club_id',c.club_id,'owner_id',c.owner_id,'member_count',(select count(*) from public.conversation_members where conversation_id=c.id),'joined',private.conversation_access(c.id,u)) order by rows.rn) filter(where rows.rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows join public.conversations c on c.id=rows.id where rows.rn>off and rows.rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;

create function private.post_visible(p uuid,u uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.social_posts x join public.profiles pr on pr.id=x.author_id where x.id=p and x.deleted_at is null and pr.deleted_at is null and not private.blocked(u,x.author_id)
 and (x.author_id=u or x.visibility='public' or private.friendship_status(u,x.author_id)='accepted')
 and (x.group_id is null or private.conversation_access(x.group_id,u) or exists(select 1 from public.conversations where id=x.group_id and visibility='public' and not private.blocked(u,owner_id))))
$$;
create function private.require_post(p uuid,u uuid) returns void language plpgsql stable set search_path='' as $$
begin if not private.post_visible(p,u) then perform private.fail('post_not_found');end if;end $$;
create function private.post_json(p uuid,u uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',x.id,'author',private.visible_card(u,x.author_id,true),'body',x.body,'visibility',x.visibility,'group_id',x.group_id,'club_id',x.club_id,'created_at',x.created_at,
 'reaction_count',(select count(*) from public.social_reactions r join public.profiles pr on pr.id=r.player_id where r.post_id=x.id and pr.deleted_at is null and not private.blocked(u,r.player_id)),
 'comment_count',(select count(*) from public.social_comments c join public.profiles pr on pr.id=c.author_id where c.post_id=x.id and c.deleted_at is null and pr.deleted_at is null and not private.blocked(u,c.author_id)),
 'my_reaction',(select reaction from public.social_reactions where post_id=x.id and player_id=u)) from public.social_posts x where x.id=p
$$;
create function public.social_post(p_post uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin perform private.require_active_player(u);perform private.require_post(p_post,u);return private.post_json(p_post,u);end $$;
create function public.social_feed(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;begin
 perform private.require_active_player(u);
 if coalesce(p->>'scope','all') not in ('all','following') then perform private.fail('invalid_request');end if;
 with rows as(select x.id,row_number() over(order by x.created_at desc,x.id) rn from public.social_posts x where private.post_visible(x.id,u) and (p->>'group_id' is null or x.group_id=(p->>'group_id')::uuid) and (not coalesce((p->>'mine')::boolean,false) or x.author_id=u)
 and (coalesce(p->>'scope','all')='all' or x.author_id=u or exists(select 1 from public.player_follows where follower_id=u and followed_id=x.author_id)))
 select coalesce(jsonb_agg(private.post_json(id,u) order by rn) filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;
create function public.create_post(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();key uuid;g uuid;club bigint;x public.social_posts%rowtype;b text:=btrim(p->>'body');vis text:=coalesce(p->>'visibility','public');begin
 if private.jtype(p)<>'object' or private.jtype(p->'client_id')<>'string' then perform private.fail('idempotency_key_required');end if;
 begin key:=(p->>'client_id')::uuid;g:=(p->>'group_id')::uuid;club:=(p->>'club_id')::bigint;exception when others then perform private.fail('invalid_request');end;
 if key is null or b is null or char_length(b) not between 1 and 4000 or vis not in ('public','friends') then perform private.fail('invalid_request');end if;
 perform private.lock_active_social_players(array[u]);
 if g is not null then perform private.require_conversation(g,u);if not exists(select 1 from public.conversations where id=g and kind='group') then perform private.fail('invalid_request');end if;end if;
 -- Club-linked news needs verified ownership; public directory creator is not a verified club operator.
 if club is not null and not exists(select 1 from private.admins where user_id=u) then perform private.fail('forbidden');end if;
 if club is not null and not exists(select 1 from public.clubs where id=club) then perform private.fail('club_not_found');end if;
 perform pg_advisory_xact_lock(hashtextextended('post:'||u||':'||key,0));
 select * into x from public.social_posts where author_id=u and client_id=key;
 if x.id is not null then if x.body<>b or x.visibility<>vis or x.group_id is distinct from g or x.club_id is distinct from club then perform private.fail('version_conflict');end if;perform private.require_post(x.id,u);return private.post_json(x.id,u);end if;
 if not private.hit_rate_limit('post:'||u,30,86400) then perform private.fail('rate_limited');end if;
 insert into public.social_posts(author_id,client_id,body,visibility,group_id,club_id) values(u,key,b,vis,g,club) returning * into x;return private.post_json(x.id,u);
end $$;
create function public.delete_post(p_post uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.lock_active_social_players(array[u]);
 if not exists(select 1 from public.social_posts where id=p_post and author_id=u) then perform private.fail('post_not_found');end if;
 update public.social_posts set deleted_at=coalesce(deleted_at,now()),body='Публикация удалена' where id=p_post and author_id=u;return jsonb_build_object('ok',true);
end $$;
create function private.comment_json(c uuid,u uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',id,'post_id',post_id,'author',private.visible_card(u,author_id,true),'body',body,'created_at',created_at) from public.social_comments where id=c
$$;
create function public.post_comments(p_post uuid,p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;begin
 perform private.require_active_player(u);perform private.require_post(p_post,u);
 with rows as(select c.id,row_number() over(order by c.created_at,c.id) rn from public.social_comments c join public.profiles pr on pr.id=c.author_id where c.post_id=p_post and c.deleted_at is null and pr.deleted_at is null and not private.blocked(u,c.author_id))
 select coalesce(jsonb_agg(private.comment_json(id,u) order by rn) filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;
create function public.comment_on_post(p_post uuid,p_body text,p_client_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();x public.social_comments%rowtype;owner uuid;begin
 if p_client_id is null then perform private.fail('idempotency_key_required');end if;
 if char_length(btrim(coalesce(p_body,''))) not between 1 and 1000 then perform private.fail('invalid_request');end if;
 select author_id into owner from public.social_posts where id=p_post;if owner is null then perform private.fail('post_not_found');end if;
 perform private.lock_active_social_players(array[u,owner]);perform id from public.social_posts where id=p_post for share;perform private.require_post(p_post,u);
 perform pg_advisory_xact_lock(hashtextextended('comment:'||u||':'||p_client_id,0));
 select * into x from public.social_comments where author_id=u and client_id=p_client_id;
 if x.id is not null then if x.post_id<>p_post or x.body<>btrim(p_body) then perform private.fail('version_conflict');end if;return private.comment_json(x.id,u);end if;
 if not private.hit_rate_limit('comment:'||u,30,60) then perform private.fail('rate_limited');end if;
 insert into public.social_comments(post_id,author_id,client_id,body) values(p_post,u,p_client_id,btrim(p_body)) returning * into x;
 perform private.notify_social(owner,u,'comment','Новый комментарий',p_post);return private.comment_json(x.id,u);
end $$;
create function public.delete_comment(p_comment uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.lock_active_social_players(array[u]);
 if not exists(select 1 from public.social_comments where id=p_comment and author_id=u) then perform private.fail('not_found');end if;
 update public.social_comments set deleted_at=coalesce(deleted_at,now()),body='Комментарий удалён' where id=p_comment and author_id=u;return jsonb_build_object('ok',true);
end $$;
create function public.react_to_post(p_post uuid,p_reaction text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();owner uuid;begin
 if p_reaction is not null and p_reaction not in ('like','celebrate','support') then perform private.fail('invalid_request');end if;
 select author_id into owner from public.social_posts where id=p_post;if owner is null then perform private.fail('post_not_found');end if;
 perform private.lock_active_social_players(array[u,owner]);perform id from public.social_posts where id=p_post for share;perform private.require_post(p_post,u);
 if p_reaction is null then delete from public.social_reactions where post_id=p_post and player_id=u;
 else insert into public.social_reactions(post_id,player_id,reaction) values(p_post,u,p_reaction) on conflict(post_id,player_id) do update set reaction=excluded.reaction;end if;
 return private.post_json(p_post,u);
end $$;
create function public.social_notifications(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;begin
 perform private.require_active_player(u);
 with rows as(select x.*,row_number() over(order by created_at desc,id) rn from public.social_notifications x where player_id=u and (actor_id is null or not private.blocked(u,actor_id)))
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'title',title,'resource_id',resource_id,'created_at',created_at,'read_at',read_at) order by rn) filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;
create function public.read_social_notifications(p_id uuid default null) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin
 perform private.lock_active_social_players(array[u]);update public.social_notifications set read_at=coalesce(read_at,now()) where player_id=u and (p_id is null or id=p_id);return jsonb_build_object('ok',true);
end $$;
create function public.report_content(p jsonb,p_client_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();t text:=p->>'target_type';target text:=p->>'target_id';r text:=p->>'reason';x public.content_reports%rowtype;c uuid;target_uuid uuid;m bigint;begin
 perform private.lock_active_social_players(array[u]);
 if p_client_id is null then perform private.fail('idempotency_key_required');end if;
 if t is null or t not in ('player','message','post','comment') or r is null or r not in ('spam','harassment','inappropriate','other') or char_length(coalesce(p->>'detail',''))>500 then perform private.fail('invalid_request');end if;
 begin if t='message' then m:=target::bigint;else target_uuid:=target::uuid;end if;exception when others then perform private.fail('invalid_request');end;
 if target is null then perform private.fail('invalid_request');end if;
 if t='player' then perform private.require_active_player(target_uuid);if not private.blocked(u,target_uuid) then perform private.require_visible_player(u,target_uuid);end if;
 elsif t='post' then perform private.require_post(target_uuid,u);
 elsif t='comment' then select post_id into c from public.social_comments where public.social_comments.id=target_uuid and deleted_at is null;if c is null then perform private.fail('not_found');end if;perform private.require_post(c,u);
 else select conversation_id into c from public.conversation_messages where public.conversation_messages.id=m;if c is null then perform private.fail('not_found');end if;perform private.require_conversation(c,u);end if;
 perform pg_advisory_xact_lock(hashtextextended('report:'||u||':'||p_client_id,0));
 select * into x from public.content_reports where reporter_id=u and client_id=p_client_id;
 if x.id is not null then if x.target_type<>t or x.target_id<>target or x.reason<>r or x.detail is distinct from p->>'detail' then perform private.fail('version_conflict');end if;return jsonb_build_object('id',x.id,'status',x.status);end if;
 if not private.hit_rate_limit('report:'||u,20,86400) then perform private.fail('rate_limited');end if;
 insert into public.content_reports(reporter_id,client_id,target_type,target_id,reason,detail) values(u,p_client_id,t,target,r,p->>'detail') returning * into x;return jsonb_build_object('id',x.id,'status',x.status);
end $$;
create function public.moderation_reports(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;begin
 perform private.require_active_player(u);if not exists(select 1 from private.admins where user_id=u) then perform private.fail('forbidden');end if;
 with rows as(select x.*,row_number() over(order by created_at,id) rn from public.content_reports x where status='pending')
 select coalesce(jsonb_agg(to_jsonb(rows)-'rn'-'client_id' order by rn) filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;
create function public.moderate_report(p_report uuid,p_decision text) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=private.require_uid();r public.content_reports%rowtype;begin
 perform private.lock_active_social_players(array[u]);if not exists(select 1 from private.admins where user_id=u) then perform private.fail('forbidden');end if;
 if p_decision is null or p_decision not in ('hide','dismiss') then perform private.fail('invalid_request');end if;
 select * into r from public.content_reports where id=p_report for update;if r.id is null then perform private.fail('report_not_found');end if;
 if r.status<>'pending' then return jsonb_build_object('id',r.id,'status',r.status);end if;
 if p_decision='hide' then
 if r.target_type='post' then update public.social_posts set deleted_at=coalesce(deleted_at,now()),body='Публикация скрыта модератором' where id=r.target_id::uuid;
 elsif r.target_type='comment' then update public.social_comments set deleted_at=coalesce(deleted_at,now()),body='Комментарий скрыт модератором' where id=r.target_id::uuid;
 elsif r.target_type='message' then update public.conversation_messages set deleted_at=coalesce(deleted_at,now()),body='Сообщение скрыто модератором' where id=r.target_id::bigint;
 else perform private.fail('invalid_request');end if;end if;
 update public.content_reports set status=case when p_decision='hide' then 'hidden' else 'dismissed' end,reviewed_by=u,reviewed_at=now() where id=r.id returning * into r;
 return jsonb_build_object('id',r.id,'status',r.status);
end $$;

create function private.anonymize_ecosystem_data() returns trigger language plpgsql security definer set search_path='' as $$
begin if old.deleted_at is null and new.deleted_at is not null then
 delete from private.conversation_creation_keys where player_id=new.id;
 delete from public.social_settings where player_id=new.id;
 delete from public.player_blocks where blocker_id=new.id or blocked_id=new.id;
 delete from public.player_follows where follower_id=new.id or followed_id=new.id;
 delete from public.social_reactions where player_id=new.id;
 delete from public.social_notifications where player_id=new.id or actor_id=new.id;
 delete from public.conversation_members where player_id=new.id;
 update public.conversation_messages set deleted_at=coalesce(deleted_at,now()),body='Сообщение удалено' where sender_id=new.id;
 update public.social_posts set deleted_at=coalesce(deleted_at,now()),body='Публикация удалена' where author_id=new.id;
 update public.social_comments set deleted_at=coalesce(deleted_at,now()),body='Комментарий удалён' where author_id=new.id;
 update public.conversations set title='Группа недоступна',description=null,creation_input=jsonb_build_object('deleted',true),visibility='private' where owner_id=new.id and kind='group';
 update public.content_reports set detail=null where reporter_id=new.id;
 end if;return new;end $$;
create trigger profiles_ecosystem_anonymize after update of deleted_at on public.profiles for each row execute function private.anonymize_ecosystem_data();

-- New helper functions must never become anonymous RPC endpoints by default.
do $$ declare f record; begin
 for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='private' loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);end loop;
 for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(array['friendship_action','social_settings','update_social_settings','blocked_players','block_player','unblock_player','follow_player','unfollow_player','following_players','conversation','conversations','create_conversation','conversation_member_action','conversation_messages','send_message','mark_conversation_read','social_groups','social_post','social_feed','create_post','delete_post','post_comments','comment_on_post','delete_comment','react_to_post','social_notifications','read_social_notifications','report_content','moderation_reports','moderate_report']) loop
 execute format('revoke all on function %s from public,anon,authenticated,service_role',f.sig);execute format('grant execute on function %s to authenticated',f.sig);
 end loop;
end $$;

-- Preserve optimized search and its friendship visibility changes; filter before ranking.
do $$ declare d text; marker text:='and pr.id <> v_uid';begin
 select pg_get_functiondef('public.search_players(jsonb)'::regprocedure) into d;
 if position(marker in d)=0 then raise exception 'search block migration precondition failed';end if;
 execute replace(d,marker,marker||chr(10)||'       and not private.blocked(v_uid, pr.id)');
end $$;

create or replace function public.recent_players(p_limit integer default 20)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  return coalesce((
    select jsonb_agg(private.player_card(x.player_id) || jsonb_build_object('matches_together', x.n) order by x.last desc)
      from (
        select o.player_id, count(*) as n, max(m.played_at) as last
          from public.match_players mp
          join public.matches m on m.id = mp.match_id and m.status in ('pending', 'disputed', 'confirmed')
          join public.match_players o on o.match_id = mp.match_id and o.player_id <> mp.player_id
          join public.profiles p on p.id = o.player_id and p.deleted_at is null
         where mp.player_id = v_uid and not private.blocked(v_uid, o.player_id)
         group by o.player_id
         order by max(m.played_at) desc
         limit greatest(1, least(coalesce(p_limit, 20), 50))
      ) x
  ), '[]'::jsonb);
end;
$$;

-- All existing serializers, including scored history, hide blocked identities.
alter function private.player_card(uuid) rename to player_card_before_blocks;
create function private.player_card(p_player uuid) returns jsonb language sql stable set search_path='' as $$
 select case when private.blocked(auth.uid(),p_player) then jsonb_build_object('id',p_player,'username',null,'display_name','Скрытый игрок','deleted',false,'avatar_path',null,'city',null,'club',null,'preferred_side',null,'is_coach',false,'level',null,'reliability',null)
 else private.player_card_before_blocks(p_player) end
$$;
-- Owners may identify their own block list to undo a block.
create or replace function public.blocked_players() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();begin perform private.require_active_player(u);
 return jsonb_build_object('items',coalesce((select jsonb_agg(private.player_card_before_blocks(blocked_id) order by created_at desc) from public.player_blocks where blocker_id=u),'[]'::jsonb),'next_offset',null);
end $$;
alter function public.player_profile(uuid) set schema private;
alter function private.player_profile(uuid) rename to player_profile_before_follows;
create function public.player_profile(p_player uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();v jsonb;begin
 v:=private.player_profile_before_follows(p_player);
 return v||jsonb_build_object('is_following',exists(select 1 from public.player_follows where follower_id=u and followed_id=p_player),
 'followers_count',(select count(*) from public.player_follows where followed_id=p_player and not private.blocked(u,follower_id)),
 'following_count',(select count(*) from public.player_follows where follower_id=p_player and not private.blocked(u,followed_id)));
end $$;
revoke all on function private.player_card(uuid),private.player_card_before_blocks(uuid),private.player_profile_before_follows(uuid) from public,anon,authenticated,service_role;
revoke all on function public.player_profile(uuid) from public,anon,authenticated,service_role;
grant execute on function public.player_profile(uuid) to authenticated;

create or replace function public.join_scheduled_match(p_match uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); m public.scheduled_matches%rowtype; v_status text; v_admission text;
begin
  perform private.lock_active_social_players(array_append((select array_agg(player_id) from public.scheduled_match_players where match_id=p_match and status='accepted'),v_uid));
  select * into m from public.scheduled_matches where id = p_match for update;
  if not found then perform private.fail('scheduled_match_not_found'); end if;
  if exists(select 1 from public.scheduled_match_players where match_id=p_match and status='accepted' and private.blocked(v_uid,player_id)) then perform private.fail('social_blocked');end if;
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
  if p_decision='accepted' and exists(select 1 from public.scheduled_match_players where match_id=p_match and status='accepted' and private.blocked(p_player,player_id)) then perform private.fail('social_blocked');end if;
  if p_decision = 'accepted' and (select count(*) from public.scheduled_match_players where match_id = p_match and status = 'accepted') >= 4 then perform private.fail('scheduled_match_full'); end if;
  update public.scheduled_match_players set status = p_decision, decided_at = now(), joined_at = case when p_decision = 'accepted' then now() end
    where match_id = p_match and player_id = p_player;
  return private.scheduled_json(p_match, v_uid);
end;
$$;

-- Explicit group membership grants profile visibility between active peers;
-- bilateral blocks still win over this voluntary relationship.
alter function private.socially_visible(uuid,uuid) rename to socially_visible_before_groups;
create function private.socially_visible(p_viewer uuid,p_player uuid) returns boolean language sql stable set search_path='' as $$
 select not private.blocked(p_viewer,p_player) and (private.socially_visible_before_groups(p_viewer,p_player)
 or exists(select 1 from public.conversation_members a join public.conversation_members b on b.conversation_id=a.conversation_id and b.player_id=p_player
 join public.conversations c on c.id=a.conversation_id and c.kind='group' where a.player_id=p_viewer))
$$;

-- Social notifications share the same inbox and privacy preferences as chats.
create function private.notify_relationship_change() returns trigger language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();target uuid;begin
 if actor is null then return new;end if;
 target:=case when new.player_low=actor then new.player_high else new.player_low end;
 if new.status='pending' and (tg_op='INSERT' or old.status is distinct from new.status) then
 perform private.notify_social(target,actor,'friend_request','Новая заявка в друзья',actor);
 elsif new.status='accepted' and old.status is distinct from new.status then
 perform private.notify_social(target,actor,'friend_accepted','Заявка в друзья принята',actor);end if;
 return new;end $$;
create trigger friendships_social_notifications after insert or update of status on public.friendships for each row execute function private.notify_relationship_change();
create function private.notify_game_participation() returns trigger language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();owner uuid;begin
 if actor is null then return new;end if;
 select organizer_id into owner from public.scheduled_matches where id=new.match_id;
 if tg_op='INSERT' or old.status is distinct from new.status then
 if new.status='pending' then perform private.notify_social(owner,actor,'game_request','Новая заявка на игру',new.match_id);
 elsif new.status='accepted' then
 if actor=owner then perform private.notify_social(new.player_id,actor,'game_accepted','Заявка на игру принята',new.match_id);
 else perform private.notify_social(owner,actor,'game_joined','Новый участник игры',new.match_id);end if;
 elsif new.status='rejected' then perform private.notify_social(new.player_id,actor,'game_rejected','Заявка на игру рассмотрена',new.match_id);
 elsif new.status='withdrawn' then perform private.notify_social(owner,actor,'game_left','Участник вышел из игры',new.match_id);end if;
 end if;return new;end $$;
create trigger scheduled_players_social_notifications after insert or update of status on public.scheduled_match_players for each row execute function private.notify_game_participation();
create function private.notify_game_cancellation() returns trigger language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();target uuid;begin
 if actor is not null and old.cancelled_at is null and new.cancelled_at is not null then
 for target in select player_id from public.scheduled_match_players where match_id=new.id and status in ('pending','accepted') loop perform private.notify_social(target,actor,'game_cancelled','Игра отменена',new.id);end loop;end if;return new;end $$;
create trigger scheduled_games_social_notifications after update of cancelled_at on public.scheduled_matches for each row execute function private.notify_game_cancellation();
revoke all on function private.socially_visible(uuid,uuid),private.socially_visible_before_groups(uuid,uuid),private.notify_relationship_change(),private.notify_game_participation(),private.notify_game_cancellation() from public,anon,authenticated,service_role;
