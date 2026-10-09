-- Match history pages are keyed by (played_at, id). Paging by played_at alone
-- skipped a match that shared its played_at with the last item of a page.
-- The cursor is returned in UTC "Z" form so it survives query-string encoding
-- (a literal "+" in a query string decodes as a space).

drop function if exists public.my_matches(text, timestamptz, integer, text);
drop function if exists public.player_matches(uuid, timestamptz, integer, text);

create or replace function private.history_cursor(p_items jsonb, p_limit integer)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_array_length(p_items) = p_limit then jsonb_build_object(
      'next_before', to_char((p_items -> (p_limit - 1) ->> 'played_at')::timestamptz at time zone 'utc',
                             'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'next_before_id', p_items -> (p_limit - 1) -> 'id')
    else jsonb_build_object('next_before', null, 'next_before_id', null)
  end
$$;

create function public.my_matches(p_scope text, p_before timestamptz default null, p_limit integer default 30,
                                  p_type text default null, p_before_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_items jsonb;
begin
  if p_scope not in ('open', 'history') then
    perform private.fail('invalid_request');
  end if;
  if p_type is not null and p_type not in ('friendly', 'ranked') then
    perform private.fail('invalid_request');
  end if;

  if p_scope = 'open' then
    update public.matches m
       set status = 'expired', closed_at = now()
     where m.status in ('pending', 'disputed')
       and m.updated_at < now() - interval '7 days'
       and exists (select 1 from public.match_players mp where mp.match_id = m.id and mp.player_id = v_uid);
    select coalesce(jsonb_agg(private.match_list_item(x.id, v_uid) order by x.needs desc, x.updated_at desc), '[]'::jsonb)
      into v_items
      from (
        select m.id, m.updated_at,
               ((m.status in ('pending', 'disputed') and mp.response = 'pending')
                 or (m.status = 'disputed' and m.created_by = v_uid)) as needs
          from public.matches m
          join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
         where m.status in ('pending', 'disputed')
      ) x;
    return jsonb_build_object('items', v_items, 'next_before', null, 'next_before_id', null);
  end if;

  select coalesce(jsonb_agg(private.match_list_item(x.id, v_uid) order by x.played_at desc, x.id), '[]'::jsonb)
    into v_items
    from (
      select m.id, m.played_at
        from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = v_uid
       where m.status = 'confirmed'
         and (p_before is null
              or m.played_at < p_before
              or (m.played_at = p_before and p_before_id is not null and m.id > p_before_id))
         and (p_type is null or m.match_type = p_type)
       order by m.played_at desc, m.id
       limit v_limit
    ) x;

  return jsonb_build_object('items', v_items) || private.history_cursor(v_items, v_limit);
end;
$$;

create function public.player_matches(p_player uuid, p_before timestamptz default null, p_limit integer default 30,
                                      p_type text default null, p_before_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_limit integer := greatest(1, least(coalesce(p_limit, 30), 50));
  v_items jsonb;
begin
  if not exists (select 1 from public.profiles where id = p_player) then
    perform private.fail('player_not_found');
  end if;
  if p_type is not null and p_type not in ('friendly', 'ranked') then
    perform private.fail('invalid_request');
  end if;
  select coalesce(jsonb_agg(
           private.match_list_item(x.id, v_uid) || jsonb_build_object(
             'subject_team', x.team,
             'subject_rating_delta', (select round((e.mu_after - e.mu_before)::numeric, 3) from public.rating_events e
                                      where e.match_id = x.id and e.player_id = p_player)
           ) order by x.played_at desc, x.id), '[]'::jsonb)
    into v_items
    from (
      select m.id, m.played_at, mp.team
        from public.matches m
        join public.match_players mp on mp.match_id = m.id and mp.player_id = p_player
       where m.status = 'confirmed'
         and (p_before is null
              or m.played_at < p_before
              or (m.played_at = p_before and p_before_id is not null and m.id > p_before_id))
         and (p_type is null or m.match_type = p_type)
       order by m.played_at desc, m.id
       limit v_limit
    ) x;
  return jsonb_build_object('items', v_items) || private.history_cursor(v_items, v_limit);
end;
$$;

revoke all on function private.history_cursor(jsonb, integer) from public, anon, authenticated, service_role;
revoke all on function public.my_matches(text, timestamptz, integer, text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.player_matches(uuid, timestamptz, integer, text, uuid) from public, anon, authenticated, service_role;
grant execute on function public.my_matches(text, timestamptz, integer, text, uuid) to authenticated;
grant execute on function public.player_matches(uuid, timestamptz, integer, text, uuid) to authenticated;
