-- Club news uses existing posts, authors, moderation, privacy and pagination.
-- Only create_post's live verified admin gate can attach a club; directory
-- authorship never grants club-publishing authority. No separate news table.
create or replace function private.post_json(p uuid,u uuid) returns jsonb language sql stable set search_path='' as $$
 select jsonb_build_object('id',x.id,'author',private.visible_card(u,x.author_id,true),'body',x.body,'visibility',x.visibility,'group_id',x.group_id,'club_id',x.club_id,'club',(select jsonb_build_object('id',cl.id,'name',cl.name) from public.clubs cl where cl.id=x.club_id),'created_at',x.created_at,
 'reaction_count',(select count(*) from public.social_reactions r join public.profiles pr on pr.id=r.player_id where r.post_id=x.id and pr.deleted_at is null and not private.blocked(u,r.player_id)),
 'comment_count',(select count(*) from public.social_comments c join public.profiles pr on pr.id=c.author_id where c.post_id=x.id and c.deleted_at is null and pr.deleted_at is null and not private.blocked(u,c.author_id)),
 'my_reaction',(select reaction from public.social_reactions where post_id=x.id and player_id=u)) from public.social_posts x where x.id=p
$$;

create or replace function public.social_feed(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();lim int:=least(greatest(coalesce((p->>'limit')::int,20),1),50);off int:=least(greatest(coalesce((p->>'offset')::int,0),0),1000);v jsonb;n int;club bigint;begin
 perform private.require_active_player(u);
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 if p ? 'club_id' and p->'club_id'<>'null'::jsonb then
  if private.jtype(p->'club_id')<>'number' or (p->>'club_id') !~ '^[1-9][0-9]*$' then perform private.fail('invalid_request');end if;
  begin club:=(p->>'club_id')::bigint;exception when others then perform private.fail('invalid_request');end;
  if club>9007199254740991 then perform private.fail('invalid_request');end if;
 end if;
 if coalesce(p->>'scope','all') not in ('all','following') then perform private.fail('invalid_request');end if;
 with rows as(select x.id,row_number() over(order by x.created_at desc,x.id) rn from public.social_posts x where private.post_visible(x.id,u) and (club is null or x.club_id=club) and (p->>'group_id' is null or x.group_id=(p->>'group_id')::uuid) and (not coalesce((p->>'mine')::boolean,false) or x.author_id=u)
 and (coalesce(p->>'scope','all')='all' or x.author_id=u or exists(select 1 from public.player_follows where follower_id=u and followed_id=x.author_id)))
 select coalesce(jsonb_agg(private.post_json(id,u) order by rn) filter(where rn<=off+lim),'[]'::jsonb),count(*) into v,n from rows where rn>off and rn<=off+lim+1;
 return jsonb_build_object('items',v,'next_offset',case when n>lim and off+lim<=1000 then off+lim end);
end $$;

-- CREATE OR REPLACE retains privileges; keep the boundary explicit as well.
revoke all on function private.post_json(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.social_feed(jsonb) from public,anon,authenticated,service_role;
grant execute on function public.social_feed(jsonb) to authenticated;
