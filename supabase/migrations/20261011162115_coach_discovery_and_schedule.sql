-- Reuse the approved coach application: publish only its professional fields,
-- after the existing profile privacy/block/deletion checks. Review metadata,
-- reviewer identities and pending/revoked applications remain private.
alter function public.player_profile(uuid) set schema private;
alter function private.player_profile(uuid) rename to player_profile_before_coach;
create function public.player_profile(p_player uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; c jsonb;
begin
 v := private.player_profile_before_coach(p_player);
 select jsonb_build_object('experience_years',a.experience_years,
   'certification',nullif(btrim(a.certification),''),'about',a.about,
   'club',(select jsonb_build_object('id',cl.id,'name',cl.name) from public.clubs cl where cl.id=a.club_id))
 into c from public.coach_applications a join public.profiles pr on pr.id=a.player_id
 where a.player_id=p_player and a.status='approved' and pr.is_coach and pr.deleted_at is null;
 return v || jsonb_build_object('coach',c);
end $$;
revoke all on function private.player_profile_before_coach(uuid) from public,anon,authenticated,service_role;
revoke all on function public.player_profile(uuid) from public,anon,authenticated,service_role;
grant execute on function public.player_profile(uuid) to authenticated;

-- Filter the same event catalog instead of inventing a separate schedule.
-- Existing event visibility gates still apply, including mutual blocks.
create or replace function public.events_catalog(p jsonb default '{}') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=private.require_uid();v_city integer;v_club bigint;v_organizer uuid;v_kind text;v_scope text;v_limit int;v_offset int;items jsonb;more boolean;
begin
 perform private.require_active_player(u);
 if private.jtype(p)<>'object' then perform private.fail('invalid_request');end if;
 begin v_city:=(p->>'city_id')::integer;v_club:=(p->>'club_id')::bigint;v_organizer:=(p->>'organizer_id')::uuid;v_kind:=p->>'kind';v_scope:=coalesce(p->>'scope','upcoming');
  v_limit:=coalesce((p->>'limit')::int,30);v_offset:=coalesce((p->>'offset')::int,0);
 exception when others then perform private.fail('invalid_request');end;
 if v_kind is not null and v_kind not in ('training','tournament') or v_scope not in ('mine','upcoming') or v_limit not between 1 and 50 or v_offset not between 0 and 1000 or v_club<=0 then perform private.fail('invalid_request');end if;
 with rows as(select e.id,row_number() over(order by e.starts_at,e.id) rn from public.sports_events e
  where private.event_access(e.id,u) and (v_city is null or e.city_id=v_city) and (v_club is null or e.club_id=v_club) and (v_kind is null or e.kind=v_kind) and (v_organizer is null or e.organizer_id=v_organizer)
   and case when v_scope='upcoming' then e.status='open' and e.starts_at>now()
    else e.organizer_id=u or exists(select 1 from public.event_registrations r where r.event_id=e.id and r.player_id=u) end)
 select coalesce(jsonb_agg(private.event_json(id,u,false) order by rn) filter(where rn<=v_offset+v_limit),'[]'::jsonb),
  coalesce(bool_or(rn>v_offset+v_limit),false) into items,more from rows where rn>v_offset and rn<=v_offset+v_limit+1;
 return jsonb_build_object('items',items,'next_offset',case when more then v_offset+v_limit end);
end $$;
