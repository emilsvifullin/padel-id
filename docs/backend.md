# Padel ID backend

Production backend for the Padel ID iOS app. Russian users reach only the
public API on Vercel; nothing in the app talks to `*.supabase.co`.

```
iPhone (Padel ID) ──HTTPS──▶ Vercel: padel-id-gamma.vercel.app (Hono, region dub1)
                                 │  publishable key + gateway secret
                                 ├──▶ Supabase Auth (password / refresh grants, logout, password change)
                                 ├──▶ PostgREST RPC: public.* API functions (user JWT)
                                 ├──▶ Storage: avatars bucket (upload with user JWT, read-through proxy)
                                 └──▶ Edge Function `account` (gateway secret ▶ service role inside Supabase)
```

## Components

| Component | Where | Notes |
| --- | --- | --- |
| Database | Supabase project `xnxhlfuncxyzdfdmqlkb`, Postgres 17 | Schema and API in `supabase/migrations` |
| Account service | Supabase Edge Function `account` (`supabase/functions/account`) | Sign-up, recovery, email change, account deletion; the only place the service role is used |
| Public API | Vercel project `padel-id`, root `server/`, Node 22, region `dub1` | `server/src/api.ts`; contract in `docs/ios-architecture.md` |
| Scheduled job | `pg_cron` job `padelid-expire-matches` (hourly) | Expires unconfirmed matches |

## Data and API design

- All tables live in `public` (domain data) or `private` (admins, recovery keys,
  rate limits, gateway secret hash). RLS is enabled on every table with a
  restrictive deny-all policy and table privileges are revoked from `anon` and
  `authenticated`: clients cannot read or write tables directly.
- The API is a set of `SECURITY DEFINER` functions in `public` with an empty
  `search_path`, granted to `authenticated` only. Each function resolves the
  caller with `private.require_uid()`, which also checks that the token's
  `session_id` still exists in `auth.sessions`, so sign-out everywhere,
  password reset and account deletion revoke access immediately.
- `svc_*` functions are granted to `service_role` only and are called by the
  account service. `bff_rate_limit` is callable by `anon` but requires the
  gateway secret.
- Matches: four distinct participants (deferred constraint trigger), optimistic
  concurrency through `version`, idempotent creation via `Idempotency-Key`,
  advisory locks against duplicate submissions, per-player daily ranked limit,
  duplicate detection (same four players within 45 minutes), 14-day window for
  ranked results, automatic expiry of unconfirmed matches.
- Rating (PIR-1, `*_rating_engine.sql`): team strength from both partners,
  exact set/match win probabilities by dynamic programming over game win
  probability, Gauss–Hermite expectation over rating uncertainty, Kalman-style
  update per player, score-margin modulation that never flips the sign,
  per-change cap, inactivity uncertainty growth and anti-farming weights for
  repeated line-ups. Every change stores a full explanation in `rating_events.details`.
- Padel DNA (`*_padel_dna.sql`): precision-weighted Bayesian offsets per
  dimension from self-assessment, partner/opponent feedback (time-decayed),
  verified coach assessments (valid 180 days) and close-set results, with
  per-dimension confidence.
- Account recovery uses one-time recovery keys (SHA-256 stored, rotated on use)
  because no email delivery is configured.
- Accounts are created only by the account service. Public GoTrue sign-up is
  off (`[auth] enable_signup = false`; the email provider itself stays on for
  sign-in), and a deferred constraint trigger on `auth.users` rejects, at
  commit, any new user without `app_metadata.padelid_origin = 'account-service'`
  (set by the account service's `createUser`; GoTrue merges app_metadata after
  the insert, hence the commit-time check). Users created any other way,
  including from the Supabase dashboard, are rejected.
- Password checks (`verify_my_password`, `regenerate_recovery_key`,
  `svc_check_password`) share a per-user budget of 10 attempts per 15 minutes;
  a wrong password is returned rather than raised so the attempt stays counted.
  The gateway also limits password-protected account actions to 20 per client
  IP per 15 minutes, and sign-in to 30 per IP, 10 per email and IP (10 minutes)
  and 100 per email (hour); email buckets are keyed by a SHA-256 of the address.
- Hidden profiles are available to owner/admin, shared scored-match peers, accepted friends, accepted scheduled-game peers, and the recipient of the hidden player’s pending friend request. Voluntary requests expose their requester, not a hidden recipient. Search/profile/DNA/rating/matches/compatibility/coach assessment enforce the same predicate. Unrelated viewers of public game cards receive masked hidden cards; organizers inspect their own applicants. Email and personal settings stay owner-only.
- Mutual friendship uses a canonical UUID pair and a transaction advisory lock. Only the pair’s members may request/accept/reject/cancel/remove; only the recipient accepts. No asymmetric copies. Account anonymization closes relationships and releases future seats.
- Social mutations hold active-profile locks in UUID order before relationship/game locks. Account deletion cannot complete cleanup and then be followed by a previously waiting join or unconfirmed linked result; confirmed history remains intact.
- Future games have separate tables and RPCs, one row per applicant/participant, a four-seat constraint and a row lock for every capacity-changing action. Organizer handles applications; reliable in-range users auto-admit. The existing rating engine provides level/reliability (including inactivity); new admission threshold is70% and5 ranked matches, without a guarantee after any count. Reliable out-of-range users are refused; provisional/insufficiently reliable users may apply.
- Any admitted participant may publish a scored result after starts_at with the exact four IDs/type/club. The existing scored result, validation, disputes, optimistic versions, idempotency and four confirmations remain authoritative. Deferred constraints and the shared legacy validator prevent subsequent admitted-lineup substitution. Replays of the same linked result do not expire with normal create windows; conflicting input is rejected.
- Scored details add nullable `scheduled_match_id` and `scheduled_starts_at` for the new editor; released clients ignore them. Expired/cancelled/disputed scores expose `result_status` without claiming the planned game itself was cancelled. The existing serializer and its access checks are retained.
- `player_stats` now computes streak over all confirmed history; ten-result form is separate and additive `last_ten` exposes actual totals.

## Secrets

| Secret | Stored in | Never in |
| --- | --- | --- |
| Service role key | Supabase Edge Function environment (managed by Supabase) | Vercel, repository, app |
| Gateway secret (`PADELID_GATEWAY_SECRET`, ≥ 32 chars) | Vercel env (sensitive); only its SHA-256 in `private.bff_secret` | repository, app, logs |
| Publishable key (`SUPABASE_PUBLISHABLE_KEY`) | Vercel env | app |

The gateway logs one JSON line per request (method, route, status, duration,
request id) and never logs bodies, tokens or passwords.

### Rotating the gateway secret

1. Generate a new value: `openssl rand -base64 48`.
2. In SQL (Supabase SQL editor or MCP), as the project owner:
   `update private.bff_secret set secret_hash = extensions.digest('<new>', 'sha256'), rotated_at = now();`
3. Set `PADELID_GATEWAY_SECRET` to the new value in Vercel (Production and
   Preview, type Sensitive) and redeploy production.
4. The account service caches validation for five minutes; old instances stop
   accepting the old secret within that window.

## Configuration (Vercel environment)

| Variable | Default | Purpose |
| --- | --- | --- |
| `SUPABASE_URL` | — | Project URL |
| `SUPABASE_PUBLISHABLE_KEY` | — | Publishable key |
| `PADELID_GATEWAY_SECRET` | — | Gateway secret |
| `PADELID_MIN_CLIENT_BUILD` | `1` | Oldest supported iOS build; older builds receive `426 update_required` |
| `PADELID_UPSTREAM_TIMEOUT_MS` | `12000` | Upstream timeout |
| `PADELID_SIGNUPS_PER_HOUR` | `5` | Sign-ups per client IP per hour |

## Deploying

- **Migrations:** add a new timestamped file to `supabase/migrations` (never edit
  applied ones), run the DB suite, then apply with `supabase db push` or the
  Supabase MCP `apply_migration`. Check `get_advisors` afterwards.
- **Account service:** `supabase functions deploy account --no-verify-jwt`
  (it authenticates the gateway itself).
- **Public API:** Vercel deploys `server/` from Git; production follows `main`.
  `GET /v1/health` returns the deployed commit; `?deep=1` also checks the database.

## Tests

| Suite | Command | CI |
| --- | --- | --- |
| Database (schema, engine, API, RLS, security) | `scripts/db/run-tests.sh` (local PostgreSQL) or the Supabase CLI stack | `backend.yml` |
| Gateway unit tests | `cd server && pnpm test` | `backend.yml` |
| End-to-end API on a local Supabase stack | `cd server && pnpm test:e2e` | `backend.yml` |
| Production smoke (read-only checks plus a throwaway account lifecycle) | `E2E_MODE=smoke pnpm test:e2e` | `production-smoke.yml`, daily and on every backend change |
