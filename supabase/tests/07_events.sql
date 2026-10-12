-- Real user/role regressions for training enrollment and confirmed tournament points.
create function tests.event_payload(kind text default 'tournament',fmt text default 'americano',cap int default 4) returns jsonb language sql as $$
 select jsonb_build_object('client_id',gen_random_uuid(),'kind',kind,'format',fmt,'title','Тестовое событие','description','Правила и условия участия',
  'starts_at',now()+interval '2 days','duration_minutes',90,'city_id',1,'club_id',null,'location','Корт № 2','capacity',cap,
  'min_level',0,'max_level',7,'specialization','Работа у сетки','price_rub',1000,'round_count',3,'points_per_game',32)
$$;
create function tests.event_start(p_event uuid) returns void language plpgsql as $$
begin perform tests.as_admin();update public.sports_events set starts_at=now()-interval '10 minutes' where id=p_event;end $$;
create function tests.event_players(prefix text,n int) returns uuid[] language plpgsql as $$
declare p uuid[]:='{}';i int;begin for i in 1..n loop p:=p||tests.player(prefix||chr(96+i));end loop;return p;end $$;
create function tests.event_confirm_round(p_event uuid) returns void language plpgsql as $$
declare g public.event_games;p uuid[];u uuid;i int;owner uuid;r int;
begin
 perform tests.as_admin();select organizer_id,current_round into owner,r from public.sports_events where id=p_event;
 for g in select * from public.event_games where event_id=p_event and round_number=r order by court loop
  perform tests.act_as(owner);perform public.event_game_score(p_event,g.id,jsonb_build_object('version',1,'points1',20,'points2',12));
  p:=array[g.player1,g.player2,g.player3,g.player4];
  foreach u in array p loop perform tests.act_as(u);perform public.event_game_confirm(p_event,g.id,2);end loop;
 end loop;perform tests.as_admin();
end $$;

create function tests.test_events_training_permissions_capacity_and_cleanup() returns void language plpgsql as $$
declare owner uuid:=tests.player('evt_coach');p uuid[]:=tests.event_players('evt_student',3);body jsonb:=tests.event_payload('training','group',2);e uuid;v jsonb;
begin
 perform tests.act_as(owner);perform tests.expect_error(format('select public.create_event(%L)',body),'event_coach_required');
 perform tests.as_admin();insert into public.coach_applications(player_id,status,experience_years,about) values(owner,'approved',4,'Подтверждённый тренер по паделу');update public.profiles set is_coach=true where id=owner;
 perform tests.act_as(owner);e:=(public.create_event(body)->>'id')::uuid;
 perform tests.assert_eq(public.create_event(body)->>'id',e::text,'same publication is idempotent');
 perform tests.expect_error(format('select public.create_event(%L)',body||'{"title":"Другое название"}'),'event_version_conflict');
 perform tests.act_as(p[1]);perform public.event_register(e);perform public.event_register(e);
 perform tests.act_as(p[2]);perform public.event_register(e);
 perform tests.act_as(p[3]);perform tests.expect_error(format('select public.event_register(%L)',e),'event_full');
 perform tests.expect_error(format('select public.event_manage(%L,''cancel'')',e),'organizer_required');
 perform tests.act_as(p[1]);perform public.event_manage(e,'leave');
 perform tests.act_as(p[3]);perform public.event_register(e);
 perform tests.act_as(owner);v:=public.event_detail(e);perform tests.assert_eq((v->>'registered_count')::int,2,'capacity not exceeded and leave frees a place');
 perform public.event_manage(e,'remove',p[2]);
 perform tests.as_admin();update public.profiles set is_coach=false where id=owner;
 perform tests.assert_eq((select status from public.sports_events where id=e),'cancelled','coach revocation cancels unfinished training');
 perform tests.act_as(p[3]);perform tests.expect_error(format('select public.event_register(%L)',e),'event_closed');
 perform tests.act_as_anon();perform tests.expect_error('select public.events_catalog()','42501');
 perform tests.act_as(p[1]);perform tests.expect_error('select * from public.sports_events','42501');
end $$;

create function tests.test_events_score_confirmation_version_and_rating_isolation() returns void language plpgsql as $$
declare p uuid[]:=tests.event_players('evt_score',5);e uuid;v jsonb;g uuid;mus jsonb;
begin
 perform tests.act_as(p[1]);e:=(public.create_event(tests.event_payload())->>'id')::uuid;
 for i in 1..4 loop perform tests.act_as(p[i]);perform public.event_register(e);end loop;
 perform tests.act_as(p[1]);perform tests.expect_error(format('select public.event_generate_round(%L,0)',e),'event_not_started');
 perform tests.event_start(e);select jsonb_agg(jsonb_build_object('id',player_id,'mu',mu,'n',ranked_matches) order by player_id) into mus from public.player_ratings where player_id=any(p);
 perform tests.act_as(p[1]);v:=public.event_generate_round(e,0);g:=(v->'games'->0->>'id')::uuid;
 perform tests.expect_error(format('select public.event_generate_round(%L,0)',e),'event_version_conflict');
 perform tests.expect_error(format('select public.event_generate_round(%L,1)',e),'event_round_pending');
 perform tests.expect_error(format('select public.event_game_score(%L,%L,''{"version":1,"points1":16,"points2":15}'')',e,g),'event_invalid_points');
 perform public.event_game_score(e,g,'{"version":1,"points1":20,"points2":12}');
 perform public.event_game_score(e,g,'{"version":1,"points1":20,"points2":12}');
 perform tests.act_as(p[5]);perform tests.expect_error(format('select public.event_game_confirm(%L,%L,2)',e,g),'event_not_participant');
 perform tests.act_as(p[1]);perform public.event_game_confirm(e,g,2);
 v:=public.event_detail(e);perform tests.assert_eq((v->'standings'->0->>'points')::int,0,'unconfirmed points never enter standings');
 perform public.event_game_score(e,g,'{"version":2,"points1":21,"points2":11}');
 perform tests.expect_error(format('select public.event_game_confirm(%L,%L,2)',e,g),'event_version_conflict');
 for i in 1..3 loop perform tests.act_as(p[i]);perform public.event_game_confirm(e,g,3);end loop;
 v:=public.event_detail(e);perform tests.assert_eq((v->'standings'->0->>'points')::int,0,'three confirmations remain pending');
 perform tests.act_as(p[4]);v:=public.event_game_confirm(e,g,3);perform tests.assert_eq((v->'standings'->0->>'points')::int,21,'four confirmations include points');
 perform public.event_game_confirm(e,g,3);
 perform tests.act_as(p[1]);perform tests.expect_error(format('select public.event_game_score(%L,%L,''{"version":3,"points1":20,"points2":12}'')',e,g),'event_game_confirmed');
 perform tests.as_admin();perform tests.assert_eq((select jsonb_agg(jsonb_build_object('id',player_id,'mu',mu,'n',ranked_matches) order by player_id) from public.player_ratings where player_id=any(p)),mus,'tournament points leave sporting ratings unchanged');
 perform tests.assert_eq((select count(*) from public.matches where created_by=any(p))::int,0,'no fabricated canonical match');
end $$;

create function tests.test_events_americano_balanced_schedule() returns void language plpgsql as $$
declare p uuid[]:=tests.event_players('evt_am',8);e uuid;n int;r int;v jsonb;
begin
 for n in 4..8 by 4 loop
  perform tests.act_as(p[1]);e:=(public.create_event(tests.event_payload('tournament','americano',n))->>'id')::uuid;
  for i in 1..n loop perform tests.act_as(p[i]);perform public.event_register(e);end loop;
  perform tests.event_start(e);
  for r in 1..n-1 loop perform tests.act_as(p[1]);perform public.event_generate_round(e,r-1);perform tests.event_confirm_round(e);end loop;
  perform tests.assert_eq((select status from public.sports_events where id=e),'completed','finished Americano after confirmed last round');
  perform tests.assert_eq((select count(*) from public.event_games where event_id=e)::int,n*(n-1)/4,'every round has complete courts');
  perform tests.assert(not exists(select 1 from(
   select round_number,unnest(array[player1,player2,player3,player4]) player from public.event_games where event_id=e
  ) t group by round_number,player having count(*)<>1),'no player occurs twice in a round');
  perform tests.assert_eq((select count(*) from(
   select least(a,b),greatest(a,b),count(*) from public.event_games g,
    lateral(values(g.player1,g.player2),(g.player3,g.player4)) t(a,b) where event_id=e group by least(a,b),greatest(a,b) having count(*)=1
  ) t)::int,n*(n-1)/2,'every player partners every other once');
  perform tests.assert_eq((select count(*) from(
   select least(a,b),greatest(a,b),count(*) from public.event_games g,
    lateral(values(g.player1,g.player3),(g.player1,g.player4),(g.player2,g.player3),(g.player2,g.player4)) t(a,b)
    where event_id=e group by least(a,b),greatest(a,b) having count(*)=2
  ) t)::int,n*(n-1)/2,'every player opposes every other twice');
 end loop;
end $$;

create function tests.test_events_fixed_team_round_robin_and_partner_consent() returns void language plpgsql as $$
declare p uuid[]:=tests.event_players('evt_rr',16);e uuid;n int;r int;v jsonb;
begin
 for n in 4..16 by 4 loop
  perform tests.act_as(p[1]);e:=(public.create_event(tests.event_payload('tournament','round_robin',n))->>'id')::uuid;
  for i in 1..n by 2 loop
   perform tests.act_as(p[i]);perform public.event_register(e,p[i+1]);
  end loop;
  perform tests.event_start(e);perform tests.act_as(p[1]);perform tests.expect_error(format('select public.event_generate_round(%L,0)',e),'event_format_roster','partner invitations require consent');
  perform tests.as_admin();update public.sports_events set starts_at=now()+interval '1 hour' where id=e;
  for i in 2..n by 2 loop perform tests.act_as(p[i]);perform public.event_register(e);end loop;
  perform tests.event_start(e);
  for r in 1..n/2-1 loop perform tests.act_as(p[1]);perform public.event_generate_round(e,r-1);perform tests.event_confirm_round(e);end loop;
  perform tests.assert_eq((select count(*) from public.event_games where event_id=e)::int,(n/2)*(n/2-1)/2,'every team meets every other exactly once');
  perform tests.assert(not exists(select 1 from public.event_games g join public.event_registrations a on a.event_id=e and a.player_id=g.player1 join public.event_registrations b on b.event_id=e and b.player_id=g.player2 where g.event_id=e and a.team_id<>b.team_id),'first team remains fixed');
  perform tests.assert(not exists(select 1 from public.event_games g join public.event_registrations a on a.event_id=e and a.player_id=g.player3 join public.event_registrations b on b.event_id=e and b.player_id=g.player4 where g.event_id=e and a.team_id<>b.team_id),'second team remains fixed');
  perform tests.act_as(p[1]);v:=public.event_detail(e);perform tests.assert_eq(jsonb_array_length(v->'standings'),n/2,'standings group fixed teams');
 end loop;
end $$;

create function tests.test_events_mexicano_king_court_and_deleted_player() returns void language plpgsql as $$
declare p uuid[]:=tests.event_players('evt_adaptive',16);e uuid;n int;r int;fmt text;v jsonb;g uuid;
begin
 foreach fmt in array array['mexicano','king_court'] loop
  for n in 4..16 by 4 loop
   perform tests.act_as(p[1]);e:=(public.create_event(tests.event_payload('tournament',fmt,n))->>'id')::uuid;
   for i in 1..n loop perform tests.act_as(p[i]);perform public.event_register(e);end loop;
   perform tests.event_start(e);
   for r in 1..3 loop
    perform tests.act_as(p[1]);v:=public.event_generate_round(e,r-1);
    if fmt='king_court' then g:=(v->'games'->((r-1)*n/4)->>'id')::uuid;perform tests.expect_error(format('select public.event_game_score(%L,%L,''{"version":1,"points1":16,"points2":16}'')',e,g),'event_invalid_points');end if;
    perform tests.event_confirm_round(e);
   end loop;
   perform tests.assert_eq((select count(*) from public.event_games where event_id=e)::int,3*n/4,'complete adaptive tournament courts');
   perform tests.assert(not exists(select 1 from(
    select round_number,unnest(array[player1,player2,player3,player4]) player from public.event_games where event_id=e
   ) t group by round_number,player having count(*)<>1),'adaptive rounds include every player exactly once');
  end loop;
 end loop;
 perform tests.act_as(p[1]);e:=(public.create_event(tests.event_payload())->>'id')::uuid;
 for i in 1..4 loop perform tests.act_as(p[i]);perform public.event_register(e);end loop;
 perform tests.event_start(e);perform tests.act_as(p[1]);perform public.event_generate_round(e,0);
 perform tests.as_admin();perform public.svc_anonymize_account(p[2]);
 perform tests.assert_eq((select status from public.sports_events where id=e),'cancelled','deletion cancels a locked roster safely');
 perform tests.act_as(p[1]);perform tests.expect_error(format('select public.event_generate_round(%L,1)',e),'event_closed');
end $$;
