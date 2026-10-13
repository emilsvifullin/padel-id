# Direct API hosting candidates

These files prepare a direct HTTPS entrypoint; nothing here has been deployed to
an external server. The owner currently has a domain but no VPS. Buying a server,
changing DNS, deploying production API/migrations or publishing a release needs
corresponding owner authorization. Shift Register must remain unchanged.

## Secret-free relay (verification)

`compose.relay.yaml` runs the existing fixed-origin relay in a private non-root
Node 22 container behind Caddy. It forwards only supported `/v1/*` requests to
`https://padel-id-gamma.vercel.app`. The destination is not user-configurable.
No gateway secret, database key or Vercel configuration change is required.
Authorization/idempotency headers pass only to that fixed API. Cookies, platform
IP/gateway headers, redirects, unbounded bodies and automatic replay are refused.
It serves the existing production revision, not the local 1.2.0 API.

After an approved host is available, preparation on that host would be:

```sh
# From server/deploy, on the approved Docker host:
API_DOMAIN=<dedicated-owned-api-hostname> docker compose -f compose.relay.yaml config --quiet
API_DOMAIN=<dedicated-owned-api-hostname> docker compose -f compose.relay.yaml build
# Only after authorization and correct DNS/firewall prerequisites:
API_DOMAIN=<dedicated-owned-api-hostname> docker compose -f compose.relay.yaml up -d
```

Use a dedicated hostname assigned only to Padel; do not change the other project's
root/www DNS or containers. Caddy needs reachable 80/443 for HTTPS issuance and
stores its certificates in dedicated named volumes. The Node API port is private;
the compose file publishes only Caddy ports. Configuration parsing does not prove
certificate issuance or physical reachability.

The relay's upstream address shares the existing Vercel anonymous IP budgets
across users. Resolving a trustworthy caller-IP/rate-limit boundary is required
before production traffic. Do not relax signup/password protection or forward
untrusted client XFF as a shortcut. This candidate is suitable for a bounded
network verification, not for declaring a new production ingress accepted.

## Independent full API

`compose.yaml` uses the same image with the full Hono API. It additionally requires
a protected environment file selected by `PADEL_GATEWAY_ENV_FILE`, containing
the existing server configuration and exact shared gateway-secret value;
`gateway.env.example` contains placeholders only.
Do not create or rotate that secret under permission to deploy a network probe.
All new RPC migrations must be deployed through the approved database release
procedure before enabling the 1.2.0 API. The full API direct Caddy boundary supplies
one verified caller address for its existing rate limits; placing another CDN or
proxy in front requires a separate review of that trust boundary.

## Local evidence, 11.10.2026

- Compose relay configuration passed with the dedicated hostname.
- Docker image `padel-id-relay:verification` built successfully using the frozen
  server dependencies and existing Dockerfile.
- A temporary local-only container used read-only filesystem, dropped capabilities
  and `no-new-privileges`; it reached healthy state.
- `127.0.0.1:8788/v1/health?deep=1`: 200, status/database ok, existing deployed revision
  preserved, `x-padelid-edge-mode: relay`, no-store and no Set-Cookie.
- Anonymous `/v1/me`: 401. The temporary container was then removed.
- Fixed-origin relay refusal/credentials/body/idempotency/privacy/deadline behavior
  is covered by seven Node tests and an actual Deno runtime adapter test.

Evidence in ignored `ios/build/verification/`: `relay-compose-check.log`,
`relay-docker-final-build.log`, `relay-container-final-{health,anonymous}.{headers,json}`,
`relay-deadline-deno-test.log`, `server-final-unit.log`.

## Acceptance after an authorized deployment

Check strict TLS/no redirects and exact deployed revision, shallow/deep health,
authenticated read/write, existing account/history, denied access, body/time
limits and rate limits. Verify the physical iPhone on Almatal Wi-Fi and Megafon
without VPN, including login/messages/avatar and switching networks. Then verify
with VPN as a regression. A working executor curl is not target-network acceptance.
Do not enable the iOS fallback URL until both infrastructure and physical results
are accepted; create/recheck the final archive after changing build configuration.
