create function tests.push_secret() returns text language sql immutable as $$ select repeat('test-worker-',4) $$;
create function tests.push_configure() returns void language plpgsql as $$
begin perform tests.as_admin();update private.push_config set enabled=true,worker_secret_hash=extensions.digest(tests.push_secret(),'sha256');end $$;
create function tests.push_dm(a uuid,b uuid) returns uuid language plpgsql as $$
declare c uuid;begin
 perform tests.act_as(a);perform public.friendship_action(b,'request');perform tests.act_as(b);perform public.friendship_action(a,'accept');
 perform tests.act_as(a);c:=(public.create_conversation(jsonb_build_object('kind','direct','player_id',b,'client_id',gen_random_uuid()))->>'id')::uuid;return c;
end $$;

create function tests.test_push_session_expiration_protects_existing_rpc_and_worker() returns void language plpgsql as $$
declare a uuid:=tests.player('push_expire_sender');b uuid:=tests.player('push_expire_reader');c uuid:=tests.push_dm(a,b);install uuid:=gen_random_uuid();v jsonb;j uuid;l uuid;s uuid;
begin
 perform tests.push_configure();perform tests.act_as(b);perform public.register_push_device(install,'aabb',true);
 perform tests.act_as(a);perform public.send_message(c,'До истечения сессии',gen_random_uuid());v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.as_admin();select session_id into s from private.push_devices where installation_id=install;
 update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=s;
 perform tests.act_as(b);perform tests.expect_error('select public.me()','session_expired');
 perform tests.expect_error(format('select public.register_push_device(%L,''aabb'',true)',install),'session_expired');
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'expired but extant Auth session revokes worker destination');
end $$;

create function tests.test_push_played_match_sources_are_versioned_and_actionable() returns void language plpgsql as $$
declare p uuid[]:=array[tests.player('push_match_a'),tests.player('push_match_b'),tests.player('push_match_c'),tests.player('push_match_d')];m uuid;v jsonb;edit jsonb;key uuid:=gen_random_uuid();j uuid;l uuid;
begin
 perform tests.push_configure();
 perform tests.act_as(p[1]);perform public.register_push_device(gen_random_uuid(),'aabb',true);
 perform tests.act_as(p[2]);perform public.register_push_device(gen_random_uuid(),'ccdd',true);
 m:=tests.match(p);
 perform tests.assert_eq((select count(*) from private.push_match_events where match_id=m)::int,3,'three real pending noncreator confirmation sources');
 v:=tests.push_claim();perform tests.assert_eq(jsonb_array_length(v->'items'),1,'only registered pending recipient gets provider job');
 j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(p[2]);perform public.confirm_match(m,1);
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'confirmed recipient no longer needs stale action');
 perform tests.act_as(p[3]);perform public.dispute_match(m,1,'wrong_score');perform public.dispute_match(m,1,'wrong_score');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_match_events where match_id=m and action='dispute')::int,1,'repeated dispute produces one creator source');
 v:=tests.push_claim();perform tests.assert_eq(jsonb_array_length(v->'items'),1,'real disputed creator receives a job');
 j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 edit:=jsonb_build_object('match_type','ranked','format','best_of_3','played_at',now()-interval '2 hours','players',tests.lineup(p),'sets',tests.sets(6,4,7,5));
 perform tests.act_as(p[1]);perform public.update_match(m,1,edit,key);perform public.update_match(m,1,edit,key);
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'new score version suppresses old dispute');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_match_events where match_id=m and match_version=2)::int,3,'edited canonical version resets three real confirmation sources once');
 v:=tests.push_claim();perform tests.assert_eq(jsonb_array_length(v->'items'),1,'one registered pending recipient for actual new version');
end $$;
create function tests.push_claim() returns jsonb language plpgsql as $$
begin perform tests.act_as_anon();return public.claim_push_deliveries(tests.push_secret(),10);end $$;

create function tests.test_push_registration_defaults_live_sessions_and_raw_security() returns void language plpgsql as $$
declare a uuid:=tests.player('push_registration');install uuid:=gen_random_uuid();v jsonb;s uuid;
begin
 perform tests.act_as(a);perform tests.expect_error(format('select public.register_push_device(%L,''aabb'',true)',install),'service_unavailable');
 perform tests.push_configure();perform tests.act_as(a);v:=public.register_push_device(install,'AABB',true);
 perform tests.assert_eq(v->>'topic','app.padelid.ios','topic comes only from owner configuration');
 perform tests.assert_eq(v->>'environment','production','environment comes only from owner configuration');
 perform tests.assert(not(v?'device_token'),'client response does not echo token');
 perform tests.expect_error(format('select public.register_push_device(%L,''abc'',true)',install),'invalid_request');
 perform tests.expect_error('select * from private.push_devices','42501');
 perform tests.expect_error('select * from private.push_config','42501');
 perform tests.expect_error('select * from private.push_deliveries','42501');
 perform tests.expect_error('select public.claim_push_deliveries(''invalid'')','42501');
 perform tests.as_admin();select session_id into s from private.push_devices where installation_id=install;delete from auth.sessions where id=s;
 perform tests.assert_eq((select count(*) from private.push_devices where installation_id=install)::int,0,'session revocation drops token');
 -- Keep the deleted session ID in the presented JWT, emulating a stale access token.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'role','authenticated','session_id',s)::text,true);
 set local role authenticated;
 perform tests.expect_error(format('select public.register_push_device(%L,''aabb'',true)',install),'session_expired');
 perform tests.act_as_anon();perform tests.expect_error(format('select public.register_push_device(%L,''aabb'',true)',install),'42501');
 perform tests.expect_error('select public.claim_push_deliveries(''invalid'')','forbidden');
end $$;

create function tests.test_push_assignment_scopes_logout_and_token_rotation() returns void language plpgsql as $$
declare a uuid:=tests.player('push_account_a');b uuid:=tests.player('push_account_b');install uuid:=gen_random_uuid();other uuid:=gen_random_uuid();v jsonb;generation bigint;old_session uuid;
begin
 perform tests.push_configure();perform tests.act_as(a);v:=public.register_push_device(install,'aabb',true);generation:=(v->>'generation')::bigint;
 v:=public.register_push_device(install,'aabb',true);perform tests.assert_eq((v->>'generation')::bigint,generation,'same live registration is idempotent');
 perform tests.as_admin();select session_id into old_session from private.push_devices where installation_id=install;
 perform tests.act_as(b);v:=public.register_push_device(install,'aabb',true);perform tests.assert_eq((v->>'generation')::bigint,1::bigint,'new account gets its own scoped destination');
 perform tests.act_as(a);perform public.revoke_push_device(install);
 perform tests.as_admin();perform tests.assert_eq((select player_id from private.push_devices where installation_id=install),b,'old account logout cannot revoke new account assignment');
 delete from auth.sessions where id=old_session;
 perform tests.assert_eq((select count(*) from private.push_devices where installation_id=install)::int,1,'old auth session deletion cannot cascade into new assignment');
 perform tests.act_as(b);v:=public.register_push_device(other,'aabb',true);
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_devices where device_token='aabb')::int,1,'one canonical delivery destination per token');
 perform tests.act_as(b);perform public.revoke_push_device(other);perform public.revoke_push_device(other);
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_devices where player_id=b)::int,0,'current revoke is idempotent');
end $$;

create function tests.test_push_installation_id_knowledge_is_not_device_ownership_and_registration_cap() returns void language plpgsql as $$
declare a uuid:=tests.player('push_scope_owner');b uuid:=tests.player('push_scope_attacker');install uuid:=gen_random_uuid();v jsonb;
begin
 perform tests.push_configure();perform tests.act_as(a);perform public.register_push_device(install,'aabb',true);
 perform tests.act_as(b);perform public.register_push_device(install,'ccdd',true);perform public.revoke_push_device(install);
 perform tests.as_admin();perform tests.assert_eq((select device_token from private.push_devices where player_id=a and installation_id=install),'aabb','same UUID with another token cannot overwrite victim');
 perform tests.assert_eq((select count(*) from private.push_devices where player_id=a)::int,1,'attacker revoke is scoped to their account/session');
 perform tests.act_as(b);
 for i in 1..20 loop perform public.register_push_device(gen_random_uuid(),lpad(to_hex(i+65535),6,'0'),true);end loop;
 perform tests.expect_error(format('select public.register_push_device(%L,''eeee'',true)',gen_random_uuid()),'rate_limited');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_devices where player_id=b)::int,20,'per-user destinations bounded');
end $$;

create function tests.test_push_group_removal_and_deleted_post_revoke_claimed_deliveries() returns void language plpgsql as $$
declare a uuid:=tests.player('push_group_owner');b uuid:=tests.player('push_group_reader');dm uuid:=tests.push_dm(a,b);c uuid;p uuid;v jsonb;j uuid;l uuid;
begin
 perform tests.push_configure();perform tests.act_as(b);perform public.register_push_device(gen_random_uuid(),'aabb',true);
 perform tests.act_as(a);c:=(public.create_conversation(jsonb_build_object('kind','group','title','Настоящая группа','player_ids',jsonb_build_array(b),'client_id',gen_random_uuid()))->>'id')::uuid;
 perform public.send_message(c,'До исключения',gen_random_uuid());v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(a);perform public.conversation_member_action(c,b,'remove');
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'removed member receives no claimed group alert');
 perform tests.act_as(b);p:=(public.create_post(jsonb_build_object('body','Публикация','client_id',gen_random_uuid()))->>'id')::uuid;
 perform tests.act_as(a);perform public.comment_on_post(p,'Комментарий',gen_random_uuid());v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(b);perform public.delete_post(p);
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'deleted post is rechecked before alert');
end $$;

create function tests.test_push_queue_fencing_retry_and_real_message_payload() returns void language plpgsql as $$
declare a uuid:=tests.player('push_sender');b uuid:=tests.player('push_recipient');c uuid:=tests.push_dm(a,b);install uuid:=gen_random_uuid();v jsonb;j uuid;l uuid;old_lease uuid;
begin
 perform tests.push_configure();perform tests.act_as(b);perform public.register_push_device(install,'aabb',true);
 perform tests.act_as(a);perform public.send_message(c,'Секретный текст, никогда не для lock screen',gen_random_uuid());
 v:=tests.push_claim();perform tests.assert_eq(jsonb_array_length(v->'items'),1,'actual message enqueues one device job');
 j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.assert_eq(jsonb_array_length(public.claim_push_deliveries(tests.push_secret())->'items'),0,'live lease excludes other claims');
 v:=public.authorize_push_delivery(tests.push_secret(),j,l);perform tests.assert(v is not null,'fresh privacy authorization returns destination');
 perform tests.assert(not(v?'body') and not(v?'title') and not(v?'actor_id') and not(v?'resource_id'),'worker destination has no content/actor/resource metadata');
 perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,gen_random_uuid()),null::jsonb,'wrong fencing token cannot authorize');
 old_lease:=l;perform tests.as_admin();update private.push_deliveries set lease_until=now()-interval '1 second' where id=j;
 v:=tests.push_claim();l:=(v->'items'->0->>'lease_id')::uuid;perform tests.assert(l<>old_lease,'expired lease reclaimed with new fence');
 perform tests.assert_eq((public.finish_push_delivery(tests.push_secret(),j,old_lease,'accepted')->>'updated')::boolean,false,'late old worker cannot acknowledge new lease');
 perform public.finish_push_delivery(tests.push_secret(),j,l,'retry','ServiceUnavailable');
 perform tests.as_admin();perform tests.assert((select status='pending' and available_at>=now()+interval '15 minutes' and attempts=2 from private.push_deliveries where id=j),'transient response gets bounded delayed retry');
 update private.push_deliveries set available_at=now()-interval '1 second' where id=j;
 v:=tests.push_claim();l:=(v->'items'->0->>'lease_id')::uuid;perform public.finish_push_delivery(tests.push_secret(),j,l,'accepted');
 perform tests.as_admin();perform tests.assert_eq((select status from private.push_deliveries where id=j),'accepted','records APNs acceptance only after successful response');
 perform tests.assert_eq((select count(*) from private.push_deliveries where id=j)::int,1,'no duplicate job from retries');
end $$;

create function tests.test_push_privacy_mute_block_membership_and_read_recheck() returns void language plpgsql as $$
declare a uuid:=tests.player('push_privacy_a');b uuid:=tests.player('push_privacy_b');c uuid:=tests.push_dm(a,b);install uuid:=gen_random_uuid();v jsonb;j uuid;l uuid;
begin
 perform tests.push_configure();perform tests.act_as(b);perform public.register_push_device(install,'aabb',true);
 perform tests.act_as(a);perform public.send_message(c,'До отключения уведомлений',gen_random_uuid());
 v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(b);perform public.update_social_settings('{"notify_messages":false}');
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'mute after claim prevents send');
 perform tests.act_as(b);perform public.update_social_settings('{"notify_messages":true}');perform public.read_social_notifications();
 perform tests.act_as(a);perform public.send_message(c,'До прочтения',gen_random_uuid());
 v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(b);perform public.read_social_notifications();
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'read after claim prevents stale alert');
 perform tests.act_as(a);perform public.send_message(c,'До блокировки',gen_random_uuid());
 v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(b);perform public.block_player(a);
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'block after claim revokes destination');
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_deliveries where status='leased')::int,0,'blocked source notification cascade removes leases');
end $$;

create function tests.test_push_dead_token_protects_new_registration_and_delete_cleanup() returns void language plpgsql as $$
declare a uuid:=tests.player('push_dead_sender');b uuid:=tests.player('push_dead_reader');c uuid:=tests.push_dm(a,b);install uuid:=gen_random_uuid();v jsonb;j uuid;l uuid;old_ms bigint;
begin
 perform tests.push_configure();perform tests.act_as(b);perform public.register_push_device(install,'aabb',true);
 perform tests.act_as(a);perform public.send_message(c,'Проверка старого invalidation',gen_random_uuid());
 v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 old_ms:=floor(extract(epoch from clock_timestamp()-interval '1 hour')*1000)::bigint;
 perform tests.act_as(b);perform public.register_push_device(install,'aabb',true);
 perform tests.act_as_anon();perform public.finish_push_delivery(tests.push_secret(),j,l,'dead_token','Unregistered',old_ms);
 perform tests.as_admin();perform tests.assert((select enabled from private.push_devices where installation_id=install),'old APNs timestamp cannot disable newly retrieved token');
 perform tests.act_as(a);perform public.send_message(c,'Проверка реального invalidation',gen_random_uuid());
 v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform public.finish_push_delivery(tests.push_secret(),j,l,'dead_token','BadDeviceToken');
 perform tests.as_admin();perform tests.assert(not(select enabled from private.push_devices where installation_id=install),'confirmed invalid current token disabled');
 perform tests.act_as(b);perform public.register_push_device(install,'ccdd',true);
 perform tests.act_as_service();perform public.svc_anonymize_account(b);
 perform tests.as_admin();perform tests.assert_eq((select count(*) from private.push_devices where player_id=b)::int,0,'account deletion erases device token');
 perform tests.assert_eq((select count(*) from private.push_deliveries)::int,0,'account deletion cascades all delivery state');
end $$;

create function tests.test_push_disabled_registration_revokes_pending_and_no_backfill() returns void language plpgsql as $$
declare a uuid:=tests.player('push_disabled_a');b uuid:=tests.player('push_disabled_b');c uuid:=tests.push_dm(a,b);install uuid:=gen_random_uuid();v jsonb;j uuid;l uuid;
begin
 perform tests.act_as(a);perform public.send_message(c,'До подключения устройства',gen_random_uuid());
 perform tests.push_configure();perform tests.act_as(b);perform public.register_push_device(install,'aabb',true);
 perform tests.assert_eq(jsonb_array_length(tests.push_claim()->'items'),0,'registration does not replay old inbox');
 perform tests.act_as(a);perform public.send_message(c,'После подключения',gen_random_uuid());
 v:=tests.push_claim();j:=(v->'items'->0->>'id')::uuid;l:=(v->'items'->0->>'lease_id')::uuid;
 perform tests.act_as(b);perform public.register_push_device(install,'aabb',false);
 perform tests.act_as_anon();perform tests.assert_eq(public.authorize_push_delivery(tests.push_secret(),j,l),null::jsonb,'disabled registration fences claimed job');
 perform tests.act_as(a);perform public.send_message(c,'На отключённое устройство',gen_random_uuid());
 perform tests.assert_eq(jsonb_array_length(tests.push_claim()->'items'),0,'disabled device gets no new jobs');
end $$;
