-- Club news reuses real publications and permission/visibility rules. All test
-- fixtures execute inside rollback transactions in the disposable database.
create function tests.test_club_news_live_role_gate_and_replay() returns void language plpgsql as $$
declare author uuid:=tests.player('cn_role_author');creator uuid:=tests.player('cn_role_creator');club bigint;p jsonb;key uuid:=gen_random_uuid();posted jsonb;
begin
 insert into public.clubs(city_id,name,created_by) values(1,'Клуб новостей полномочия',creator) returning id into club;
 p:=jsonb_build_object('client_id',key,'club_id',club,'body','Настоящая новость клуба','visibility','public');
 perform tests.act_as(creator);perform tests.expect_error(format('select public.create_post(%L)',p),'forbidden','directory creator cannot impersonate a verified operator');
 perform tests.as_admin();insert into private.admins(user_id) values(author);
 perform tests.act_as(author);posted:=public.create_post(p);
 perform tests.assert_eq(public.create_post(p)->>'id',posted->>'id','lost-response replay returns same publication');
 perform tests.assert_eq(posted->'club'->>'id',club::text,'real linked club attributed');
 perform tests.expect_error(format('select public.create_post(%L)',p||'{"body":"Изменённый текст"}'),'version_conflict','same key cannot silently replace text');
 perform tests.as_admin();delete from private.admins where user_id=author;
 perform tests.act_as(author);perform tests.expect_error(format('select public.create_post(%L)',p),'forbidden','current role checked even on same-session replay');
 perform tests.expect_error(format('select public.create_post(%L)',p||jsonb_build_object('client_id',gen_random_uuid())),'forbidden','revoked role cannot publish another club item');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from public.social_posts where author_id=author),1::bigint,'revocation/replay creates no duplicate content');
end $$;

create function tests.test_club_news_filter_precedes_pagination_and_keeps_attribution() returns void language plpgsql as $$
declare author uuid:=tests.player('cn_page_author');reader uuid:=tests.player('cn_page_reader');club bigint;other bigint;a uuid;b uuid;p jsonb;v jsonb;
begin
 insert into private.admins(user_id) values(author);
 insert into public.clubs(city_id,name) values(1,'Клуб новостей выбранный') returning id into club;
 insert into public.clubs(city_id,name) values(1,'Клуб новостей другой') returning id into other;
 perform tests.act_as(author);
 a:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'club_id',club,'body','Первая клубная новость'))->>'id')::uuid;
 b:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'club_id',club,'body','Вторая клубная новость'))->>'id')::uuid;
 perform public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'club_id',other,'body','Новость другого клуба'));
 perform tests.as_admin();update public.social_posts set created_at=now()-interval '2 days' where id=a;
 update public.social_posts set created_at=now()-interval '1 day' where id=b;
 -- Crowd the default newest prefix with unrelated posts; a client-side filter
 -- would incorrectly show an empty club page.
 insert into public.social_posts(author_id,client_id,body,created_at)
 select author,gen_random_uuid(),'Общая публикация '||i,now()+make_interval(secs=>i) from generate_series(1,35) i;
 perform tests.act_as(reader);p:=jsonb_build_object('club_id',club,'limit',1,'offset',0);v:=public.social_feed(p);
 perform tests.assert_eq(jsonb_array_length(v->'items'),1,'club filter applied before page slicing');
 perform tests.assert_eq(v->'items'->0->>'id',b::text,'newest actual club post selected');
 perform tests.assert_eq(v->'items'->0->'club'->>'name','Клуб новостей выбранный','canonical catalog name displayed');
 perform tests.assert_eq(v->>'next_offset','1','club-relative cursor');
 v:=public.social_feed(p||'{"offset":1}');perform tests.assert_eq(v->'items'->0->>'id',a::text,'older club post remains reachable');
 perform tests.assert_eq(v->'next_offset','null'::jsonb,'terminal club page has no cursor');
 perform tests.assert_eq(jsonb_array_length(public.social_feed(jsonb_build_object('club_id',other))->'items'),1,'other club remains independently scoped');
 perform tests.assert_eq(jsonb_array_length(public.social_feed('{"limit":50}')->'items'),38,'ordinary feed includes all existing publication kinds');
end $$;

create function tests.test_club_news_privacy_block_and_delete() returns void language plpgsql as $$
declare author uuid:=tests.player('cn_priv_author');reader uuid:=tests.player('cn_priv_reader');club bigint;g uuid;pub uuid;v jsonb;
begin
 insert into private.admins(user_id) values(author);
 insert into public.clubs(city_id,name) values(1,'Клуб новостей приватность') returning id into club;
 perform tests.act_as(author);
 pub:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'club_id',club,'body','Открытая клубная новость'))->>'id')::uuid;
 perform public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'club_id',club,'body','Только для друзей','visibility','friends'));
 g:=(public.create_conversation(jsonb_build_object('client_id',gen_random_uuid(),'kind','group','title','Закрытая клубная группа','visibility','private'))->>'id')::uuid;
 perform public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'club_id',club,'group_id',g,'body','Закрытая клубная публикация'));
 perform tests.act_as(reader);v:=public.social_feed(jsonb_build_object('club_id',club));
 perform tests.assert_eq(jsonb_array_length(v->'items'),1,'club association does not expose private content');
 perform tests.act_as(author);perform public.friendship_action(reader,'request');
 perform tests.act_as(reader);perform public.friendship_action(author,'accept');
 v:=public.social_feed(jsonb_build_object('club_id',club));perform tests.assert_eq(jsonb_array_length(v->'items'),2,'friend rule remains but unrelated private group stays hidden');
 perform public.block_player(author);v:=public.social_feed(jsonb_build_object('club_id',club));
 perform tests.assert_eq(jsonb_array_length(v->'items'),0,'block hides author even in club news');
 perform public.unblock_player(author);
 perform tests.act_as(author);perform public.delete_post(pub);
 perform tests.act_as(reader);v:=public.social_feed(jsonb_build_object('club_id',club));
 perform tests.assert_eq(jsonb_array_length(v->'items'),0,'canonical refresh removes deleted news; unblock does not restore friendships');
 perform tests.act_as_anon();perform tests.expect_error(format('select public.social_feed(%L)',jsonb_build_object('club_id',club)),'42501','club news requires live authenticated reader');
end $$;

create function tests.test_club_news_rpc_ids_and_terminal_cursor_are_bounded() returns void language plpgsql as $$
declare author uuid:=tests.player('cn_bounds_author');club bigint;v jsonb;q jsonb;
begin
 insert into private.admins(user_id) values(author);
 insert into public.clubs(city_id,name) values(1,'Клуб новостей границы') returning id into club;
 insert into public.social_posts(author_id,client_id,body,club_id)
 select author,gen_random_uuid(),'Новость для проверки курсора '||i,club from generate_series(1,1030) i;
 perform tests.act_as(author);v:=public.social_feed(jsonb_build_object('club_id',club,'offset',990,'limit',30));
 perform tests.assert_eq(jsonb_array_length(v->'items'),30,'last bounded window still returns actual rows');
 perform tests.assert_eq(v->'next_offset','null'::jsonb,'no cursor beyond supported offset1000');
 v:=public.social_feed(jsonb_build_object('club_id',club,'offset',1000,'limit',20));
 perform tests.assert_eq(v->'next_offset','null'::jsonb,'explicit supported final offset also ends');
 foreach q in array array['{"club_id":0}'::jsonb,'{"club_id":-1}','{"club_id":1.2}','{"club_id":true}','{"club_id":"1"}','{"club_id":9007199254740992}'] loop
  perform tests.expect_error(format('select public.social_feed(%L)',q),'invalid_request','malformed club filters rejected by RPC');
 end loop;
end $$;
