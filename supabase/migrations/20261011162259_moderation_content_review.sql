-- Moderators inspect only the currently reported item, not an entire private
-- conversation or a retained copy of deleted content. The role gate runs before
-- reading any content; ordinary users retain their existing visibility gates.
create or replace function public.moderation_reports(p jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
 u uuid:=private.require_uid();
 lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);
 off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);
 v jsonb; n int;
begin
 perform private.require_active_player(u);
 if not exists(select 1 from private.admins where user_id=u) then perform private.fail('forbidden');end if;
 with rows as (
  select x.*,row_number() over(order by x.created_at,x.id) rn,
   case x.target_type
    when 'post' then (select jsonb_build_object('body',s.body,'author_name',pr.display_name)
      from public.social_posts s join public.profiles pr on pr.id=s.author_id
      where s.id=x.target_id::uuid and s.deleted_at is null and pr.deleted_at is null)
    when 'comment' then (select jsonb_build_object('body',s.body,'author_name',pr.display_name)
      from public.social_comments s join public.profiles pr on pr.id=s.author_id
      join public.social_posts post on post.id=s.post_id
      where s.id=x.target_id::uuid and s.deleted_at is null and post.deleted_at is null and pr.deleted_at is null)
    when 'message' then (select jsonb_build_object('body',s.body,'author_name',pr.display_name)
      from public.conversation_messages s join public.profiles pr on pr.id=s.sender_id
      where s.id=x.target_id::bigint and s.deleted_at is null and pr.deleted_at is null)
    when 'player' then (select jsonb_build_object('author_name',pr.display_name)
      from public.profiles pr where pr.id=x.target_id::uuid and pr.deleted_at is null)
   end as content
  from public.content_reports x where x.status='pending'
 )
 select coalesce(jsonb_agg(to_jsonb(rows)-'rn'-'client_id' order by rn)
   filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n
 from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim then off+lim end);
end $$;
revoke all on function public.moderation_reports(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.moderation_reports(jsonb) to authenticated;
