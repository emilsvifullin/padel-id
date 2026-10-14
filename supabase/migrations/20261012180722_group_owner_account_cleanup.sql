-- The account service is the sole production writer of deleted_at. Serialize
-- account cleanup before it acquires any profile/conversation locks: two owners
-- deleting accounts simultaneously must not hand a group to an already deleting
-- successor. Ordinary chat/member actions keep their existing lock order.
alter function public.svc_anonymize_account(uuid) set schema private;
alter function private.svc_anonymize_account(uuid) rename to svc_anonymize_account_before_group_cleanup;
create function public.svc_anonymize_account(p_user uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended('padelid:account-group-cleanup',0));
 perform private.svc_anonymize_account_before_group_cleanup(p_user);
end $$;
revoke all on function private.svc_anonymize_account_before_group_cleanup(uuid) from public,anon,authenticated,service_role;
revoke all on function public.svc_anonymize_account(uuid) from public,anon,authenticated,service_role;
grant execute on function public.svc_anonymize_account(uuid) to service_role;

alter table public.conversations add column archived_at timestamptz;
alter table public.conversations add constraint conversations_archive_group_only check(archived_at is null or kind='group');

-- Transfer before the established AFTER cleanup erases the creator membership
-- and authored content. Metadata/history belong to the continuing group; the
-- deleted creator's original publication input and idempotency identity do not.
create function private.handoff_groups_before_account_deletion() returns trigger
language plpgsql security definer set search_path='' as $$
declare group_id uuid; successor uuid;
begin
 if old.deleted_at is null and new.deleted_at is not null then
  for group_id in select c.id from public.conversations c
   where c.kind='group' and c.owner_id=new.id and c.archived_at is null order by c.id for update
  loop
   -- Stale privileged membership rows must not strand the remaining members:
   -- send_message deliberately requires every canonical member to be active.
   delete from public.conversation_members cm where cm.conversation_id=group_id and cm.player_id<>new.id
    and not exists(select 1 from public.profiles p join public.player_ratings rating on rating.player_id=p.id
     where p.id=cm.player_id and p.deleted_at is null);
   select cm.player_id into successor from public.conversation_members cm
    join public.profiles p on p.id=cm.player_id
    join public.player_ratings rating on rating.player_id=p.id
    where cm.conversation_id=group_id and cm.player_id<>new.id and p.deleted_at is null
     and not private.blocked(new.id,cm.player_id)
    order by cm.joined_at,cm.player_id limit 1;
   if successor is not null then
    update public.conversation_members set role=case when player_id=successor then 'owner' else 'member' end
     where conversation_id=group_id;
    update public.conversations set owner_id=successor,client_id=gen_random_uuid(),creation_input='{}',updated_at=now()
     where id=group_id;
   else
    -- No eligible owner: retain history, but revoke access and discovery. The
    -- existing cleanup anonymizes title/description and the creator's messages.
    update public.conversations set archived_at=now(),visibility='private',updated_at=now() where id=group_id;
    delete from public.conversation_members where conversation_id=group_id;
   end if;
  end loop;
 end if;
 return new;
end $$;
create trigger profiles_group_handoff before update of deleted_at on public.profiles
 for each row execute function private.handoff_groups_before_account_deletion();
revoke all on function private.handoff_groups_before_account_deletion() from public,anon,authenticated,service_role;

-- Reuse the authoritative access gate for lists, history, posts and push
-- delivery. Direct/game chats retain their established tombstone/lineup rules.
create or replace function private.conversation_access(c uuid,u uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.conversations x where x.id=c and x.archived_at is null and
 (case when x.kind='game' then exists(select 1 from public.scheduled_match_players sp where sp.match_id=x.game_id and sp.player_id=u and sp.status='accepted')
 else exists(select 1 from public.conversation_members cm where cm.conversation_id=x.id and cm.player_id=u) end)
 and (x.kind<>'direct' or not private.blocked(x.direct_low,x.direct_high))
 and (x.kind<>'group' or exists(select 1 from public.profiles p where p.id=x.owner_id and p.deleted_at is null)))
$$;
