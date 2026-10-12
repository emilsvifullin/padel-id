# APNs foundation — 1.2.0

Real APNs registration, durable delivery state and a Node HTTP/2 provider are implemented locally. **APNs is disabled by default. No Apple key, paid signing profile or worker deployment was supplied, and delivery to a physical iPhone has not been verified.** This document is a contract and local evidence, not production acceptance.

## iOS ↔ gateway

Portable gateway module: `server/src/push.ts` (`registerPushRoutes`). These authenticated routes work with the existing shared gateway; they contain no Node/provider imports or secrets.

```http
PUT /v1/me/push-devices/:installationUUID
Authorization: Bearer <current access token>
Content-Type: application/json

{"device_token":"opaque-apns-token-hex","enabled":true}
```

Actual tokens must be an even number of hexadecimal characters, 2–1024 characters; uppercase is normalized. Apple token lengths are variable, so there is no assumed fixed 32-byte token. Unknown fields, client `player_id`, `environment` and `topic` are rejected. The installation UUID is generated/persisted by the app; APNs tokens are obtained from the OS on launch/registration and are not cached as a permanent client identity.

SQL RPC: `register_push_device(p_installation uuid,p_token text,p_enabled boolean)`. Canonical response:

```json
{
  "installation_id":"…",
  "enabled":true,
  "environment":"production",
  "topic":"app.padelid.ios",
  "generation":1,
  "registered_at":"2026-10-11T…Z"
}
```

Topic and production/sandbox environment come only from owner-controlled `private.push_config`; there is no client metadata/JWT-claim authority for these fields. Disabled/unprovisioned configuration returns `service_unavailable` (503). Invalid payloads return `invalid_request` (400); an expired/revoked Auth session returns `session_expired` (401).

`DELETE /v1/me/push-devices/:installationUUID` calls `revoke_push_device(p_installation)` and returns `{"ok":true}`. It deletes only the installation belonging to the current UID **and current live session**; already absent/not owned is an idempotent success. An old account/session logout cannot erase a destination registered by a new session/account.

Installation uniqueness is `(environment, topic, player_id, installation_id)`. Knowing another user's installation UUID cannot overwrite their different token. Device tokens are opaque APNs destinations with global uniqueness per topic/environment; possession of the same actual APNs token allows a newly authenticated session to move its destination when the account changes. This is token possession, not hardware attestation; no App Attest guarantee is claimed. At most 20 registrations per UID/topic/environment limits queue amplification.

Repeating the same token/session/permission registration preserves its generation and pending jobs while updating `registered_at` to acknowledge fresh OS retrieval. Token/session/enabled changes increment the generation and cancel outstanding work for that device. Disabled registrations receive no new jobs. Auth session deletion cascades token/job deletion; account anonymization explicitly clears registrations. Re-registration does **not** replay old inbox items.

## Implemented iOS lifecycle and build gates

`RemotePushService` and `NotificationAppDelegate` request current OS tokens on
launch, keep tokens only in memory and persist a random installation UUID.
Registration is serialized, bound to the current user/token/permission and
server-confirmed before replacing local social-delivery fallback. Failures show
a pending state with an explicit retry; no ambiguous mutation replay is hidden.
Foreground synchronization also rechecks permission. Disabling push unregisters
with the OS immediately; logout revokes the scoped destination before clearing
authorization. Account changes and late token callbacks cannot restore an old
registration as current. Notification taps open a fresh authenticated inbox;
legacy local match notifications keep their existing authorized match route.

The default `PADELID_REMOTE_PUSH_ENABLED=NO` is preserved. The entitlement template
and `verify-push-config.py` require a matching production APS signing profile
before an enabled build; `verify-ipa.sh` additionally checks actual signed APS
entitlement/profile. An unsigned candidate with the flag NO is not an APNs-ready
physical build. Paid Apple provisioning/provider credentials are still absent.

Eight iOS push tests passed inside the 156-test Release iOS 27 run:
`unit-final-fixed-27.xcresult`; five Python build/provisioning tests passed:
`push-config-final.log`. These verify lifecycle and fail-closed configuration,
not actual registration/delivery with Apple.

## Common live-session protection

`private.push_session_live(session,player)` checks exact session ownership and nullable `auth.sessions.not_after`, using the current clock. Supabase may retain expired session rows until cleanup, so row existence alone is insufficient.

This new migration replaces `private.require_uid()` with the original UID/JWT session UUID validation plus that shared helper. Existing RPCs such as `me()` now reject an expired-but-still-present Auth row as well. Original already applied migrations are unchanged; raw helper execution remains revoked. The local Auth shim mirrors Supabase's nullable `not_after` column.

## Event sources and privacy

New `social_notifications` insertions enqueue one unique `(notification_id,device_id)` job per currently registered, enabled, live-session device. Existing true messages, comments, friend changes, scheduled game invitations/participation/cancellation/waitlist activity and sports-event invitation/registration/score actions use their existing canonical inbox sources.

Played-match actions now also generate canonical `kind: "match"` inbox notifications with `resource_id` equal to the real match ID: initial pending noncreator confirmations, an actual participant dispute for the creator, and reset confirmations after a new edited score version. Private `(match,version,recipient,action)` source keys prevent mutation retries/duplicate disputes from adding duplicate sources. Notification delivery is allowed only for the current match version and a recipient who still needs action. A client opens an authorized fresh match route from its fetched inbox item; push payloads do not contain match data.

At claim and immediately before sending, SQL rechecks device generation, current session expiry, active recipient/actor, bilateral blocks, message/activity preferences, unread state, expiration and current canonical resource visibility. Group membership removal, a deleted/hidden post, confirmed match, changed match version, cancelled registration or account deletion cannot authorize a queued stale destination. Unknown future notification kinds are denied until an explicit access rule is added.

There is an unavoidable interval between the last database check and the external APNs request; privacy changes cannot retract a request already sent. Therefore the lock-screen payload is always generic:

```json
{
  "aps":{
    "alert":{"title":"Padel ID","body":"Есть новые события. Откройте приложение."},
    "sound":"default"
  },
  "notification_id":"opaque-inbox-UUID"
}
```

No actor, message text, group title, location, event name, rating, resource ID or participant information appears in the alert. Tapping opens a freshly fetched, authenticated inbox; the app must not trust push fields as a source of private content/authorization. `apns-expiration: 0` avoids APNs storing an undeliverable alert for later offline delivery; the canonical inbox remains available when connectivity returns.

## Private worker ↔ database ↔ Apple

`server/src/push-provider.ts` and `push-worker.ts` are **Node-only** and excluded from `build-edge`. A separately scheduled Node 22 worker invokes:

- `claim_push_deliveries(secret,limit)` — dedicated secret authentication, `FOR UPDATE SKIP LOCKED`, random 120-second lease, at most eight attempts, 24-hour job expiration.
- `authorize_push_delivery(secret,job,lease)` — fences expired/old workers, rechecks privacy/session state and atomically renews a current lease for 120 seconds before returning the destination. Batches do not expose tokens until actual per-job authorization.
- `finish_push_delivery(secret,job,lease,outcome,reason,invalidated_at_ms)` — current lease/generation only; consistent device-before-delivery lock ordering for logout/register/worker races.

Allowed outcomes are `accepted`, `retry`, `dead_token`, `permanent` and `provider_error`. Transient retries wait at least 15 minutes (Apple's current 5xx guidance), increase exponentially to six hours, and stop at the attempt/expiration bound. A successful APNs response records **provider acceptance**, never a claim that an iPhone displayed it. Transport uncertainty/crashes can require another request; stable `apns-id`/`apns-collapse-id` and unique queue rows reduce duplicate alerts, but exactly-once delivery is not claimed.

Confirmed `BadDeviceToken`/`DeviceTokenNotForTopic` or timestamped 410 `Unregistered` responses disable only the current destination generation. A 410 timestamp older than a subsequently refreshed `registered_at` cannot disable it. Provider key/topic errors pause batch processing and retry later without invalidating unrelated devices. RPC responses/Apple errors are reduced to bounded machine reasons; `.p8`, JWTs, device tokens and upstream bodies are never logged. Normal worker output contains counts only.

The provider validates P-256 keys, signs ES256 with fixed key/team/topic IDs, reuses its JWT for 50 minutes and connects only to `api.push.apple.com` or `api.sandbox.push.apple.com` over HTTP/2/TLS. It enforces an absolute 10-second request deadline covering pending connections and continuously dripping responses. The portable gateway cannot invoke a public worker endpoint.

## Activation dependencies

Required owner-supplied setup, not performed here:

1. Apple Developer provisioning allowing Push Notifications for the actual installed bundle ID and correct production/sandbox entitlement. Current default bundle topic is `app.padelid.ios`; changed/resigned IDs require an authorized matching topic/profile.
2. A valid APNs `.p8` signing key, key ID and team ID stored only in the Node worker secret environment. No key is committed or bundled with the iOS app/gateway.
3. A random dedicated `PADELID_PUSH_WORKER_SECRET` (≥32 characters), stored as a SHA-256 hash in private SQL configuration. An owner sets `environment`, `topic`, hash and `enabled`; there is no public configuration endpoint. Environment/topic must exactly match the worker's signing configuration.
4. A deployed/scheduled Node 22 worker with outbound HTTPS/HTTP2 access to Apple and Supabase, monitored/retried by its operator. CLI after the normal server build: `node dist/push-worker.js`; running it once is not a scheduler.
5. Enable the already implemented iOS registration/permission/tap flow only in a correctly provisioned build, after the matching server setup. Local fallback remains until provider/device acceptance is verified.

Worker environment: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `PADELID_PUSH_WORKER_SECRET`, `PADELID_APNS_KEY_ID`, `PADELID_APNS_TEAM_ID`, `PADELID_APNS_TOPIC`, `PADELID_APNS_ENVIRONMENT` (`production` or `sandbox`), and raw multiline `PADELID_APNS_PRIVATE_KEY`. These are worker secrets/configuration, not client-controlled request parameters. Missing/invalid setup fails closed.

## Local verification, 2026-10-11

- The complete chain was tested first against an isolated Auth shim (`push-clean-migrations.log`), then against the actual local Supabase PG17/Auth schema after a backed-up disposable reset (`stack-clean-reset.log`). Hosted data was not reset.
- **74 SQL tests passed**, including ten push regressions: raw privilege/live-session checks, common `me()` expiry, scoped account/session logout and UUID attack, cap, real queue source, fences/backoff, block/mute/read/group removal/post deletion, fresh-token 410 protection, actual played-match version sources, disable and no history replay: `ios/build/verification/push-db.log`; repeated against actual local Supabase in `stack-db-current.log`.
- **Six independent-session races passed**: disjoint claims, expired-lease fencing, fresh registration versus old dead-token response, registration/revoke/finish lock ordering, unique token destinations, scoped UUID ownership: `ios/build/verification/push-concurrency.log`; actual local stack repeat in `stack-push-races.log`.
- **15 Node tests passed**, including a real local HTTP/2 server, independently verified ES256 signatures/JWT refresh, exact generic payload, absolute slow-drip/pending-stream/close deadlines, provider error classification, worker fencing/privacy behavior and authenticated gateway contracts: `ios/build/verification/push-server.log`.
- Node 22 typecheck passed: `ios/build/verification/push-typecheck.log`. The earlier isolated local shim security-advisor check reported no warning/error issues: `ios/build/verification/push-advisors.log`.

Actual local Edge/Auth E2E additionally passed 21 tests, including disabled push registration, anonymous denial and common live-session expiry (`stack-edge-full-auth-e2e.log`).

Local HTTP/2 tests use generated ephemeral test keys and a local server; they do not exercise Apple credentials or Apple delivery. No hosted APNs migration, provider key/configuration, push-worker deployment, commit or Git push was performed. The separately authorized gateway verification deployment is documented in its README.

## Official sources checked

- [Apple: Token-based APNs connections](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)
- [Apple: Sending APNs requests](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Apple: Handling APNs responses](https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns)
- [Supabase: User sessions](https://supabase.com/docs/guides/auth/sessions)
- [Supabase Auth: session model and NotAfter](https://github.com/supabase/auth/blob/master/internal/models/sessions.go)
- [Supabase: Database functions](https://supabase.com/docs/guides/database/functions)
