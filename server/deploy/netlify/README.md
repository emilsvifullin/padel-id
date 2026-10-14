# Isolated free HTTPS network probe

Published with the owner's explicit permission on 12 October 2026:
https://padel-id-network-probe.netlify.app/v1/health?deep=1

The new `padel-id-network-probe` project is in the verified Free team
`emilsvifullin` (`padel-id-diagnostics`), project ID
`2df11cca-1f71-4826-9a84-5c5977cd086f`, deploy
`6acbf908b35357bcd95b784d`. Only this diagnostic project's production URL was
made public; previews remain private. No Git integration, environment secret,
custom domain or production Padel ID change was made.

Six unauthenticated hosted checks passed with system TLS trust verification:
shallow/deep health 200; POST health, `/v1/me`, the default function URL and
arbitrary query 404; no redirects or cookies. Deep health reports the existing
API revision `b93723db3c71e9a3f28187c38ffd5d84c4f63a74` and `database: ok`.
Evidence: `ios/build/verification/netlify-probe-hosted-verification.json`.
The owner checked the actual iPhone on 12 October: Almatal Wi-Fi works without
VPN, MegaFon mobile data does not load the address without VPN. This experiment
therefore does not solve the mobile connectivity requirement and is not an
accepted production API route. The exact network failure mechanism is unproven.

The owner declined paid hosting on 11 October 2026. This package prepares an
alternative **read-only network experiment** on Netlify Free. It is not a
production API or an accepted mobile fallback.

Netlify's current Free plan is $0/month with 300 monthly credits, a hard limit
and no automatic recharge. Verify the account is actually on Free before any
approved deployment; do not select Personal/Pro, paid add-ons or domain orders.
There is no claim that its hostname works through MegaFon until tested on the
actual iPhone. Cloudflare is not an assumed working alternative; the provider
has documented Russian ISP throttling. Render Free sleeps after inactivity and
its documentation explicitly excludes production use.

## Prepared behavior

- Only `GET /v1/health` and `GET /v1/health?deep=1` are accepted. No login,
  account/profile/avatar/message reads or writes are exposed.
- The existing bounded relay implementation calls only the fixed current
  Vercel origin, with a 15-second total deadline and no redirects/retries.
- Caller authorization/cookies/IP headers never leave this probe. No database,
  Vercel or Apple secret is needed or copied. No DNS changes are needed to test
  the assigned `netlify.app` URL. Shift Register is unchanged.
- Successful output remains `status: configuration_required`,
  `mode: network_verification`, `upstream_status: ok`; deep health also returns
  `database: ok` from the existing API. The app cannot select this as a working
  API route. Production fallback remains empty.

## Build and local verification

From `server`, use the existing frozen package lockfile, run `pnpm run build`,
then `node --test deploy/netlify/probe.test.mjs`. The function imports the compiled
relay, so production build must precede bundling. No new dependency was added.
Set project base to `server`, build command to `pnpm run build`, publish directory
to `deploy/netlify/public`, functions to `deploy/netlify/functions`, Node22 and
pnpm10.28.0; `netlify.toml` contains the reviewed isolated configuration. Do not
point Netlify at an existing project or enable auto-deploy/commit/push here.
A deployment must be separately authorized under AGENTS.md.

The actual manual deployment used CLI 27.12.0 and an isolated staging root,
`/tmp/padel-netlify-isolated-probe`. The nested config here is not auto-detected
from the repository root, and this CLI has no `deploy --config` option. Copy
only `network-probe.mjs`, `public/index.html`, `dist/edge-relay.js` and
`dist/gateway-url.js` into the staging directory preserving their relative
paths under `server`; put this configuration at the staging root:

```toml
[build]
publish = "server/deploy/netlify/public"
[functions]
directory = "server/deploy/netlify/functions"
node_bundler = "esbuild"
```

Use an isolated package with `type: module`. An offline Netlify build verified
the custom health route and bundled only the probe and its two pure helpers.
For this existing diagnostic project, the approved manual publication used
`deploy --prod --no-build --site padel-id-network-probe` with absolute `--dir`
and `--functions` paths and `--skip-functions-cache --json`. Do not create
another project when a transient lookup fails, or use anonymous deployment.
The original new project was created with `sites:create --disable-linking`.
New Free projects can start private; intentionally make only this reviewed
probe public after its successful deployment.

After an approved deployment, verify strict TLS, `GET`200, rejected mutation404,
no redirects/cookies, fixed existing revision and response headers. Then open
the new deep-health URL on iPhone with Wi-Fi and VPN disabled through MegaFon,
and with VPN disabled through Almatal Wi-Fi. Stop at a failed physical check;
do not modify production routing based only on a desktop success.

A successful experiment would still require a separately reviewed full API
adapter, trusted caller-IP/rate-limit boundary, credit-capacity assessment and
release/deployment permissions. This probe cannot launch release1.2.0 by itself.

Official sources checked 11 October 2026:
[JavaScript Functions API](https://docs.netlify.com/build/functions/get-started/),
[Project visibility](https://docs.netlify.com/manage/security/secure-access-to-sites/project-visibility/),
[Free credit plan](https://docs.netlify.com/manage/accounts-and-billing/billing/billing-for-credit-based-plans/credit-based-pricing-plans/),
[Render Free limitations](https://render.com/docs/free),
[Cloudflare's Russian ISP report](https://blog.cloudflare.com/russian-internet-users-are-unable-to-access-the-open-internet/).
