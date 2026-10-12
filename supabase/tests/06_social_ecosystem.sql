-- Regression scenarios for participant access, retry identity and privacy.
create function tests.test_social_direct_privacy_and_idempotency() returns void language plpgsql as $$
declare a uuid:=tests.player('sc_alice');b uuid:=tests.player('sc_boris');o uuid:=tests.player('sc_out');c uuid;key uuid:=gen_random_uuid();m jsonb;v jsonb;begin
 perform tests.act_as(a);
 perform tests.expect_error(format('select public.create_conversation(%L::jsonb)',jsonb_build_object('kind','direct','player_id',b,'client_id',gen_random_uuid())), 'messages_not_allowed','DM friends-only default');
 perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');perform tests.act_as(a);
 c:=(public.create_conversation(jsonb_build_object('kind','direct','player_id',b,'client_id',gen_random_uuid()))->>'id')::uuid;
 m:=public.send_message(c,'Привет, сыграем?',key);
 perform tests.assert_eq(public.send_message(c,'Привет, сыграем?',key)->>'id',m->>'id','send retry preserves message');
 perform tests.expect_error(format('select public.send_message(%L,%L,%L)',c,'Другой текст',key),'version_conflict','same key different message fails');
 perform tests.assert_eq(jsonb_array_length(public.conversation_messages(c)->'items'),1,'one message per key');
 perform tests.assert_eq((select count(*)::int from jsonb_array_elements(public.social_notifications()->'items') n where n->>'kind'='message'),0,'sender no own message notification');
 perform tests.act_as(o);
 perform tests.expect_error(format('select public.conversation(%L)',c),'conversation_not_found','foreign chat hidden');
 perform tests.expect_error(format('select public.send_message(%L,''Посторонний'',%L)',c,gen_random_uuid()),'conversation_not_found','outsider cannot write');
 perform tests.act_as(b);
 perform tests.assert_eq(public.conversation(c)->>'unread_count','1','recipient has unread');
 v:=public.social_notifications();perform tests.assert_eq((select n->>'title' from jsonb_array_elements(v->'items') n where n->>'kind'='message' limit 1),'Новое сообщение','notification omits text');
 perform public.mark_conversation_read(c,(m->>'id')::bigint);perform tests.assert_eq(public.conversation(c)->>'unread_count','0','read mark');
 perform tests.expect_error(format('select public.mark_conversation_read(%L,999999)',c),'invalid_request','forged high water rejected');
 perform public.update_social_settings('{"messages_from":"nobody"}');perform tests.act_as(a);
 perform tests.expect_error(format('select public.send_message(%L,''Ещё'',%L)',c,gen_random_uuid()),'messages_not_allowed','changed privacy affects existing chat');
 perform tests.act_as(b);perform public.update_social_settings('{"messages_from":"everyone"}');perform tests.act_as(o);
 perform tests.assert(public.create_conversation(jsonb_build_object('kind','direct','player_id',b,'client_id',gen_random_uuid()))->>'id' is not null,'everyone permits new DM');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from public.conversation_messages where conversation_id=c)::int,1,'only valid write exists');
end $$;

create function tests.test_social_blocks_protect_existing_paths() returns void language plpgsql as $$
declare a uuid:=tests.player('sb_alice');b uuid:=tests.player('sb_boris');o uuid:=tests.player('sb_out');c uuid;p uuid;begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');
 p:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'body','Ищем партнёров'))->>'id')::uuid;
 perform tests.act_as(a);perform public.follow_player(b);
 perform tests.assert_eq(public.player_profile(b)->>'is_following','true','real follow state');
 c:=(public.create_conversation(jsonb_build_object('kind','direct','player_id',b,'client_id',gen_random_uuid()))->>'id')::uuid;
 perform public.send_message(c,'До встречи',gen_random_uuid());perform public.block_player(b);perform public.block_player(b);
 perform tests.assert_eq(jsonb_array_length(public.blocked_players()->'items'),1,'block retry one row');
 perform tests.assert_eq(public.blocked_players()->'items'->0->>'id',b::text,'block list player card');
 perform tests.assert_eq(jsonb_array_length(public.following_players()->'items'),0,'follow removed');
 perform tests.expect_error(format('select public.player_profile(%L)',b),'player_not_found','profile gate includes blocks');
 perform tests.expect_error(format('select public.friendship_action(%L,''request'')',b),'social_blocked','request cannot bypass block');
 perform tests.expect_error(format('select public.conversation(%L)',c),'conversation_not_found','blocked DM unavailable');
 perform tests.expect_error(format('select public.social_post(%L)',p),'post_not_found','blocked post unavailable');
 perform tests.assert_eq(jsonb_array_length(public.search_players('{}')->'items'),1,'blocked absent search but outsider retained');
 perform tests.assert_eq(jsonb_array_length(public.social_feed()->'items'),0,'blocked absent feed');
 perform tests.act_as(b);perform tests.expect_error(format('select public.player_profile(%L)',a),'player_not_found','bilateral profile gate');
 perform tests.assert_eq(jsonb_array_length(public.social_notifications()->'items'),0,'block clears actor inbox');
 perform tests.act_as(a);perform public.unblock_player(b);perform tests.assert_eq(public.player_profile(b)->>'is_following','false','unblock does not restore follow');
 perform tests.assert_eq(jsonb_array_length(public.friendships()->'accepted'),0,'unblock does not restore friend');
 perform tests.assert_eq(jsonb_array_length(public.social_feed()->'items'),1,'content visible after unblock');
end $$;

create function tests.test_social_groups_membership_and_creation_retry() returns void language plpgsql as $$
declare a uuid:=tests.player('sg_alice');b uuid:=tests.player('sg_boris');o uuid:=tests.player('sg_out');c uuid;g uuid;key uuid:=gen_random_uuid();payload jsonb;v jsonb;begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');perform tests.act_as(a);
 payload:=jsonb_build_object('kind','group','client_id',key,'title','Постоянная игра','description','Каждую среду','player_ids',jsonb_build_array(b));
 c:=(public.create_conversation(payload)->>'id')::uuid;
 perform tests.assert_eq(public.create_conversation(payload)->>'id',c::text,'group retry');
 perform tests.expect_error(format('select public.create_conversation(%L::jsonb)',payload||'{"description":"Каждый день"}'),'version_conflict','all group semantic fields immutable for key');
 perform tests.expect_error(format('select public.conversation_member_action(%L,null,''leave'')',c),'conversation_owner_cannot_leave','owner cannot orphan group');
 perform tests.act_as(o);
 perform tests.assert_eq(jsonb_array_length(public.social_groups()->'items'),0,'private group hidden');
 perform tests.expect_error(format('select public.conversation_member_action(%L,null,''join'')',c),'forbidden','private self join denied');
 perform tests.expect_error(format('select public.create_post(%L::jsonb)',jsonb_build_object('client_id',gen_random_uuid(),'body','Чужая группа','group_id',c)),'conversation_not_found','outsider cannot publish in group');
 perform tests.act_as(b);perform public.send_message(c,'Буду',gen_random_uuid());perform public.conversation_member_action(c,null,'leave');
 perform tests.expect_error(format('select public.conversation_messages(%L)',c),'conversation_not_found','leaving immediately revokes history access');
 perform tests.act_as(a);perform public.conversation_member_action(c,b,'add');perform tests.assert_eq(jsonb_array_length(public.conversation(c)->'members'),2,'owner can invite accepted friend');
 g:=(public.create_conversation(jsonb_build_object('kind','group','client_id',gen_random_uuid(),'title','Клуб любителей','visibility','public'))->>'id')::uuid;
 perform tests.act_as(o);perform tests.assert_eq(jsonb_array_length(public.social_groups()->'items'),1,'public group discoverable');
 v:=public.conversation_member_action(g,null,'join');perform tests.assert_eq(jsonb_array_length(v->'members'),2,'public self join works');
 perform tests.expect_error(format('select public.conversation_member_action(%L,%L,''remove'')',g,a),'conversation_owner_required','ordinary member cannot remove others');
 perform tests.act_as(b);
 perform tests.expect_error(format('select public.conversation_member_action(%L,%L,''transfer_owner'')',c,b),'conversation_owner_required','ordinary member cannot make themselves owner');
 perform tests.act_as(a);
 perform tests.expect_error(format('select public.conversation_member_action(%L,%L,''transfer_owner'')',c,o),'conversation_not_found','new owner must already be a member');
 v:=public.conversation_member_action(c,b,'transfer_owner');
 perform tests.assert_eq(v->>'owner_id',b::text,'ownership transfer is persisted');
 perform tests.assert_eq((select count(*)::int from jsonb_array_elements(v->'members') m where m->>'role'='owner'),1,'one canonical owner after transfer');
 perform tests.assert_eq(public.conversation_member_action(c,b,'transfer_owner')->>'owner_id',b::text,'transfer replay does not reassign ownership');
 perform public.conversation_member_action(c,null,'leave');
 perform tests.expect_error(format('select public.conversation(%L)',c),'conversation_not_found','previous owner can leave and loses access');
 perform tests.expect_error(format('select public.create_conversation(%L::jsonb)',payload),'conversation_not_found','original creation key does not restore revoked membership');
 perform tests.act_as(b);perform public.send_message(c,'Группа продолжает работать',gen_random_uuid());
end $$;

create function tests.test_social_posts_comments_reactions_and_moderation() returns void language plpgsql as $$
declare a uuid:=tests.player('sf_alice');b uuid:=tests.player('sf_boris');o uuid:=tests.player('sf_out');p uuid;private_p uuid;comment uuid;r uuid;key uuid:=gen_random_uuid();payload jsonb;v jsonb;begin
 perform tests.act_as(a);payload:=jsonb_build_object('client_id',key,'body','Отличная игра сегодня');p:=(public.create_post(payload)->>'id')::uuid;
 perform tests.assert_eq(public.create_post(payload)->>'id',p::text,'post retry one identity');
 perform tests.expect_error(format('select public.create_post(%L::jsonb)',payload||'{"body":"Заменить"}'),'version_conflict','post identity collision rejected');
 private_p:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'body','Только друзьям','visibility','friends'))->>'id')::uuid;
 perform tests.act_as(b);perform tests.expect_error(format('select public.social_post(%L)',private_p),'post_not_found','friend post not public');
 perform public.follow_player(a);perform tests.assert_eq(jsonb_array_length(public.social_feed('{"scope":"following"}')->'items'),1,'following actual content');
 v:=public.react_to_post(p,'celebrate');perform tests.assert_eq(v->>'reaction_count','1','one reaction');
 perform public.react_to_post(p,'support');perform tests.assert_eq(public.social_post(p)->>'reaction_count','1','reaction replaces same user');
 key:=gen_random_uuid();comment:=(public.comment_on_post(p,'И снова сыграем!',key)->>'id')::uuid;
 perform tests.assert_eq(public.comment_on_post(p,'И снова сыграем!',key)->>'id',comment::text,'comment retry');
 perform tests.assert_eq(public.social_post(p)->>'comment_count','1','real comment count');
 perform tests.act_as(o);perform tests.expect_error(format('select public.delete_post(%L)',p),'post_not_found','outsider delete denied');
 perform tests.expect_error(format('select public.delete_comment(%L)',comment),'not_found','outsider cannot delete comment');
 key:=gen_random_uuid();payload:=jsonb_build_object('target_type','post','target_id',p,'reason','spam');r:=(public.report_content(payload,key)->>'id')::uuid;
 perform tests.assert_eq(public.report_content(payload,key)->>'id',r::text,'report retry');
 perform tests.expect_error('select public.moderation_reports()','forbidden','reports private to moderators');
 perform tests.expect_error(format('select public.moderate_report(%L,''hide'')',r),'forbidden','ordinary player cannot moderate');
 perform tests.as_admin();insert into private.admins(user_id) values(a);perform tests.act_as(a);
 perform tests.assert_eq(jsonb_array_length(public.moderation_reports()->'items'),1,'moderator gets report');
 perform tests.assert_eq(public.moderation_reports()->'items'->0->'content'->>'body','Отличная игра сегодня','moderator inspects only reported live content');
 perform tests.assert_eq(public.moderate_report(r,'hide')->>'status','hidden','moderation hides');
 perform tests.act_as(b);perform tests.expect_error(format('select public.social_post(%L)',p),'post_not_found','hidden content no longer accessible');
end $$;

create function tests.test_social_game_chat_and_read_cursor() returns void language plpgsql as $$
declare a uuid:=tests.player('sm_alice');b uuid:=tests.player('sm_boris');o uuid:=tests.player('sm_out');game uuid;c uuid;other uuid;m jsonb;begin
 perform tests.established(b,3,.25,5);perform tests.act_as(a);game:=(public.create_scheduled_match(tests.scheduled_payload())->>'id')::uuid;
 perform tests.act_as(b);perform public.join_scheduled_match(game);c:=(public.create_conversation(jsonb_build_object('client_id',gen_random_uuid(),'kind','game','game_id',game))->>'id')::uuid;
 m:=public.send_message(c,'Уже готов',gen_random_uuid());perform tests.act_as(a);
 perform tests.assert_eq(public.create_conversation(jsonb_build_object('client_id',gen_random_uuid(),'kind','game','game_id',game))->>'id',c::text,'one game one chat');
 other:=(public.create_conversation(jsonb_build_object('client_id',gen_random_uuid(),'kind','group','title','Другой чат'))->>'id')::uuid;
 perform tests.expect_error(format('select public.mark_conversation_read(%L,%s)',other,m->>'id'),'invalid_request','foreign chat message cannot advance mark');
 perform tests.act_as(o);perform tests.expect_error(format('select public.conversation(%L)',c),'conversation_not_found','outsider denied game chat');
 perform tests.act_as(b);perform public.leave_scheduled_match(game);
 perform tests.expect_error(format('select public.conversation_messages(%L)',c),'conversation_not_found','withdrawn participant history revoked');
 perform tests.expect_error(format('select public.send_message(%L,''После выхода'',%L)',c,gen_random_uuid()),'conversation_not_found','withdrawn send denied');
end $$;

create function tests.test_social_deletion_and_function_privileges() returns void language plpgsql as $$
declare a uuid:=tests.player('sd_alice');b uuid:=tests.player('sd_boris');c uuid;p uuid;m jsonb;begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');perform tests.act_as(a);
 c:=(public.create_conversation(jsonb_build_object('kind','direct','player_id',b,'client_id',gen_random_uuid()))->>'id')::uuid;
 m:=public.send_message(c,'Личные данные удалятся',gen_random_uuid());p:=(public.create_post(jsonb_build_object('client_id',gen_random_uuid(),'body','Авторский контент'))->>'id')::uuid;
 perform tests.expect_error('select * from public.conversation_messages','42501','raw messages inaccessible');
 perform tests.expect_error('select * from public.player_blocks','42501','raw block relationships inaccessible');
 perform tests.act_as_anon();perform tests.expect_error('select public.social_feed()','42501','anonymous RPC denied');
 perform tests.expect_error('select private.blocked(null,null)','42501','private helper denied');
 perform tests.act_as_service();perform public.svc_anonymize_account(a);
 perform tests.act_as(b);perform tests.assert_eq(jsonb_array_length(public.social_feed()->'items'),0,'deleted content removed');
 perform tests.assert_eq(public.conversation_messages(c)->'items'->0->>'deleted','true','deleted sender message erased');
 perform tests.assert_eq(public.conversation_messages(c)->'items'->0->'sender'->>'deleted','true','sender tombstone');
 perform tests.as_admin();perform tests.assert_eq((select body from public.conversation_messages where id=(m->>'id')::bigint),'Сообщение удалено','stored body erased');
 perform tests.assert_eq((select count(*) from public.conversation_members where player_id=a)::int,0,'memberships removed');
end $$;
