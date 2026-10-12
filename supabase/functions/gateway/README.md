# Padel ID gateway: full API and verification relay

The same portable `server/src` Hono API can execute in Supabase Edge Runtime.
There is also a fixed-origin relay for checking a new network entrypoint against
an existing API without copying or rotating its write-only gateway secret.
Neither mode adds database/provider credentials to iOS.

## Modes and current hosted state

The entrypoint chooses these modes in order:

1. `PADELID_EDGE_NETWORK_PROBE_ONLY=true`: transport probe only. Shallow health
   returns `configuration_required` / `network_verification`; deep health and
   user routes return 503. It makes no Auth, Storage or database call.
2. `PADELID_EDGE_RELAY_EXISTING_API=true`: relay to the fixed
   `https://padel-id-gamma.vercel.app` API. Only `/v1/*` and the supported API
   methods/headers pass. Request/response bodies are bounded; deadline covers
   the full response; redirects and automatic mutation retries are refused.
   The upstream revision is preserved. Cookies, spoofed platform IP and
   gateway-secret headers are stripped. No gateway secret is needed here.
3. Otherwise: independent full Hono API using its server configuration and the
   same Auth/Storage/PostgREST/account service and protected RPC contracts.

On 11.10.2026, authorized verification deployment `gateway` is ACTIVE version 4
in project `xnxhlfuncxyzdfdmqlkb`, with probe false / relay true. Its public base is
`https://xnxhlfuncxyzdfdmqlkb.supabase.co/functions/v1/gateway`.
The existing account function was observed ACTIVE version 4; it was not deployed
by this work. No hosted migration, Vercel setting/deployment or secret rotation
was performed. The initial version 1 probe is historical, not the current mode.

Strict HTTPS shallow/deep health returned 200, `status: ok`, existing production
revision `b93723db3c71e9a3f28187c38ffd5d84c4f63a74`; anonymous `/v1/me` returned 401.
Evidence: `ios/build/verification/edge-relay-final-live.json` and
`edge-relay-final-deployed-source.json`. The owner confirmed off-VPN Wi-Fi access, but
**Megafon still cannot connect**, including the alternate official hostname.
Production iOS fallback remains empty; this is not accepted production networking.

The existing Vercel key is protected/write-only. A deliberately invalid recovery
request for a nonexistent address passed the account function's gateway-secret
check and reached `invalid_recovery` (403). This safely verifies agreement of the
active Vercel/account/database configuration, without exposing or replacing the
secret or changing an account. Evidence: `production-key-consistency.json`.
A shallow/deep health pair alone is insufficient on the old fail-open limiter.
Do not rotate the existing key; the owner requires separate agreement for any
proven necessary replacement. Relay verification removes the need to recover it.

## Build and local checks

`_shared` is generated/ignored. Rebuild it after portable API changes; do not edit
it directly. Dependency versions derive from `server/package.json`, and
`deno.lock` records integrity. Node-only server/provider/worker entrypoints are
excluded from generation.

From repository root with existing dependencies installed:

```sh
node server/scripts/build-edge.mjs
deno check --frozen --config supabase/functions/gateway/deno.json supabase/functions/gateway/index.ts
deno test --frozen --config supabase/functions/gateway/deno.json supabase/functions/gateway/adapter_test.ts
```

Latest Node unit: 101 passed; Deno check plus six actual runtime tests passed.
The actual local Supabase Edge Runtime also passed 21 full Auth E2E after the
complete 19-migration chain, including privacy, event four confirmations,
unchanged rating and expired-but-existing Auth session denial. Hosted relay
only executes the existing production API, not these new local 1.2.0 RPCs.

The adapter accepts `/functions/v1/gateway/v1/...` and `/gateway/v1/...` prefixes.
`verify_jwt=false` allows public health/signup/login/refresh; authenticated user
routes retain bearer, live database session and domain authorization checks.
It never authorizes a protected RPC merely because the platform JWT gate is off.

## Independent full API configuration

Hosted migrations/full API publication need corresponding owner permission;
the gateway verification permission does not authorize them. Generate immediately
before an approved deployment. All five 1.2.0 RPC migrations and the protected
account function must be available before enabling the new routes for users.

Supabase injects `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEYS` (or legacy
`SUPABASE_ANON_KEY`). A privileged/service-role key is never selected as the API
key. Reserved `SUPABASE_` secret names must not be overridden. If needed, use
`PADELID_SUPABASE_PUBLISHABLE_KEY` explicitly.

A protected/untracked configuration file for full API mode would contain:

```dotenv
PADELID_GATEWAY_SECRET=<the existing value whose SHA-256 is registered in the database>
PADELID_MIN_CLIENT_BUILD=1
PADELID_UPSTREAM_TIMEOUT_MS=12000
PADELID_SIGNUPS_PER_HOUR=5
PADELID_RELEASE_COMMIT=<actual deployed revision>
PADELID_EDGE_NETWORK_PROBE_ONLY=false
PADELID_EDGE_RELAY_EXISTING_API=false
# Optional: PADELID_SUPABASE_PUBLISHABLE_KEY=<publishable key>
```

After the corresponding approval, commands are `supabase secrets set --env-file
<protected-file> --project-ref <ref>` and `supabase functions deploy gateway
--project-ref <ref>`. Do not substitute a new secret, update its database hash or
rotate account/Vercel configuration under permission for transport verification.

## Client IP trust and rate limits

Full API mode strips client platform IP/gateway headers. Without a verified
exclusive ingress, its rate limits use the shared `unknown` IP bucket.
`PADELID_EDGE_TRUST_CF_CONNECTING_IP=true` is permitted only after evidence that
that ingress overwrites spoofed values. Merely receiving a header proves nothing;
missing/malformed values remain `unknown`. Never trust client-controlled XFF.

Relay mode strips client IP headers and the existing Vercel API sees the relay's
upstream address. Anonymous signup/password IP budgets therefore aggregate across
users. **Resolving authoritative caller IP is a production prerequisite for either
new ingress; limits are not relaxed to make verification look successful.**

Full API mode and relay mode both need actual target-network acceptance. Local
curl/Deno/Docker success does not prove availability on a Russian iPhone.

References: [routing](https://supabase.com/docs/guides/functions/routing),
[dependencies](https://supabase.com/docs/guides/functions/dependencies),
[auth headers](https://supabase.com/docs/guides/functions/auth-headers),
[secrets](https://supabase.com/docs/guides/functions/secrets).
