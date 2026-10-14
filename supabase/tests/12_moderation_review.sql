create function tests.test_moderation_private_item_review_and_deleted_content() returns void language plpgsql as $$
declare a uuid:=tests.player('mr_author'); b uuid:=tests.player('mr_reporter');
 admin uuid:=tests.player('mr_admin'); outsider uuid:=tests.player('mr_out');
 chat uuid; message jsonb; report uuid; view jsonb;
begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');
 perform tests.act_as(b);perform public.friendship_action(a,'accept');
 chat:=(public.create_conversation(jsonb_build_object('kind','direct','player_id',a,'client_id',gen_random_uuid()))->>'id')::uuid;
 perform tests.act_as(a);
 message:=public.send_message(chat,'Reported private message',gen_random_uuid());
 perform public.send_message(chat,'Unreported private message',gen_random_uuid());
 perform tests.act_as(b);
 report:=(public.report_content(jsonb_build_object('target_type','message','target_id',message->>'id','reason','harassment'),gen_random_uuid())->>'id')::uuid;
 perform tests.act_as(outsider);perform tests.expect_error('select public.moderation_reports()','forbidden','outsider cannot inspect report content');
 perform tests.as_admin();insert into private.admins(user_id) values(admin);perform tests.act_as(admin);
 perform tests.expect_error(format('select public.conversation(%L)',chat),'conversation_not_found','moderator cannot read entire foreign conversation');
 view:=public.moderation_reports()->'items'->0;
 perform tests.assert_eq(view->'content'->>'body','Reported private message','report grants only specific live content');
 perform tests.assert(position('Unreported private message' in view::text)=0,'no surrounding private history disclosed');
 perform tests.as_admin();update public.conversation_messages set deleted_at=now(),body='Сообщение удалено' where id=(message->>'id')::bigint;
 perform tests.act_as(admin);
 perform tests.assert(public.moderation_reports()->'items'->0->'content'='null'::jsonb,'deleted body not retained for report review');
 perform tests.assert_eq(public.moderate_report(report,'dismiss')->>'status','dismissed','deleted content report can be resolved');
end $$;
