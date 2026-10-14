create function tests.test_private_game_invitations_and_decline_privacy() returns void language plpgsql as $$
declare a uuid:=tests.player('pi_alice');b uuid:=tests.player('pi_boris');o uuid:=tests.player('pi_out');m uuid;p jsonb;v jsonb;begin
 perform tests.act_as(a);p:=tests.scheduled_payload()||'{"visibility":"private"}';m:=(public.create_scheduled_match(p)->>'id')::uuid;
 perform tests.assert_eq(public.create_scheduled_match(p)->>'id',m::text,'private create retry');
 perform tests.expect_error(format('select public.create_scheduled_match(%L::jsonb)',p||'{"visibility":"public"}'),'version_conflict','create semantics same key protected');
 perform tests.act_as(o);perform tests.assert_eq(jsonb_array_length(public.scheduled_matches()->'items'),0,'private game absent open feed');
 perform tests.expect_error(format('select public.scheduled_match(%L)',m),'scheduled_match_not_found','UUID guessing no access');
 perform tests.expect_error(format('select public.join_scheduled_match(%L)',m),'scheduled_match_not_found','cannot join private without invite');
 perform tests.act_as(a);perform tests.expect_error(format('select public.invite_scheduled_player(%L,%L)',m,b),'friendship_not_accepted','only accepted friends invited');
 perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');perform tests.act_as(a);
 v:=public.invite_scheduled_player(m,b);perform tests.assert_eq(v->>'spots_left','3','invitation never reserves seat');
 perform public.invite_scheduled_player(m,b);perform tests.act_as(b);
 perform tests.assert_eq(public.scheduled_match(m)->'viewer'->>'participation','invited','invitee can inspect');
 perform tests.assert_eq(jsonb_array_length(public.scheduled_matches('{"scope":"mine"}')->'items'),1,'invitations in my games');
 v:=public.respond_scheduled_invitation(m,'declined');perform tests.assert_eq(v->'viewer'->>'participation','rejected','own decline');
 perform tests.expect_error(format('select public.scheduled_match(%L)',m),'scheduled_match_not_found','decline revokes private details');
 perform tests.as_admin();update public.scheduled_matches set note='Новое закрытое обсуждение' where id=m;perform tests.act_as(b);
 perform tests.assert_eq(public.respond_scheduled_invitation(m,'declined')->>'note',v->>'note','retry uses original snapshot after revocation');
 perform tests.act_as(a);perform public.invite_scheduled_player(m,b);perform tests.act_as(b);
 v:=public.respond_scheduled_invitation(m,'accepted');perform tests.assert_eq(v->'viewer'->>'participation','accepted','explicit invitation approves provisional friend');
 perform tests.assert_eq(v->>'spots_left','2','accept consumes exactly seat');perform tests.assert_eq(public.respond_scheduled_invitation(m,'accepted')->>'spots_left','2','accept retry');
 v:=public.leave_scheduled_match(m);perform tests.expect_error(format('select public.scheduled_match(%L)',m),'scheduled_match_not_found','withdraw revokes private details');
 perform tests.assert_eq(public.leave_scheduled_match(m),v,'withdraw retry frozen response');
end $$;

create function tests.test_game_waitlist_does_not_reserve_and_notifies() returns void language plpgsql as $$
declare p uuid[]:=array[tests.player('wl_owner'),tests.player('wl_two'),tests.player('wl_three'),tests.player('wl_four'),tests.player('wl_five')];m uuid;v jsonb;begin
 for i in 2..5 loop perform tests.established(p[i],3,.25,5);end loop;
 perform tests.act_as(p[1]);m:=(public.create_scheduled_match(tests.scheduled_payload())->>'id')::uuid;
 for i in 2..4 loop perform tests.act_as(p[i]);perform public.join_scheduled_match(m);end loop;
 perform tests.act_as(p[5]);v:=public.waitlist_scheduled_match(m);perform tests.assert_eq(v->'viewer'->>'participation','waitlisted','explicit waitlist');
 perform tests.assert_eq(v->>'spots_left','0','no fictitious seat');perform tests.assert_eq(jsonb_array_length(v->'participants'),4,'four accepted actual seats');
 perform public.waitlist_scheduled_match(m);perform tests.assert_eq(jsonb_array_length(public.scheduled_matches('{"scope":"mine"}')->'items'),1,'waitlisted in mine');
 perform tests.assert_eq(jsonb_array_length(public.scheduled_matches('{"scope":"mine","accepted_only":true}')->'items'),0,'waitlist not accepted');
 perform tests.act_as(p[4]);perform public.leave_scheduled_match(m);perform tests.act_as(p[5]);
 perform tests.assert_eq(public.scheduled_match(m)->'viewer'->>'participation','waitlisted','seat opening requires confirmed user action');
 perform tests.assert_eq((select count(*)::int from jsonb_array_elements(public.social_notifications()->'items') x where x->>'kind'='game_spot_available'),1,'availability inbox event');
 v:=public.join_scheduled_match(m);perform tests.assert_eq(v->'viewer'->>'participation','accepted','own join consumes free seat');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from public.rating_events where kind='match')::int,0,'waitlist no rating effects');
end $$;

create function tests.test_private_game_invitation_capacity_and_owner_review() returns void language plpgsql as $$
declare p uuid[]:=array[tests.player('ic_owner'),tests.player('ic_two'),tests.player('ic_three'),tests.player('ic_four'),tests.player('ic_five')];m uuid;v jsonb;begin
 for i in 2..5 loop
 perform tests.act_as(p[1]);perform public.friendship_action(p[i],'request');perform tests.act_as(p[i]);perform public.friendship_action(p[1],'accept');end loop;
 perform tests.act_as(p[1]);m:=(public.create_scheduled_match(tests.scheduled_payload()||'{"visibility":"private"}')->>'id')::uuid;
 for i in 2..5 loop perform public.invite_scheduled_player(m,p[i]);end loop;
 for i in 2..4 loop perform tests.act_as(p[i]);perform public.respond_scheduled_invitation(m,'accepted');end loop;
 perform tests.act_as(p[5]);perform tests.expect_error(format('select public.respond_scheduled_invitation(%L,''accepted'')',m),'scheduled_match_full','invites cannot overfill');
 perform tests.assert_eq(public.scheduled_match(m)->'viewer'->>'participation','invited','failed accept preserves invite');
 perform public.waitlist_scheduled_match(m);perform tests.act_as(p[4]);perform public.leave_scheduled_match(m);
 perform tests.act_as(p[1]);v:=public.review_scheduled_application(m,p[5],'accepted');perform tests.assert_eq(v->>'spots_left','0','owner approves queue atomically');
 perform tests.act_as(p[5]);perform tests.assert_eq(public.respond_scheduled_invitation(m,'accepted')->'viewer'->>'participation','accepted','accepted invite retry after owner approval');
end $$;

create function tests.test_scheduled_weekly_series_atomicity_and_timezone() returns void language plpgsql as $$
declare a uuid:=tests.player('sr_owner');key uuid:=gen_random_uuid();p jsonb;v jsonb;id uuid;start timestamptz:=now()+interval '2 days';begin
 perform tests.act_as(a);p:=jsonb_build_object('match',tests.scheduled_payload()-'client_id','occurrences',3,'interval_weeks',1,'time_zone','Europe/Moscow');
 v:=public.create_scheduled_series(p,key);id:=(v->>'series_id')::uuid;perform tests.assert_eq(jsonb_array_length(v->'items'),3,'bounded real weekly games');
 perform tests.assert_eq(public.create_scheduled_series(p,key)->>'series_id',id::text,'series retry idempotent');
 perform tests.assert_eq((v->'items'->1->>'starts_at')::timestamptz-(v->'items'->0->>'starts_at')::timestamptz,interval '1 week','weekly date offset');
 perform tests.assert_eq(v->'items'->2->>'occurrence','3','ordinal preserved');
 perform tests.expect_error(format('select public.create_scheduled_series(%L::jsonb,%L)',p||'{"occurrences":4}',key),'version_conflict','series same-key mismatch');
 perform tests.expect_error(format('select public.create_scheduled_series(%L::jsonb,%L)',jsonb_build_object('match',(tests.scheduled_payload()-'client_id')||jsonb_build_object('starts_at',now()+interval '175 days'),'occurrences',3,'interval_weeks',1),gen_random_uuid()),'invalid_scheduled_match','any too-far occurrence rolls whole series back');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from public.scheduled_series where organizer_id=a)::int,1,'failed series rollback');perform tests.assert_eq((select count(*) from public.scheduled_matches where organizer_id=a)::int,3,'failed series no partial games');
end $$;

create function tests.test_waitlist_deletion_block_and_revocation() returns void language plpgsql as $$
declare a uuid:=tests.player('wd_owner');b uuid:=tests.player('wd_friend');m uuid;begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');perform tests.act_as(a);
 m:=(public.create_scheduled_match(tests.scheduled_payload()||'{"visibility":"private"}')->>'id')::uuid;perform public.invite_scheduled_player(m,b);
 perform tests.act_as(b);perform public.block_player(a);perform tests.expect_error(format('select public.scheduled_match(%L)',m),'scheduled_match_not_found','blocked owner private event hidden');
 perform tests.expect_error(format('select public.respond_scheduled_invitation(%L,''accepted'')',m),'social_blocked','accept cannot bypass block');
 perform tests.act_as_service();perform public.svc_anonymize_account(b);perform tests.as_admin();
 perform tests.assert_eq((select status from public.scheduled_match_players where match_id=m and player_id=b),'withdrawn','deleted invited player removed');
 perform tests.act_as(a);perform tests.expect_error('select * from public.scheduled_series','42501','series raw access denied');
end $$;
