-- Social and scheduled-game user scenarios. All data is isolated and rolled
-- back by the existing runner, using real SQL roles and live auth sessions.

create function tests.scheduled_payload(p_client uuid default null, p_starts timestamptz default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_id', coalesce(p_client, gen_random_uuid()), 'starts_at', coalesce(p_starts, now() + interval '2 days'),
    'city_id', 1, 'club_id', null, 'location', 'Корт № 1', 'match_type', 'ranked', 'min_level', 2, 'max_level', 4, 'note', 'Парная игра')
$$;

create function tests.established(p_player uuid, p_mu double precision default 3, p_sigma double precision default 0.25, p_matches integer default 5)
returns void language plpgsql as $$
begin
  perform tests.as_admin();
  update public.player_ratings set mu = p_mu, sigma = p_sigma, ranked_matches = p_matches, last_ranked_at = now() where player_id = p_player;
end;
$$;

create function tests.test_friendship_lifecycle_and_privacy()
returns void language plpgsql as $$
declare
  a uuid := tests.player('fr_alex'); b uuid := tests.player('fr_boris'); outsider uuid := tests.player('fr_outsider');
  v jsonb;
begin
  update public.profiles set discoverable = false where id = a;
  perform tests.act_as(outsider);
  perform tests.expect_error(format('select public.friendship_action(%L, ''request'')', a), 'player_not_found', 'hidden player cannot receive unsolicited requests');
  perform tests.act_as(a);
  v := public.friendship_action(b, 'request');
  perform tests.assert_eq(v ->> 'status', 'outgoing', 'new request outgoing');
  perform tests.assert_eq(public.friendship_action(b, 'request') ->> 'status', 'outgoing', 'request retry idempotent');
  perform tests.expect_error(format('select public.friendship_action(%L, ''accept'')', b), 'friendship_not_incoming', 'cannot accept own request');
  perform tests.assert_eq(jsonb_array_length(public.friendships() -> 'outgoing'), 1, 'no duplicate outgoing');
  perform tests.act_as(b);
  perform tests.assert_eq(public.friendship_status(a) ->> 'status', 'incoming', 'recipient sees incoming');
  v := public.player_profile(a);
  perform tests.assert_eq(v -> 'profile' ->> 'username', 'fr_alex', 'hidden requester invites recipient to inspect their public profile');
  perform tests.assert(v::text not like '%@padel.test%' and not (v ? 'email'), 'friendship never shares account data');
  perform tests.assert_eq(public.friendship_action(a, 'request') ->> 'status', 'incoming', 'opposing request does not silently accept');
  perform tests.expect_error(format('select public.friendship_action(%L, ''cancel'')', a), 'friendship_not_outgoing', 'recipient cannot cancel sender request');
  perform tests.assert_eq(public.friendship_action(a, 'accept') ->> 'status', 'accepted', 'explicit acceptance');
  perform tests.assert_eq(public.friendship_action(a, 'accept') ->> 'status', 'accepted', 'accept retry');
  perform tests.assert_eq(jsonb_array_length(public.friendships() -> 'accepted'), 1, 'accepted list');
  perform tests.assert(public.search_players('{"query":"fr_alex"}')::text like '%' || a || '%', 'accepted hidden friend searchable');
  perform tests.act_as(outsider);
  perform tests.expect_error(format('select public.player_profile(%L)', a), 'player_not_found', 'unrelated viewer still blocked');
  perform tests.expect_error(format('select public.friendship_action(%L, ''accept'')', a), 'friendship_not_pending', 'outsider cannot accept others relationship');
  perform tests.act_as(b);
  perform tests.assert_eq(public.friendship_action(a, 'remove') ->> 'status', 'none', 'remove accepted friend');
  perform tests.assert_eq(public.friendship_action(a, 'remove') ->> 'status', 'none', 'remove retry');
  perform tests.expect_error(format('select public.player_profile(%L)', a), 'player_not_found', 'remove revokes hidden profile access');
  perform tests.act_as(a);
  perform public.friendship_action(b, 'request');
  perform tests.assert_eq(public.friendship_action(b, 'cancel') ->> 'status', 'none', 'cancel outgoing');
  perform public.friendship_action(b, 'request');
  perform tests.act_as(b);
  perform tests.assert_eq(public.friendship_action(a, 'reject') ->> 'status', 'none', 'reject incoming');
  perform tests.assert_eq(public.friendship_action(a, 'reject') ->> 'status', 'none', 'reject retry');
  perform tests.act_as(a); perform public.friendship_action(b, 'request');
  perform tests.as_admin(); update public.profiles set discoverable = false where id = b;
  perform tests.act_as(a);
  v := public.friendships();
  perform tests.assert((v -> 'outgoing' -> 0 -> 'player' ->> 'username') is null, 'outgoing request cannot reveal newly hidden recipient');
  perform tests.expect_error(format('select public.player_profile(%L)', b), 'player_not_found', 'outgoing request does not grant recipient-profile access');
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.friendships)::integer, 1, 'one canonical pair through whole lifecycle');
end;
$$;

create function tests.test_scheduled_admission_boundaries()
returns void language plpgsql as $$
declare
  owner uuid := tests.player('ad_owner'); edge uuid := tests.player('ad_edge'); low uuid := tests.player('ad_low');
  early uuid := tests.player('ad_early'); high uuid := tests.player('ad_high'); novice uuid := tests.player('ad_novice');
  idle uuid := tests.player('ad_idle'); m uuid; v jsonb;
begin
  perform tests.established(edge, 2, 0.46, 5); -- reliability exactly 70
  perform tests.established(low, 3, 0.47, 5); -- reliability 69
  perform tests.established(early, 3, 0.25, 4); -- reliable but not established
  perform tests.established(high, 4.001, 0.25, 5);
  perform tests.established(novice, 6, 1.2, 0);
  perform tests.established(idle, 3, 0.25, 20);
  update public.player_ratings set last_ranked_at = now() - interval '450 days' where player_id = idle;
  perform tests.act_as(owner);
  m := (public.create_scheduled_match(tests.scheduled_payload()) ->> 'id')::uuid;
  perform tests.act_as(edge);
  v := public.join_scheduled_match(m);
  perform tests.assert_eq(v -> 'viewer' ->> 'admission', 'auto', 'inclusive minimum and 70% reliability');
  perform tests.assert_eq(v -> 'viewer' ->> 'participation', 'accepted', 'auto takes a seat');
  perform tests.act_as(low);
  v := public.join_scheduled_match(m);
  perform tests.assert_eq(v -> 'viewer' ->> 'participation', 'pending', '69% asks organizer');
  perform tests.act_as(early);
  perform tests.assert_eq(public.join_scheduled_match(m) -> 'viewer' ->> 'participation', 'pending', 'four ranked matches cannot auto join');
  perform tests.act_as(high);
  perform tests.expect_error(format('select public.join_scheduled_match(%L)', m), 'level_out_of_range', 'established player above inclusive max rejected');
  perform tests.act_as(novice);
  v := public.join_scheduled_match(m);
  perform tests.assert_eq(v -> 'viewer' ->> 'participation', 'pending', 'uncertain out-of-band novice may apply');
  perform tests.assert_eq(jsonb_array_length(v -> 'applications'), 1, 'applicant sees only own application');
  perform tests.act_as(idle);
  perform tests.assert_eq(public.join_scheduled_match(m) -> 'viewer' ->> 'admission', 'approval', 'inactivity uncertainty affects admission');
  perform tests.act_as(owner);
  v := public.scheduled_match(m);
  perform tests.assert_eq(jsonb_array_length(v -> 'applications'), 5, 'organizer sees applicants and their facts');
  perform tests.assert_eq((select x -> 'player' ->> 'reliability' from jsonb_array_elements(v -> 'applications') x
    where x -> 'player' ->> 'id' = edge::text), '70', 'real rating reliability in cards');
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.match_players)::integer, 0, 'admission does not create played-match confirmations');
  perform tests.assert_eq((select count(*) from public.rating_events where kind = 'match')::integer, 0, 'admission does not change rating');
end;
$$;

create function tests.test_scheduled_lifecycle_permissions_and_retry()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('sl_owner'), tests.player('sl_two'), tests.player('sl_three'), tests.player('sl_four'), tests.player('sl_extra')];
  key uuid := gen_random_uuid(); m uuid; v jsonb; payload jsonb;
begin
  for i in 2..5 loop perform tests.established(p[i], 3, 0.25, 5); end loop;
  perform tests.act_as(p[1]);
  payload := tests.scheduled_payload(key);
  m := (public.create_scheduled_match(payload) ->> 'id')::uuid;
  perform tests.assert_eq(public.create_scheduled_match(payload) ->> 'id', m::text, 'create retry same identity');
  perform tests.expect_error(format('select public.leave_scheduled_match(%L)', m), 'organizer_cannot_leave', 'organizer cancels game instead of leaving');
  for i in 2..4 loop
    perform tests.act_as(p[i]);
    v := public.join_scheduled_match(m);
    perform tests.assert_eq(public.join_scheduled_match(m) -> 'viewer' ->> 'participation', 'accepted', 'join retry');
  end loop;
  perform tests.assert_eq(v ->> 'status', 'full', 'four seats full');
  perform tests.act_as(p[5]);
  perform tests.expect_error(format('select public.join_scheduled_match(%L)', m), 'scheduled_match_full', 'fifth seat forbidden');
  perform tests.expect_error(format('select public.cancel_scheduled_match(%L)', m), 'organizer_required', 'only owner cancels');
  perform tests.expect_error(format('select public.review_scheduled_application(%L,%L,''accepted'')', m, p[3]), 'organizer_required', 'only owner reviews');
  perform tests.act_as(p[3]);
  v := public.leave_scheduled_match(m);
  perform tests.assert_eq(v ->> 'status', 'open', 'leave releases seat');
  perform tests.assert_eq(public.leave_scheduled_match(m) ->> 'spots_left', '1', 'leave retry releases exactly one seat');
  perform tests.act_as(p[5]);
  perform tests.assert_eq(public.join_scheduled_match(m) ->> 'status', 'full', 'released seat can be filled');
  perform tests.act_as(p[1]);
  perform tests.assert_eq(public.cancel_scheduled_match(m) ->> 'status', 'cancelled', 'cancel state');
  perform tests.assert_eq(public.cancel_scheduled_match(m) ->> 'status', 'cancelled', 'cancel retry');
  perform tests.act_as(p[3]);
  perform tests.expect_error(format('select public.join_scheduled_match(%L)', m), 'scheduled_match_closed', 'cancelled game cannot be joined');
  perform tests.act_as(p[5]);
  perform tests.assert_eq(public.scheduled_match(m) ->> 'status', 'cancelled', 'participant sees cancellation');
  perform tests.assert_eq(jsonb_array_length(public.scheduled_matches('{"scope":"open"}') -> 'items'), 0, 'cancelled absent from public feed');
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.scheduled_matches)::integer, 1, 'create retry one row');
  perform tests.assert_eq((select count(*) from public.scheduled_match_players where match_id = m and status = 'accepted')::integer, 4, 'lineup preserved when whole game cancelled');
end;
$$;

create function tests.test_scheduled_applications_and_hidden_roster()
returns void language plpgsql as $$
declare
  owner uuid := tests.player('sp_owner'); applicant uuid := tests.player('sp_applicant'); outsider uuid := tests.player('sp_out');
  m uuid; v jsonb;
begin
  update public.profiles set discoverable = false where id = applicant;
  perform tests.act_as(owner);
  m := (public.create_scheduled_match(tests.scheduled_payload()) ->> 'id')::uuid;
  perform tests.act_as(applicant);
  perform public.join_scheduled_match(m);
  perform tests.assert_eq(public.join_scheduled_match(m) -> 'viewer' ->> 'participation', 'pending', 'application retry');
  perform tests.act_as(outsider);
  v := public.scheduled_match(m);
  perform tests.assert_eq(jsonb_array_length(v -> 'applications'), 0, 'applications private to owner and applicant');
  perform tests.expect_error(format('select public.player_profile(%L)', applicant), 'player_not_found', 'applicant profile remains hidden to outsiders');
  perform tests.act_as(owner);
  v := public.scheduled_match(m);
  perform tests.assert_eq(v -> 'applications' -> 0 -> 'player' ->> 'username', 'sp_applicant', 'organizer sees applicant facts');
  perform public.review_scheduled_application(m, applicant, 'rejected');
  perform tests.assert_eq(public.review_scheduled_application(m, applicant, 'rejected') -> 'applications' -> 0 ->> 'status', 'rejected', 'reject retry');
  perform tests.act_as(applicant);
  perform public.join_scheduled_match(m);
  perform tests.act_as(owner);
  perform public.review_scheduled_application(m, applicant, 'accepted');
  perform tests.assert_eq(public.review_scheduled_application(m, applicant, 'accepted') ->> 'spots_left', '2', 'accept retry no duplicate seat');
  perform tests.assert_eq(public.player_profile(applicant) -> 'profile' ->> 'username', 'sp_applicant', 'admitted players may view shared lineup profile');
  perform tests.act_as(outsider);
  v := public.scheduled_match(m);
  perform tests.assert(v::text not like '%sp_applicant%', 'hidden admitted player identity masked in public feed');
  perform tests.assert_eq(v -> 'participants' -> 1 -> 'player' ->> 'display_name', 'Скрытый игрок', 'stable private card shape');
  perform tests.act_as(owner);
  perform public.cancel_scheduled_match(m);
  perform tests.expect_error(format('select public.player_profile(%L)', applicant), 'player_not_found', 'cancelled game no longer grants hidden-profile access');
end;
$$;

create function tests.test_scheduled_result_link_and_confirmations()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('res_owner'), tests.player('res_two'), tests.player('res_three'), tests.player('res_four')];
  other uuid := tests.player('res_other'); other_club bigint; m uuid; result_id uuid; key uuid := gen_random_uuid(); payload jsonb; v jsonb;
begin
  for i in 2..4 loop perform tests.established(p[i]); end loop;
  perform tests.act_as(p[1]);
  m := (public.create_scheduled_match(tests.scheduled_payload()) ->> 'id')::uuid;
  for i in 2..4 loop perform tests.act_as(p[i]); perform public.join_scheduled_match(m); end loop;
  payload := jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '1 hour',
    'players', tests.lineup(p), 'sets', tests.sets(6, 4, 6, 3));
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.submit_scheduled_result(%L,%L::jsonb,%L)', m, payload, key), 'scheduled_match_not_started', 'cannot enter future score');
  perform tests.as_admin();
  update public.scheduled_matches set starts_at = now() - interval '2 hours' where id = m;
  perform tests.act_as(other);
  perform tests.expect_error(format('select public.submit_scheduled_result(%L,%L::jsonb,%L)', m, payload, key), 'scheduled_match_not_found', 'outsider cannot enter result');
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.submit_scheduled_result(%L,%L::jsonb,%L)', m,
    jsonb_set(payload, '{players}', tests.lineup(array[p[1],p[2],p[3],other])), key), 'scheduled_lineup_mismatch', 'admitted lineup cannot be substituted');
  v := public.submit_scheduled_result(m, payload, key); result_id := (v ->> 'id')::uuid;
  perform tests.assert_eq(v ->> 'status', 'pending', 'linked result still needs confirmations');
  perform tests.assert_eq(v ->> 'scheduled_match_id',m::text,'first result response includes scheduled identity');
  perform tests.assert_eq((v ->> 'scheduled_starts_at')::timestamptz,now()-interval '2 hours','scheduled result retains earliest playable date');
  perform tests.assert_eq(public.scheduled_match(m) ->> 'status', 'result_pending', 'schedule linked pending');
  perform tests.assert_eq(public.submit_scheduled_result(m, payload, key) ->> 'id', result_id::text, 'lost response retry');
  perform tests.expect_error(format('select public.update_match(%L,1,%L::jsonb,gen_random_uuid())', result_id,
    jsonb_set(payload, '{players}', tests.lineup(array[p[1],p[2],p[3],other]))), 'scheduled_lineup_mismatch', 'old editor cannot replace linked admitted roster');
  perform tests.expect_error(format('select public.update_match(%L,1,%L::jsonb,gen_random_uuid())', result_id,
    jsonb_set(payload, '{match_type}', '"friendly"')), 'scheduled_result_mismatch', 'old editor cannot change scheduled match type');
  perform tests.as_admin();
  insert into public.clubs(city_id,name) values (1,'Другой корт') returning id into other_club;
  perform tests.act_as(p[1]);
  perform tests.expect_error(format('select public.update_match(%L,1,%L::jsonb,gen_random_uuid())', result_id,
    jsonb_set(payload, '{club_id}', to_jsonb(other_club))), 'scheduled_result_mismatch', 'old editor cannot substitute scheduled club');
  perform tests.expect_error(format('select public.update_match(%L,1,%L::jsonb,gen_random_uuid())', result_id,
    jsonb_set(payload, '{played_at}', to_jsonb(now()-interval '3 hours'))), 'scheduled_result_mismatch', 'old editor cannot backdate result before game');
  perform tests.act_as(p[2]);
  perform tests.assert_eq(public.submit_scheduled_result(m, payload, gen_random_uuid()) ->> 'id', result_id::text, 'other participant exact result uses same link');
  perform tests.expect_error(format('select public.submit_scheduled_result(%L,%L::jsonb,gen_random_uuid())', m,
    jsonb_set(payload, '{sets}', tests.sets(6, 1, 6, 1))), 'scheduled_result_mismatch', 'different result cannot overwrite link');
  perform tests.expect_error(format('select public.leave_scheduled_match(%L)', m), 'scheduled_match_closed', 'linked lineup frozen');
  perform tests.assert_eq(public.player_profile(p[1]) -> 'stats' ->> 'matches', '0', 'unconfirmed result absent from stats');
  perform public.confirm_match(result_id, 1);
  perform tests.act_as(p[3]); perform public.confirm_match(result_id, 1);
  perform tests.assert_eq(public.scheduled_match(m) ->> 'status', 'result_pending', 'three confirmations not enough');
  perform tests.act_as(p[4]); perform public.confirm_match(result_id, 1);
  perform tests.assert_eq(public.scheduled_match(m) ->> 'status', 'completed', 'four confirmations complete scheduled game');
  perform tests.assert_eq(public.player_profile(p[1]) -> 'stats' ->> 'matches', '1', 'confirmed result counts once');
  perform tests.as_admin();
  perform tests.assert_eq((select count(*) from public.matches)::integer, 1, 'all retries one played result');
  perform tests.assert_eq((select count(*) from public.rating_events where match_id = result_id)::integer, 4, 'one rating event per participant');
end;
$$;

create function tests.test_scheduled_closed_result_is_not_cancelled_game()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('closed_owner'),tests.player('closed_two'),tests.player('closed_three'),tests.player('closed_four')];
  m uuid; result_id uuid; payload jsonb; v jsonb;
begin
  for i in 2..4 loop perform tests.established(p[i]); end loop;
  for attempt in 1..2 loop
    perform tests.act_as(p[1]);
    m := (public.create_scheduled_match(tests.scheduled_payload()) ->> 'id')::uuid;
    for i in 2..4 loop perform tests.act_as(p[i]); perform public.join_scheduled_match(m); end loop;
    perform tests.as_admin(); update public.scheduled_matches set starts_at=now()-interval '2 hours' where id=m;
    payload := jsonb_build_object('match_type','ranked','format','best_of_3','played_at',now()-interval '1 hour',
      'players',tests.lineup(p),'sets',tests.sets(6,4,6,3));
    perform tests.act_as(p[1]);
    result_id := (public.submit_scheduled_result(m,payload,gen_random_uuid()) ->> 'id')::uuid;
    if attempt=1 then
      perform public.cancel_match(result_id,1);
    else
      perform tests.as_admin();
      set local session_replication_role = replica;
      update public.matches set updated_at=now()-interval '8 days' where id=result_id;
      set local session_replication_role = origin;
      perform private.expire_if_stale(result_id);
      perform tests.act_as(p[1]);
    end if;
    v := public.scheduled_match(m);
    perform tests.assert_eq(v ->> 'status','result_pending','a closed score does not mean the played game was cancelled');
    perform tests.assert_eq(v ->> 'result_status',case when attempt=1 then 'cancelled' else 'expired' end,'score state remains separately visible');
    perform tests.assert_eq(jsonb_array_length(v -> 'participants'),4,'closed score preserves admitted lineup');
    perform tests.assert_eq(public.submit_scheduled_result(m,payload,gen_random_uuid()) ->> 'id',result_id::text,'retry cannot create a replacement for closed linked score');
  end loop;
end;
$$;

create function tests.test_scheduled_validation_security_and_lifecycle()
returns void language plpgsql as $$
declare
  owner uuid := tests.player('sv_owner'); member uuid := tests.player('sv_member'); payload jsonb; m uuid; v jsonb; t text;
begin
  perform tests.act_as(owner);
  payload := tests.scheduled_payload();
  perform tests.expect_error(format('select public.create_scheduled_match(%L::jsonb)', jsonb_set(payload, '{starts_at}', to_jsonb(now() - interval '1 day'))), 'invalid_scheduled_match');
  perform tests.expect_error(format('select public.create_scheduled_match(%L::jsonb)', jsonb_set(payload, '{max_level}', '1')), 'invalid_scheduled_match');
  perform tests.expect_error(format('select public.create_scheduled_match(%L::jsonb)', jsonb_set(payload, '{location}', '""')), 'invalid_scheduled_match');
  perform tests.expect_error(format('select public.create_scheduled_match(%L::jsonb)', payload - 'client_id'), 'idempotency_key_required');
  perform tests.expect_error(format('select public.create_scheduled_match(%L::jsonb)', jsonb_set(payload, '{min_level}', '"NaN"')), 'invalid_scheduled_match');
  foreach t in array array['friendships', 'scheduled_matches', 'scheduled_match_players'] loop
    perform tests.expect_error(format('select * from public.%I', t), '42501', 'no direct social table access');
    perform tests.expect_error(format('delete from public.%I', t), '42501');
  end loop;
  perform tests.expect_error(format('select private.scheduled_json(%L,%L)', gen_random_uuid(), member), '42501', 'private serializer cannot impersonate viewer');
  m := (public.create_scheduled_match(payload) ->> 'id')::uuid;
  perform tests.act_as(member); perform public.join_scheduled_match(m);
  perform tests.act_as(owner); perform public.review_scheduled_application(m, member, 'accepted');
  perform public.friendship_action(member, 'request');
  perform tests.act_as(member); perform public.friendship_action(owner, 'accept');
  perform tests.act_as_service();
  perform tests.expect_error('select public.friendships()', '42501', 'service cannot impersonate end-user');
  perform public.svc_anonymize_account(member);
  perform tests.act_as(owner);
  v := public.scheduled_match(m);
  perform tests.assert_eq(v ->> 'spots_left', '3', 'deleted participant releases future seat');
  perform tests.assert_eq(jsonb_array_length(public.friendships() -> 'accepted'), 0, 'deleted friend removed');
  perform tests.act_as_service(); perform public.svc_anonymize_account(owner);
  perform tests.as_admin();
  perform tests.assert((select cancelled_at is not null from public.scheduled_matches where id = m), 'deleted organizer cancels their future game');
  perform tests.act_as_anon();
  perform tests.expect_error('select public.scheduled_matches(''{}'')', '42501', 'public feed requires signed in player');
end;
$$;

create function tests.test_scheduled_result_replay_after_time_and_deletion()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('retry_owner'), tests.player('retry_two'), tests.player('retry_three'), tests.player('retry_four')];
  m uuid; result_id uuid; key uuid := gen_random_uuid(); payload jsonb; old_date timestamptz := now() - interval '30 days';
begin
  for i in 2..4 loop perform tests.established(p[i]); end loop;
  perform tests.act_as(p[1]);
  m := (public.create_scheduled_match(tests.scheduled_payload()) ->> 'id')::uuid;
  for i in 2..4 loop perform tests.act_as(p[i]); perform public.join_scheduled_match(m); end loop;
  perform tests.as_admin(); update public.scheduled_matches set starts_at = now() - interval '2 hours' where id = m;
  payload := jsonb_build_object('match_type', 'ranked', 'format', 'best_of_3', 'played_at', now() - interval '1 hour',
    'players', tests.lineup(p), 'sets', tests.sets(6,4,6,3));
  perform tests.act_as(p[1]);
  result_id := (public.submit_scheduled_result(m, payload, key) ->> 'id')::uuid;
  -- Model an original submission made thirty days ago. An ordinary new ranked
  -- result now fails the fourteen-day window; its lost-response retry must not.
  perform tests.as_admin();
  update public.scheduled_matches set starts_at = old_date - interval '1 hour', result_input = jsonb_set(result_input, '{played_at}', to_jsonb(old_date)) where id = m;
  update public.matches set played_at = old_date where id = result_id;
  payload := jsonb_set(payload, '{played_at}', to_jsonb(old_date));
  perform tests.act_as(p[1]);
  perform tests.assert_eq(public.submit_scheduled_result(m,payload,key) ->> 'id', result_id::text, 'replay ignores elapsed new-result window');
  perform tests.act_as_service(); perform public.svc_anonymize_account(p[3]);
  perform tests.act_as(p[1]);
  perform tests.assert_eq(public.submit_scheduled_result(m,payload,key) ->> 'id', result_id::text, 'replay survives another participant deletion');
  perform tests.expect_error(format('select public.submit_scheduled_result(%L,%L::jsonb,%L)', m,
    jsonb_set(payload, '{sets}', tests.sets(6,1,6,1)), key), 'scheduled_result_mismatch', 'time-independent replay still rejects a changed score');
end;
$$;

create function tests.test_scheduled_mine_accepted_filter_and_order()
returns void language plpgsql as $$
declare
  me uuid := tests.player('home_me'); owner uuid := tests.player('home_owner'); pending uuid; accepted uuid; ready uuid; v jsonb;
begin
  perform tests.act_as(owner);
  pending := (public.create_scheduled_match(tests.scheduled_payload(null,now()+interval '1 day')) ->> 'id')::uuid;
  perform tests.act_as(me); perform public.join_scheduled_match(pending);
  accepted := (public.create_scheduled_match(tests.scheduled_payload(null,now()+interval '2 days')) ->> 'id')::uuid;
  ready := (public.create_scheduled_match(tests.scheduled_payload(null,now()+interval '3 days')) ->> 'id')::uuid;
  perform tests.as_admin(); update public.scheduled_matches set starts_at=now()-interval '1 day' where id=ready;
  perform tests.act_as(me);
  v := public.scheduled_matches('{"scope":"mine","accepted_only":true,"limit":1}');
  perform tests.assert_eq(v -> 'items' -> 0 ->> 'id', accepted::text, 'nearest future admitted game survives earlier pending applications and past history');
  perform tests.assert_eq(v ->> 'next_offset', '1', 'accepted mine page is paginated');
  perform tests.assert_eq(public.scheduled_matches('{"scope":"mine","limit":1}') -> 'items' -> 0 ->> 'id', pending::text, 'ordinary mine still includes applications');
  perform tests.expect_error('select public.scheduled_matches(''{"scope":"open","accepted_only":true}'')','invalid_request','accepted filter has unambiguous mine scope');
end;
$$;

create function tests.test_complete_streak_and_last_ten()
returns void language plpgsql as $$
declare
  p uuid[] := array[tests.player('form_one'), tests.player('form_two'), tests.player('form_three'), tests.player('form_four')];
  empty uuid := tests.player('form_empty'); m uuid; v jsonb;
begin
  -- An older opposite result forms a real boundary; twelve newer wins must
  -- produce a twelve-match streak while the recent form remains ten entries.
  m := tests.match(p, 'friendly', tests.sets(1, 6, 1, 6), 'best_of_3', now() - interval '20 days');
  perform tests.confirm_all(m);
  perform tests.act_as(p[1]);
  perform tests.assert_eq(public.player_profile(p[1]) -> 'stats' -> 'last_ten', '{"matches":1,"wins":0,"losses":1}'::jsonb, 'fewer than ten reports actual sample');
  for i in 1..12 loop
    m := tests.match(p, 'friendly', tests.sets(6, 1, 6, 1), 'best_of_3', now() - make_interval(days => i));
    perform tests.confirm_all(m);
  end loop;
  -- Pending latest match is never part of form or streak.
  perform tests.match(p, 'friendly', tests.sets(1, 6, 1, 6), 'best_of_3', now() - interval '1 hour');
  perform tests.act_as(p[1]);
  v := public.player_profile(p[1]) -> 'stats';
  perform tests.assert_eq(v -> 'streak' ->> 'count', '12', 'winning streak beyond ten');
  perform tests.assert_eq(v -> 'streak' ->> 'type', 'win', 'winning streak type');
  perform tests.assert_eq(jsonb_array_length(v -> 'form'), 10, 'form capped at ten');
  perform tests.assert_eq(v -> 'last_ten', '{"matches":10,"wins":10,"losses":0}'::jsonb, 'recent facts independent of all-time totals');
  perform tests.assert_eq(v ->> 'losses', '1', 'legacy aggregate losses preserved');
  v := public.player_profile(p[3]) -> 'stats';
  perform tests.assert_eq(v -> 'streak' ->> 'count', '12', 'losing streak beyond ten');
  perform tests.assert_eq(v -> 'streak' ->> 'type', 'loss', 'losing streak type');
  perform tests.assert_eq(v -> 'last_ten', '{"matches":10,"wins":0,"losses":10}'::jsonb, 'recent losing facts');
  perform tests.act_as(empty);
  v := public.player_profile(empty) -> 'stats';
  perform tests.assert_eq(v -> 'streak', 'null'::jsonb, 'zero matches has no streak');
  perform tests.assert_eq(v -> 'last_ten', '{"matches":0,"wins":0,"losses":0}'::jsonb, 'zero matches recent facts');
end;
$$;
