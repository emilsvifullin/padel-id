-- Professional coach data reuses the approved application; visibility remains
-- exactly the same as player_profile and sports event catalogs.
create function tests.test_coach_public_profile_privacy_and_revocation() returns void language plpgsql as $$
declare coach uuid:=tests.player('cpublic_coach');viewer uuid:=tests.player('cpublic_viewer');v jsonb;club bigint;
begin
 insert into public.clubs(city_id,name) values(1,'Клуб тренерского профиля') returning id into club;
 insert into public.coach_applications(player_id,status,experience_years,certification,about,club_id,review_note)
 values(coach,'pending',8,'Сертификат федерации','Групповые занятия и техника игры у сетки',club,'Внутреннее замечание');
 perform tests.act_as(viewer);v:=public.player_profile(coach);
 perform tests.assert_eq(v->'coach','null'::jsonb,'pending professional data stays private');
 perform tests.as_admin();update public.coach_applications set status='approved' where player_id=coach;
 update public.profiles set is_coach=true where id=coach;
 perform tests.act_as(viewer);v:=public.player_profile(coach);
 perform tests.assert_eq(v->'coach'->>'experience_years','8','real approved experience published');
 perform tests.assert_eq(v->'coach'->>'certification','Сертификат федерации','real professional qualification published');
 perform tests.assert_eq(v->'coach'->'club'->>'id',club::text,'club from existing application');
 perform tests.assert(not (v->'coach' ? 'review_note') and not (v->'coach' ? 'submitted_at'),'internal application metadata excluded');
 perform tests.as_admin();update public.profiles set discoverable=false where id=coach;
 perform tests.act_as(viewer);perform tests.expect_error(format('select public.player_profile(%L)',coach),'player_not_found','hidden profile does not expose coach details');
 perform tests.as_admin();update public.profiles set discoverable=true where id=coach;
 perform tests.act_as(viewer);perform public.block_player(coach);
 perform tests.expect_error(format('select public.player_profile(%L)',coach),'player_not_found','block hides professional profile');
 perform public.unblock_player(coach);
 perform tests.as_admin();update public.coach_applications set status='revoked' where player_id=coach;
 update public.profiles set is_coach=false where id=coach;
 perform tests.act_as(viewer);perform tests.assert_eq(public.player_profile(coach)->'coach','null'::jsonb,'revoked data not published');
 perform tests.act_as_anon();perform tests.expect_error(format('select public.player_profile(%L)',coach),'42501','anonymous profile remains forbidden');
end $$;

create function tests.test_coach_schedule_filters_real_trainings_and_visibility() returns void language plpgsql as $$
declare coach uuid:=tests.player('cschedule_coach');other uuid:=tests.player('cschedule_other');viewer uuid:=tests.player('cschedule_viewer');e uuid;v jsonb;
begin
 insert into public.coach_applications(player_id,status,experience_years,about)
 values(coach,'approved',4,'Подтверждённый тренер по паделу'),(other,'approved',6,'Другой подтверждённый тренер');
 update public.profiles set is_coach=true where id in(coach,other);
 perform tests.act_as(coach);e:=(public.create_event(tests.event_payload('training','individual',1))->>'id')::uuid;
 perform tests.act_as(other);perform public.create_event(tests.event_payload('training','group',2));
 perform tests.act_as(viewer);v:=public.events_catalog(jsonb_build_object('organizer_id',coach,'kind','training'));
 perform tests.assert_eq(jsonb_array_length(v->'items'),1,'schedule contains only selected coach');
 perform tests.assert_eq(v->'items'->0->>'id',e::text,'real individually bookable session');
 perform public.event_register(e);v:=public.events_catalog('{"scope":"mine","kind":"training"}');
 perform tests.assert_eq(v->'items'->0->>'id',e::text,'registered session enters existing personal history');
 perform public.block_player(coach);v:=public.events_catalog(jsonb_build_object('organizer_id',coach,'kind','training'));
 perform tests.assert_eq(jsonb_array_length(v->'items'),0,'blocked coach schedule not leaked');
 perform tests.expect_error('select public.events_catalog(''{"organizer_id":"not-a-uuid"}'')','invalid_request','RPC validates malformed organizer');
end $$;
