#!/usr/bin/env bash
# Regenerates the iOS test fixtures from the real database code.
#
# 1. Recreates a dedicated local database (default `padelid_fixtures`, never
#    the test database `padelid`) with the shim and all migrations.
# 2. Builds the scenario (scripts/fixtures/scenario.sql) through the API
#    functions.
# 3. Exports exactly the RPC results the API gateway passes through to the app,
#    acting as the users, into ios/PadelIDUITests/Fixtures and copies them to
#    ios/PadelIDTests/Fixtures.
#
# Connection: PGHOST (default /var/tmp/pgdev), PGPORT (54329), PGUSER (postgres).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export PGHOST=${PGHOST:-/var/tmp/pgdev}
export PGPORT=${PGPORT:-54329}
export PGUSER=${PGUSER:-postgres}
export PGTZ=UTC
export PGOPTIONS='-c client_min_messages=warning'
DB=${DB:-padelid_fixtures}

if [ "$DB" = "padelid" ]; then
  echo "export.sh: refusing to touch the test database 'padelid'; use another DB name" >&2
  exit 1
fi
for tool in psql jq python3; do
  command -v "$tool" >/dev/null || { echo "export.sh: $tool is required" >&2; exit 1; }
done

OUT="$ROOT/ios/PadelIDUITests/Fixtures"
COPY="$ROOT/ios/PadelIDTests/Fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT" "$COPY"

echo "Building database $DB"
DB="$DB" "$ROOT/scripts/db/reset-local.sh" >/dev/null
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$ROOT/scripts/fixtures/scenario.sql" >/dev/null

echo "Exporting API responses"
# Every export runs in its own transaction that is rolled back, so mutations
# (confirming, creating, onboarding) never change the scenario.
psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -v out="$TMP" <<'SQL'
select fixtures.pid('OR') as me \gset
select fixtures.pid('NEW') as newcomer \gset
select id as action from fixtures.refs where key = 'action' \gset
select id as recent from fixtures.refs where key = 'recent' \gset
select id as upcoming from fixtures.refs where key = 'upcoming_main' \gset
select id as upcoming_ready from fixtures.refs where key = 'upcoming_result_ready' \gset
select id as moscow from public.cities where name = 'Москва' and country_code = 'RU' \gset
-- The most frequent partner of the main user.
select mp2.player_id as partner
  from public.match_players mp
  join public.matches m on m.id = mp.match_id and m.status = 'confirmed'
  join public.match_players mp2 on mp2.match_id = mp.match_id and mp2.team = mp.team and mp2.player_id <> mp.player_id
 where mp.player_id = fixtures.pid('OR')
 group by mp2.player_id
 order by count(*) desc, mp2.player_id
 limit 1 \gset

begin;
\o :out/me.raw
select fixtures.run_as(:'me', 'select public.me()');
\o
rollback;

begin;
\o :out/me_new.raw
select fixtures.run_as(:'newcomer', 'select public.me()');
\o
rollback;

begin;
\o :out/home.raw
select fixtures.run_as(:'me', 'select public.home()');
\o
rollback;

begin;
\o :out/home_new.raw
select fixtures.run_as(:'newcomer',
  format('select public.complete_onboarding(%L::jsonb)', jsonb_build_object(
    'username', 'ilya_gromov', 'display_name', 'Илья Громов', 'city_id', :moscow,
    'club_id', fixtures.club('Corner Padel Club'),
    'preferred_side', 'right', 'dominant_hand', 'right', 'playing_since', 2025,
    'calibration', jsonb_build_object('experience', 'lt6m', 'frequency', 'monthly', 'racket', 'none',
                                      'glass', 1, 'net', 0, 'competition', 0),
    'dna_self', jsonb_build_object('serve_return', 0, 'defense', 0, 'transition_lob', 0,
                                   'net_game', 1, 'overheads', 0, 'consistency_decisions', -1))::text),
  'select public.home()');
\o
rollback;

begin;
\o :out/matches_open.raw
select fixtures.run_as(:'me', 'select public.my_matches(''open'', null, 30, null)');
\o
rollback;

begin;
\o :out/matches_history.raw
select fixtures.run_as(:'me', 'select public.my_matches(''history'', null, 30, null)');
\o
rollback;

begin;
\o :out/match_action.raw
select fixtures.run_as(:'me', format('select public.match_detail(%L)', :'action'));
\o
rollback;

begin;
\o :out/match_action_confirmed.raw
select fixtures.run_as(:'me', format('select public.confirm_match(%L, %s)', :'action',
  (select version from public.matches where id = :'action')));
\o
rollback;

begin;
\o :out/match_confirmed.raw
select fixtures.run_as(:'me', format('select public.match_detail(%L)', :'recent'));
\o
rollback;

begin;
\o :out/match_created.raw
select fixtures.run_as(:'me', format('select public.create_match(%L::jsonb, %L)', jsonb_build_object(
    'match_type', 'ranked', 'format', 'best_of_3',
    'played_at', least(date_trunc('hour', now()) - interval '1 hour', fixtures.at(0, '16:00')),
    'club_id', fixtures.club('Падел Арена Лужники'),
    'players', fixtures.lineup(array['OR', 'SO', 'NO', 'MO']),
    'sets', jsonb_build_array(fixtures.set(6, 3), fixtures.set(6, 4)))::text,
  fixtures.uuid('idempotency:created')));
\o
rollback;

begin;
\o :out/player_profile.raw
select fixtures.run_as(:'me', format('select public.player_profile(%L)', :'partner'));
\o
rollback;

begin;
\o :out/player_matches.raw
select fixtures.run_as(:'me', format('select public.player_matches(%L, null, 30, null)', :'partner'));
\o
rollback;

begin;
\o :out/rating_history.raw
select fixtures.run_as(:'me', format('select public.rating_history(%L, null)', :'me'));
\o
rollback;

begin;
\o :out/dna.raw
select fixtures.run_as(:'me', format('select public.player_dna(%L)', :'me'));
\o
rollback;

-- GET v1/players/search without parameters (the gateway drops undefined keys).
begin;
\o :out/search.raw
select fixtures.run_as(:'me',
  'select public.search_players(''{"query": "", "reliable_only": false, "coaches_only": false}''::jsonb)');
\o
rollback;

begin;
\o :out/recent_players.raw
select fixtures.run_as(:'me', 'select public.recent_players(20)');
\o
rollback;

begin;
\o :out/cities.raw
select fixtures.run_as(:'me', 'select public.list_cities(null)');
\o
rollback;

begin;
\o :out/clubs.raw
select fixtures.run_as(:'me', format('select public.list_clubs(%s, null)', :moscow));
\o
rollback;

begin;
\o :out/preview.raw
select fixtures.run_as(:'me', format('select public.preview_match(%L::jsonb)', jsonb_build_object(
    'format', 'best_of_3',
    'players', fixtures.lineup(array['OR', 'SO', 'NO', 'MO']),
    'sets', jsonb_build_array(fixtures.set(6, 3), fixtures.set(6, 4)))::text));
\o
rollback;

begin;
\o :out/username_check.raw
select fixtures.run_as(:'me', 'select public.check_username(''ilya_gromov'')');
\o
rollback;

begin;
\o :out/coach_application.raw
select fixtures.run_as(:'me', 'select public.coach_application()');
\o
rollback;

begin;
\o :out/friends.raw
select fixtures.run_as(:'me', 'select public.friendships()');
\o
rollback;

begin;
\o :out/friendship_status.raw
select fixtures.run_as(:'me', format('select public.friendship_status(%L)', fixtures.pid('SO')));
\o
rollback;

begin;
\o :out/upcoming_mine.raw
select fixtures.run_as(:'me', 'select public.scheduled_matches(''{"scope":"mine"}''::jsonb)');
\o
rollback;

begin;
\o :out/upcoming_home.raw
select fixtures.run_as(:'me', 'select public.scheduled_matches(''{"scope":"mine","accepted_only":true}''::jsonb)');
\o
rollback;

begin;
\o :out/upcoming_open.raw
select fixtures.run_as(:'me', 'select public.scheduled_matches(''{"scope":"open"}''::jsonb)');
\o
rollback;

begin;
\o :out/upcoming_match.raw
select fixtures.run_as(:'me', format('select public.scheduled_match(%L)', :'upcoming'));
\o
rollback;

begin;
\o :out/upcoming_result_ready.raw
select fixtures.run_as(:'me', format('select public.scheduled_match(%L)', :'upcoming_ready'));
\o
rollback;

begin;
\o :out/upcoming_linked_result.raw
select fixtures.run_as(:'me',format('select public.submit_scheduled_result(%L,%L::jsonb,%L)', :'upcoming_ready',jsonb_build_object(
  'match_type','ranked','format','best_of_3','played_at',now()-interval '1 hour',
  'club_id',fixtures.club('Падел Арена Лужники'),'players',fixtures.lineup(array['OR','SO','NO','MO']),
  'sets',jsonb_build_array(fixtures.set(6,3),fixtures.set(6,4)))::text,fixtures.uuid('idempotency:upcoming-result')));
\o
rollback;

\o :out/ids.raw
select concat_ws(' ', :'me', 'm.orlov@padelid.app', :'newcomer', (select email from fixtures.players where code = 'NEW'));
\o
SQL

for raw in "$TMP"/*.raw; do
  name="$(basename "$raw" .raw)"
  [ "$name" = "ids" ] && continue
  jq . "$raw" > "$OUT/$name.json"
done

# Sessions are issued by Supabase Auth, not by SQL: well-formed values with the
# real user ids, deterministic tokens and an expiry far in the future.
read -r ME_ID ME_EMAIL NEW_ID NEW_EMAIL < "$TMP/ids.raw"
token() {
  python3 -c 'import base64, hashlib, sys; print(base64.urlsafe_b64encode(hashlib.sha512(sys.argv[1].encode()).digest()).decode().rstrip("="))' "$1"
}
session() {
  jq -n --arg access "$(token "access:$1")" --arg refresh "$(token "refresh:$1")" --arg id "$1" --arg email "$2" \
    '{access_token: $access, refresh_token: $refresh, expires_in: 3600, expires_at: 4102444800, token_type: "bearer",
      user: {id: $id, email: $email}}'
}
session "$ME_ID" "$ME_EMAIL" > "$OUT/session.json"
session "$NEW_ID" "$NEW_EMAIL" > "$OUT/new_user_session.json"
jq '{session: ., recovery_key: "7K2QD-M4XPR-9HV3A-TC8WN"}' "$OUT/session.json" > "$OUT/signup.json"

# Validation: every fixture is non-empty, valid JSON, and only the coach
# application of a player without one is null.
expected=(me me_new home home_new matches_open matches_history match_action match_action_confirmed
          match_confirmed match_created player_profile player_matches rating_history dna search
          recent_players cities clubs preview username_check coach_application session signup
          new_user_session friends friendship_status upcoming_mine upcoming_home upcoming_open upcoming_match upcoming_result_ready upcoming_linked_result)
for name in "${expected[@]}"; do
  file="$OUT/$name.json"
  [ -s "$file" ] || { echo "export.sh: $name.json is missing or empty" >&2; exit 1; }
  jq -e . "$file" >/dev/null 2>&1 || [ "$(jq -c . "$file")" = "null" ] || { echo "export.sh: $name.json is not valid JSON" >&2; exit 1; }
  if [ "$name" = "coach_application" ]; then
    [ "$(jq -c . "$file")" = "null" ] || { echo "export.sh: coach_application.json must be null" >&2; exit 1; }
  else
    [ "$(jq -r 'type' "$file")" != "null" ] || { echo "export.sh: $name.json is null" >&2; exit 1; }
  fi
done

rm -f "$COPY"/*.json
cp "$OUT"/*.json "$COPY"/
echo "Wrote ${#expected[@]} fixtures to ios/PadelIDUITests/Fixtures and ios/PadelIDTests/Fixtures"
