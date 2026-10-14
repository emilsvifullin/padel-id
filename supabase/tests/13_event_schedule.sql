create function tests.test_event_schedule_preserves_enrollment_and_replay_identity() returns void language plpgsql as $$
declare coach uuid:=tests.player('edit_coach');student uuid:=tests.player('edit_student');outsider uuid:=tests.player('edit_out');
 e uuid;v jsonb;body jsonb;notification_count int;
begin
 insert into public.coach_applications(player_id,status,experience_years,about) values(coach,'approved',4,'Подтверждённый тренер по паделу');
 update public.profiles set is_coach=true where id=coach;
 perform tests.act_as(coach);e:=(public.create_event(tests.event_payload('training','group',2))->>'id')::uuid;
 perform tests.act_as(student);perform public.event_register(e);
 body:=jsonb_build_object('version',1,'title','Перенесённая тренировка','description','Новые условия',
  'starts_at',now()+interval '3 days','duration_minutes',60,'city_id',1,'club_id',null,
  'location','Корт 3','specialization','Работа у сетки','price_rub',1200);
 perform tests.act_as(outsider);perform tests.expect_error(format('select public.event_update(%L,%L)',e,body),'organizer_required','foreign actor cannot reschedule');
 perform tests.act_as(coach);v:=public.event_update(e,body);
 perform tests.assert_eq(v->>'metadata_version','2','canonical metadata version advances');
 perform tests.assert_eq(v->>'registered_count','1','rescheduling preserves enrollment');
 perform tests.assert_eq(v->'registrations'->0->'player'->>'id',student::text,'same actual student remains');
 perform tests.assert_eq(public.event_update(e,body)->>'metadata_version','2','lost response replay returns same version');
 perform tests.expect_error(format('select public.event_update(%L,%L)',e,body||'{"title":"Чужая старая правка"}'),'event_version_conflict','stale divergent request cannot overwrite');
 perform tests.act_as(student);perform tests.assert_eq(public.event_detail(e)->>'title','Перенесённая тренировка','student sees canonical updated conditions');
 select count(*) into notification_count from jsonb_array_elements(public.social_notifications()->'items') n where n->>'title'='Обновлены условия события';
 perform tests.assert_eq(notification_count,1,'replay does not duplicate update notification');
 perform tests.as_admin();update public.sports_events set starts_at=now()-interval '1 minute' where id=e;
 perform tests.act_as(coach);perform tests.expect_error(format('select public.event_update(%L,%L)',e,body||'{"version":2}'),'event_roster_locked','started session cannot be rewritten');
end $$;

create function tests.test_personal_upcoming_events_filter_before_pagination() returns void language plpgsql as $$
declare owner uuid:=tests.player('home_evt_owner');viewer uuid:=tests.player('home_evt_viewer');
 past uuid;future uuid;invited uuid;v jsonb;
begin
 perform tests.act_as(owner);past:=(public.create_event(tests.event_payload())->>'id')::uuid;
 future:=(public.create_event(tests.event_payload())->>'id')::uuid;
 invited:=(public.create_event(tests.event_payload('tournament','round_robin',4))->>'id')::uuid;
 perform tests.act_as(viewer);perform public.event_register(past);perform public.event_register(future);
 perform public.friendship_action(owner,'request');perform tests.act_as(owner);perform public.friendship_action(viewer,'accept');
 perform public.event_register(invited,viewer);
 perform tests.as_admin();update public.sports_events set starts_at=now()-interval '1 day',status='completed' where id=past;
 perform tests.act_as(viewer);v:=public.events_catalog('{"scope":"mine","upcoming_only":true,"limit":1}');
 perform tests.assert_eq(jsonb_array_length(v->'items'),1,'past history does not fill upcoming page');
 perform tests.assert_eq(v->'items'->0->>'id',future::text,'only accepted future session appears');
 perform tests.assert_eq(v->'next_offset','null'::jsonb,'pending pair invite excluded before pagination');
 perform tests.expect_error('select public.events_catalog(''{"scope":"upcoming","upcoming_only":true}'')','invalid_request','personal flag does not become public activity query');
 perform tests.expect_error('select public.events_catalog(''{"scope":"mine","upcoming_only":"true"}'')','invalid_request','RPC rejects textual boolean');
end $$;
