create function tests.club_admin(p_user uuid) returns void language plpgsql as $$
begin perform tests.as_admin();insert into private.admins(user_id) values(p_user) on conflict do nothing;perform tests.act_as(p_user);end $$;

create function tests.test_clubs_metadata_permissions_sources_and_versions() returns void language plpgsql as $$
declare user_id uuid:=tests.player('clubs_regular');admin_id uuid:=tests.player('clubs_admin');club bigint;v jsonb;
begin
 perform tests.act_as(user_id);club:=(public.create_club(1,'Реальный клуб каталога')->>'id')::bigint;
 v:=public.club_detail(club);perform tests.assert_eq((v->'viewer'->>'can_edit')::boolean,false,'club creator is not administrator');
 perform tests.assert_eq(v->>'booking_url',null::text,'unknown booking availability is not fabricated');
 perform tests.assert_eq(v->>'latitude',null::text,'missing coordinates are not invented');
 perform tests.expect_error(format('select public.admin_club_update(%s,''{"version":1,"description":"Подмена","reason":"Не разрешено"}'')',club),'forbidden');
 perform tests.club_admin(admin_id);
 v:=public.admin_club_update(club,'{"version":1,"description":"Реальные сведения клуба","address":"Москва, улица Спортивная, 1","latitude":55.75,"longitude":37.6,"photo_urls":["https://images.club.ru/court.jpg"],"amenities":["Душ","Парковка"],"contact_phone":"+7 (999) 123-45-67","website_url":"https://club.ru/","booking_url":"https://booking.club.ru/reserve","booking_verified":true,"reason":"Подтверждено оператором клуба"}');
 perform tests.assert_eq((v->>'metadata_version')::int,2,'metadata version advances');
 perform tests.assert_eq(v->>'name','Реальный клуб каталога','community name stays intact');
 perform tests.assert(v->>'booking_verified_at' is not null,'official booking assertion recorded');
 perform tests.assert_eq(jsonb_array_length(v->'photo_urls'),1,'curated source photos survive reads');
 perform tests.expect_error(format('select public.admin_club_update(%s,''{"version":1,"description":"Старые данные","reason":"Старая версия"}'')',club),'version_conflict');
 v:=public.club_detail(club);perform tests.assert_eq(v->>'description','Реальные сведения клуба','stale writer cannot clobber new metadata');
 perform tests.assert_eq(jsonb_array_length(public.list_clubs(1,'Спортивная')),1,'catalog searches real address');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.club_metadata_audit where club_id=club)::int,1,'one successful mutation audited');
 delete from private.admins ad where ad.user_id=admin_id;perform tests.act_as(admin_id);
 perform tests.expect_error(format('select public.admin_club_update(%s,''{"version":2,"reason":"Администратор отозван"}'')',club),'forbidden');
 perform tests.act_as_anon();perform tests.expect_error(format('select public.club_detail(%s)',club),'42501');
 perform tests.act_as(user_id);perform tests.expect_error('select * from public.club_courts','42501');
 perform tests.expect_error('select * from private.club_metadata_audit','42501');
 perform tests.expect_error(format('select public.club_detail(%s)',club+999999),'club_not_found');
end $$;

create function tests.test_clubs_games_filter_before_pagination_preserves_private_access() returns void language plpgsql as $$
declare a uuid:=tests.player('club_game_owner');b uuid:=tests.player('club_game_reader');club bigint;other bigint;game uuid;hidden uuid;v jsonb;
begin
 perform tests.act_as(a);club:=(public.create_club(1,'Клуб открытых игр')->>'id')::bigint;other:=(public.create_club(1,'Другой клуб открытых игр')->>'id')::bigint;
 perform public.create_scheduled_match(tests.scheduled_payload(null,now()+interval '1 day')||jsonb_build_object('club_id',other));
 game:=(public.create_scheduled_match(tests.scheduled_payload()||jsonb_build_object('club_id',club))->>'id')::uuid;
 hidden:=(public.create_scheduled_match(tests.scheduled_payload()||jsonb_build_object('club_id',club,'visibility','private'))->>'id')::uuid;
 perform tests.act_as(b);v:=public.scheduled_matches(jsonb_build_object('club_id',club,'limit',1));
 perform tests.assert_eq(jsonb_array_length(v->'items'),1,'club filter precedes first page');
 perform tests.assert_eq(v->'items'->0->>'id',game::text,'canonical game belongs to this club');
 perform tests.assert_eq(v->>'next_offset',null::text,'inaccessible private game does not affect pagination');
 perform tests.expect_error(format('select public.scheduled_match(%L)',hidden),'scheduled_match_not_found');
end $$;

create function tests.test_clubs_metadata_validation_and_explicit_clearing() returns void language plpgsql as $$
declare a uuid:=tests.player('clubs_validate');club bigint;p jsonb;v jsonb;
begin
 perform tests.act_as(a);club:=(public.create_club(1,'Клуб валидации')->>'id')::bigint;perform tests.club_admin(a);
 for p in select x from jsonb_array_elements('[
  {"latitude":55.1},{"latitude":null,"longitude":42},{"latitude":91,"longitude":40},
  {"photo_urls":["http://club.ru/photo"]},{"photo_urls":["https://127.0.0.1/secret"]},
  {"photo_urls":["https://club.ru/\\secret"]},{"website_url":"https://user:password@club.ru/"},
  {"website_url":"https://internal/"},{"website_url":"https://a.local/"},
  {"booking_url":"https://club.ru/booking"},{"booking_verified":true},
  {"amenities":[3]},{"amenities":[""]},{"contact_phone":"javascript:evil"},{"name":"Подмена"}
 ]') x loop
  perform tests.expect_error(format('select public.admin_club_update(%s,%L)',club,p||'{"version":1,"reason":"Проверка недопустимого поля"}'),'invalid_request');
 end loop;
 v:=public.admin_club_update(club,'{"version":1,"description":"Сохраняется","address":"Адрес клуба","latitude":55.1,"longitude":40,"website_url":"https://club.ru/","booking_url":"https://club.ru/book","booking_verified":true,"reason":"Сведения проверены"}');
 v:=public.admin_club_update(club,'{"version":2,"address":null,"latitude":null,"longitude":null,"website_url":null,"booking_url":null,"reason":"Ссылка более не актуальна"}');
 perform tests.assert_eq(v->>'description','Сохраняется','omitted field remains untouched');
 perform tests.assert_eq(v->>'address',null::text,'explicit null clears address');
 perform tests.assert_eq(v->>'booking_verified_at',null::text,'clearing booking clears verification too');
 perform tests.assert_eq(v->>'latitude',null::text,'coordinate pair clears');
end $$;

create function tests.test_clubs_courts_stable_identity_archive_and_versions() returns void language plpgsql as $$
declare a uuid:=tests.player('courts_admin');club bigint;other bigint;court uuid:=gen_random_uuid();p jsonb:='{"version":0,"name":"Корт 1","indoor":true,"surface":"Искусственная трава","description":"Официальный корт","is_active":true,"reason":"Подтверждено клубом"}';v jsonb;
begin
 perform tests.act_as(a);club:=(public.create_club(1,'Клуб с кортами')->>'id')::bigint;other:=(public.create_club(1,'Другой клуб с кортами')->>'id')::bigint;
 perform tests.expect_error(format('select public.admin_court_put(%s,%L,%L)',club,court,p),'forbidden');
 perform tests.club_admin(a);v:=public.admin_court_put(club,court,p);
 perform tests.assert_eq(v->>'id',court::text,'court uses supplied stable ID');
 perform tests.assert_eq((public.club_detail(club)->>'courts_count')::int,1,'active court counted');
 v:=public.admin_court_put(club,court,p);perform tests.assert_eq((v->>'version')::int,1,'identical lost-response retry returns actual unchanged court');
 perform tests.expect_error(format('select public.admin_court_put(%s,%L,%L)',club,court,p||'{"name":"Другой корт"}'),'version_conflict');
 perform tests.expect_error(format('select public.admin_court_put(%s,%L,%L)',other,court,p||'{"version":1}'),'not_found');
 v:=public.admin_court_put(club,court,p||'{"version":1,"is_active":false}');
 perform tests.assert_eq((v->>'version')::int,2,'court edit advances version');
 perform tests.assert_eq((public.club_detail(club)->>'courts_count')::int,0,'archived court is not advertised');
 perform tests.assert_eq(jsonb_array_length(public.club_detail(club)->'courts'),1,'admin can inspect archived courts for reactivation');
 perform tests.as_admin();delete from private.admins ad where ad.user_id=a;perform tests.act_as(a);
 perform tests.assert_eq(jsonb_array_length(public.club_detail(club)->'courts'),0,'public detail excludes archived courts');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from public.club_courts where id=court)::int,1,'archive preserves historical ID');
 perform tests.assert_eq((select count(*) from private.club_metadata_audit where club_id=club)::int,2,'court lifecycle audited');
end $$;

create function tests.test_clubs_events_filter_preserves_real_activity_location() returns void language plpgsql as $$
declare a uuid:=tests.player('club_event_owner');club bigint;other bigint;e uuid;v jsonb;
begin
 perform tests.act_as(a);club:=(public.create_club(1,'Клуб мероприятий')->>'id')::bigint;other:=(public.create_club(1,'Другой клуб мероприятий')->>'id')::bigint;
 e:=(public.create_event(tests.event_payload()||jsonb_build_object('club_id',club))->>'id')::uuid;
 perform public.create_event(tests.event_payload()||jsonb_build_object('club_id',other));
 v:=public.events_catalog(jsonb_build_object('club_id',club));
 perform tests.assert_eq(jsonb_array_length(v->'items'),1,'club query excludes other club activities');
 perform tests.assert_eq(v->'items'->0->>'id',e::text,'returned activity is real canonical event');
 perform tests.assert_eq((v->'items'->0->'club'->>'id')::bigint,club,'location identifier retained');
end $$;
