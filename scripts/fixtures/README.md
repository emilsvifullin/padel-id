# Test fixtures

The JSON files in `ios/PadelIDUITests/Fixtures` (served by the UI-test stub
server) and `ios/PadelIDTests/Fixtures` (decoded by the unit tests) are real API
responses: they are produced by the database code in `supabase/migrations`, not
written by hand. They are test data only and never ship in the app target.

## Regenerate

Requires the local PostgreSQL 16 used for the database tests (socket
`/var/tmp/pgdev`, port `54329`, user `postgres`), `jq` and `python3`.

```sh
./scripts/fixtures/export.sh
```

The script

1. recreates the dedicated database `padelid_fixtures` with the shim and all
   migrations (`DB=… ./scripts/db/reset-local.sh`; override the name with
   `DB=…`, the test database `padelid` is refused);
2. runs `scenario.sql`, which builds the community only through the public API
   functions, acting as each user the same way `supabase/tests/00_setup.sql`
   does;
3. exports the RPC results the gateway passes through unchanged, each inside a
   transaction that is rolled back, pretty-prints them with `jq`, validates
   them and copies them to both fixture folders.

Ids are deterministic, so a regeneration only changes timestamps and the values
that depend on the current time (idle days, trends, expiry).

## Scenario

* 12 onboarded players in Москва and two clubs, «Падел Арена Лужники» and
  «Corner Padel Club». The main user is Михаил Орлов (`@m_orlov`,
  `m.orlov@padelid.app`) with a Padel DNA self-assessment from onboarding.
* 22 confirmed matches over about 70 days (ranked and friendly; best of three,
  two sets plus a super tie-break and single sets; 7:6 sets with tie-break
  points). Орлов plays 19 of them, most often with Дмитрий Соколов. Each match
  is entered with the real validation, confirmed by all four players (rating
  engine and Padel DNA run for real) and then moved into the past.
* Partners and opponents leave feedback on Орлов; Андрей Новиков is an approved
  coach (reviewed by the admin Артём Захаров) and has assessed Орлов.
* Open matches of Орлов: a ranked match entered by Волков that waits for his
  confirmation, a ranked match he entered that waits for two players, and a
  friendly match he disputed.
* A brand new account (`new.player@padelid.app`) without a profile.

## Files

| File | Source (acting as Орлов unless noted) |
|---|---|
| `me.json` | `public.me()` |
| `me_new.json` | `public.me()` of the new account |
| `home.json` | `public.home()` |
| `home_new.json` | `public.home()` of the new account right after onboarding (Илья Громов) |
| `matches_open.json` / `matches_history.json` | `public.my_matches('open' / 'history')` |
| `match_action.json` | `public.match_detail()` of the match waiting for Орлов |
| `match_action_confirmed.json` | `public.confirm_match()` on that match (completes it) |
| `match_confirmed.json` | `public.match_detail()` of the latest confirmed ranked match |
| `match_created.json` | `public.create_match()` of a new ranked match |
| `player_profile.json` / `player_matches.json` | `public.player_profile()` / `public.player_matches()` of Соколов |
| `rating_history.json` | `public.rating_history(me, null)` |
| `dna.json` | `public.player_dna(me)` |
| `search.json` | `public.search_players()` with the gateway defaults |
| `recent_players.json` | `public.recent_players(20)` |
| `cities.json` / `clubs.json` | `public.list_cities(null)` / `public.list_clubs(Москва, null)` |
| `preview.json` | `public.preview_match()` for Орлов + Соколов against Новиков + Морозов, 6:3 6:4 |
| `username_check.json` | `public.check_username('ilya_gromov')` |
| `coach_application.json` | `public.coach_application()` (`null`: Орлов has not applied) |
| `session.json`, `new_user_session.json`, `signup.json` | Auth responses (issued by Supabase Auth, not SQL): real user ids, deterministic fake tokens, `expires_at` in 2100 |
