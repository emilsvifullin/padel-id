-- Group ownership must outlive a deleted creator without granting outsiders
-- access or restoring a removed membership. Every test rolls back in run-tests.
create function tests.test_group_owner_deletion_transfers_and_preserves_history() returns void language plpgsql as $$
declare a uuid:=tests.player('go_owner'); b uuid:=tests.player('go_first'); c uuid:=tests.player('go_later'); outsider uuid:=tests.player('go_out'); g uuid; tied_group uuid; post uuid; v jsonb;
begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');
 perform tests.act_as(a);perform public.friendship_action(c,'request');perform tests.act_as(c);perform public.friendship_action(a,'accept');
 perform tests.act_as(a);
 g:=(public.create_conversation(jsonb_build_object('kind','group','client_id',gen_random_uuid(),'title','Постоянная группа','description','По средам','player_ids',jsonb_build_array(b,c)))->>'id')::uuid;
 tied_group:=(public.create_conversation(jsonb_build_object('kind','group','client_id',gen_random_uuid(),'title','Равное время вступления','player_ids',jsonb_build_array(b,c)))->>'id')::uuid;
 perform public.send_message(g,'Удаляемый текст создателя',gen_random_uuid());
 perform tests.act_as(c);perform public.send_message(g,'Сохраняем историю участников',gen_random_uuid());
 post:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'group_id',g,'body','План следующей игры'))->>'id')::uuid;
 perform tests.as_admin();
 update public.conversation_members set joined_at=case when player_id=b then '2026-01-01'::timestamptz else '2026-01-02'::timestamptz end where conversation_id=g and player_id<>a;
 update public.conversation_members set joined_at='2026-01-01'::timestamptz where conversation_id=tied_group and player_id<>a;
 perform tests.act_as_service();perform public.svc_anonymize_account(a);
 perform tests.as_admin();perform tests.assert_eq((select owner_id from public.conversations where id=tied_group),least(b,c),'UUID resolves equal join times deterministically');
 perform tests.act_as(b);v:=public.conversation(g);
 perform tests.assert_eq(v->>'owner_id',b::text,'oldest active member becomes owner');
 perform tests.assert_eq(v->>'title','Постоянная группа','shared group title retained');
 perform tests.assert_eq(v->>'visibility','private','private group stays private');
 perform tests.assert_eq(jsonb_array_length(v->'members'),2,'deleted creator membership removed');
 perform tests.assert_eq((select count(*)::int from jsonb_array_elements(v->'members') m where m->>'role'='owner'),1,'exactly one owner');
 perform tests.assert_eq(public.conversation_messages(g)->'items'->0->>'deleted','true','deleted creator message tombstoned');
 perform tests.assert_eq(public.conversation_messages(g)->'items'->1->>'body','Сохраняем историю участников','other member history retained');
 perform tests.assert_eq(public.social_post(post)->>'body','План следующей игры','group activity retained');
 perform public.send_message(g,'Новый организатор',gen_random_uuid());
 perform public.conversation_member_action(g,c,'remove');
 perform tests.act_as(c);perform tests.expect_error(format('select public.conversation(%L)',g),'conversation_not_found','new owner manages membership');
 perform tests.act_as(outsider);perform tests.expect_error(format('select public.conversation(%L)',g),'conversation_not_found','handoff grants no outsider access');
 perform tests.assert_eq(jsonb_array_length(public.social_groups()->'items'),0,'private group remains hidden');
 perform tests.as_admin();perform tests.assert_eq((select creation_input from public.conversations where id=g),'{}'::jsonb,'deleted creator input erased');
 perform tests.act_as_service();perform public.svc_anonymize_account(a);
 perform tests.act_as(b);perform tests.assert_eq(public.conversation(g)->>'owner_id',b::text,'repeated account cleanup does not change owner');
end $$;

create function tests.test_group_owner_deletion_excludes_ineligible_members() returns void language plpgsql as $$
declare a uuid:=tests.player('gx_owner'); b uuid:=tests.player('gx_removed'); c uuid:=tests.player('gx_blocked'); d uuid:=tests.player('gx_alive'); dead uuid:=tests.player('gx_deleted'); unrated uuid:=tests.player('gx_unrated'); peer uuid; g uuid;
begin
 foreach peer in array array[b,c,d,dead,unrated] loop
  perform tests.act_as(a);perform public.friendship_action(peer,'request');perform tests.act_as(peer);perform public.friendship_action(a,'accept');
 end loop;
 perform tests.act_as(a);g:=(public.create_conversation(jsonb_build_object('kind','group','client_id',gen_random_uuid(),'title','Надёжная группа','player_ids',jsonb_build_array(b,c,d,dead,unrated)))->>'id')::uuid;
 perform public.conversation_member_action(g,b,'remove');
 perform tests.act_as(c);perform public.block_player(a);
 perform tests.act_as_service();perform public.svc_anonymize_account(dead);
 perform tests.as_admin();
 -- Defense against a pre-existing stale membership: deleted profiles cannot
 -- acquire ownership even if privileged maintenance left their old row behind.
 insert into public.conversation_members(conversation_id,player_id,joined_at) values(g,dead,'2025-01-01');
 delete from public.player_ratings where player_id=unrated;
 update public.conversation_members set joined_at='2024-01-01'::timestamptz where conversation_id=g and player_id=unrated;
 update public.conversation_members set joined_at=case when player_id=c then '2026-01-01'::timestamptz else '2026-01-02'::timestamptz end where conversation_id=g and player_id in(c,d);
 perform tests.act_as_service();perform public.svc_anonymize_account(a);
 perform tests.act_as(d);perform tests.assert_eq(public.conversation(g)->>'owner_id',d::text,'only active unblocked current member eligible');
 perform public.send_message(g,'Группа работает без неактивных участников',gen_random_uuid());
 perform tests.act_as(b);perform tests.expect_error(format('select public.conversation(%L)',g),'conversation_not_found','removed member never restored by handoff');
 perform tests.as_admin();perform tests.assert_eq((select count(*)::int from public.conversation_members where conversation_id=g and role='owner'),1,'canonical successor role');
 perform tests.assert_eq((select count(*)::int from public.conversation_members where conversation_id=g and player_id in(dead,unrated)),0,'stale inactive memberships are not retained');
end $$;

create function tests.test_group_owner_deletion_archives_without_successor() returns void language plpgsql as $$
declare a uuid:=tests.player('ga_owner'); b uuid:=tests.player('ga_blocked'); outsider uuid:=tests.player('ga_out'); g uuid;
begin
 perform tests.act_as(a);g:=(public.create_conversation(jsonb_build_object('kind','group','client_id',gen_random_uuid(),'title','Завершаем группу','visibility','public'))->>'id')::uuid;
 perform tests.act_as(b);perform public.conversation_member_action(g,null,'join');perform public.send_message(g,'История остаётся в базе',gen_random_uuid());perform public.block_player(a);
 perform tests.act_as_service();perform public.svc_anonymize_account(a);
 perform tests.act_as(b);perform tests.expect_error(format('select public.conversation(%L)',g),'conversation_not_found','archived group revokes old membership');
 perform tests.expect_error(format('select public.send_message(%L,''Не возобновлять'',%L)',g,gen_random_uuid()),'conversation_not_found','archived group cannot send');
 perform tests.act_as(outsider);perform tests.assert_eq(jsonb_array_length(public.social_groups()->'items'),0,'archived public group removed from discovery');
 perform tests.expect_error(format('select public.conversation_member_action(%L,null,''join'')',g),'forbidden','archived group cannot reopen through self join');
 perform tests.as_admin();
 perform tests.assert_eq((select count(*)::int from public.conversation_messages where conversation_id=g),1,'archive retains history without public access');
 perform tests.assert_eq((select count(*)::int from public.conversation_members where conversation_id=g),0,'no stranded members');
end $$;

create function tests.test_group_account_cleanup_helpers_are_service_only() returns void language plpgsql as $$
declare a uuid:=tests.player('gp_owner');begin
 perform tests.act_as(a);
 perform tests.expect_error(format('select public.svc_anonymize_account(%L)',a),'42501','ordinary player cannot delete through service RPC');
 perform tests.expect_error(format('select private.svc_anonymize_account_before_group_cleanup(%L)',a),'42501','wrapped original remains private');
 perform tests.expect_error('select private.handoff_groups_before_account_deletion()','42501','trigger helper not callable');
 perform tests.act_as_anon();perform tests.expect_error(format('select public.svc_anonymize_account(%L)',a),'42501','anonymous cannot delete');
end $$;
