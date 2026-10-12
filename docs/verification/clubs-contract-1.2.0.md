# Clubs and courts — 1.2.0 contract

The catalog extends existing club IDs without replacing or renaming community-created records. No photos, addresses, coordinates, court availability, payments or reservations are fabricated. Unknown metadata remains empty/null and existing city/name/player counts remain usable by 1.1 clients.

## Reads and real activities

All routes require a live authenticated session. `GET /v1/clubs?city_id=…&query=…` retains its array response and max 100 results; search covers real club names and supplied addresses. Results use deterministic player-count/name/ID order. Existing `POST /v1/clubs` behavior is unchanged.

`GET /v1/clubs/:id` returns the canonical club detail:

```typescript
type ClubDetail = {
  id: number; name: string; city_id: number; city_name: string;
  players_count: number;
  description: string; address: string | null;
  latitude: number | null; longitude: number | null;
  photo_urls: string[]; amenities: string[];
  contact_phone: string | null; website_url: string | null;
  booking_url: string | null; booking_verified_at: string | null;
  metadata_version: number; updated_at: string;
  courts_count: number; courts: Court[];
  viewer: { can_edit: boolean };
};
type Court = {
  id: string; club_id: number; name: string; indoor: boolean;
  surface: string; description: string; is_active: boolean;
  version: number; updated_at: string;
};
```

List rows contain the same metadata without `viewer`, with `courts: []`. `courts_count` counts active courts. Detail shows active courts to ordinary viewers and also archived courts to administrators, for reactivation. Dates are actual PostgreSQL timestamps. Coordinates are a nullable pair; zero is a valid real coordinate and absence must not produce a map pin.

`GET /v1/upcoming-matches?club_id=:id&city_id=…&scope=open&limit=…&offset=…` filters scheduled games by club **before pagination**, while preserving private-game consent, bilateral block checks, canonical ordering, admission and existing fields. `mine` and `accepted_only` retain their existing meanings.

`GET /v1/events?club_id=:id&kind=training|tournament&scope=upcoming|mine&limit=…&offset=…` filters real canonical events before pagination and preserves event visibility/participation rules. Convenience `GET /v1/clubs/:id/events` accepts those event query parameters except `club_id`/`city_id`, injecting only the path club ID. Responses remain `{ items: Event[], next_offset: number | null }`. Club filtering does not synthesize activities from another city/page.

## Curated metadata

`PATCH /v1/admin/clubs/:id` accepts a strict partial body with required `version` (current `metadata_version`, integer ≥1) and `reason` (5–400 characters). Editable fields are `description` (0–2000), nullable `address` (2–300), paired nullable `latitude` (−90…90)/`longitude` (−180…180), `photo_urls` (≤12), `amenities` (≤24 strings of 2–60), nullable `contact_phone` (5–32 phone characters), nullable `website_url`, nullable `booking_url`, and optional `booking_verified`.

Omitting a field preserves its current value; explicit null clears nullable fields. Photos are supplied public HTTPS URLs, never fetched by a privileged server. Website/booking/photos reject credentials, numeric IP hosts, local/reserved host suffixes, non-HTTPS schemes, malformed labels, control characters, whitespace and backslashes. SQL repeats validation independently of gateway Zod schemas.

Setting a nonnull `booking_url` requires `booking_verified: true`, asserting that an administrator checked an official operator/club booking destination. The server records the verification timestamp and audit reason. Removing it clears the timestamp. Passing `booking_verified` without `booking_url` is invalid. The URL opens the official external booking flow; Padel ID does not claim that a reservation/payment has occurred.

The database checks the current `private.admins` table, not user-editable/JWT metadata. Club creators are not automatically administrators. Every successful update is row-locked, increments the version and writes a private audit record with before/after values and reason. Stale versions return `version_conflict` (409), protecting new values against lost updates; clients reload/review before trying again. Returns canonical `ClubDetail` only after mutation succeeds. Immutable club name/city and IDs remain unchanged by this metadata endpoint.

## Courts

`PUT /v1/admin/clubs/:id/courts/:courtUUID` requires the same current administrator authorization. Full body:

```json
{
  "version": 0,
  "name": "Корт 1",
  "indoor": true,
  "surface": "Искусственная трава",
  "description": "Описание, подтверждённое оператором клуба",
  "is_active": true,
  "reason": "Проверено с оператором клуба"
}
```

The client creates and preserves the UUID for a new court and uses `version: 0`. Name is 2–80 characters, surface 0–80, description 0–600, reason 5–400; both booleans are required. Existing records require their actual current `version`. Same-UUID identical create retries return the unchanged version-1 canonical record without another court or audit; different payloads or any subsequent edit conflict. Club-level row locks serialize absent-row creation and court-name uniqueness. Court IDs cannot be moved between clubs. Archiving (`is_active: false`) preserves identity/history; administrators can inspect and reactivate archived courts. Returns the actual canonical court, never an optimistic placeholder.

## Security and booking dependencies

New `public.club_courts` and `private.club_metadata_audit` have RLS enabled and no direct privileges for public/anon/authenticated/service_role. Public RPC execution is restricted to authenticated; private helper execution is revoked. Live-session and administrator checks are repeated in SQL. Old club-table security remains intact.

No official provider integration credentials, club authorization or provider court identifiers were supplied. Full native availability/reservation/payment therefore still requires a club/operator agreement, selected provider's official API access and court mappings, authenticated reservation/cancellation contracts, provider-confirmed webhooks, and a payment/accounting arrangement where applicable. Prepared stable club/court IDs, curated metadata, external verified booking destination and audit/version control are the foundation; there are no fabricated time slots, charges or confirmations.

## Local verification, 2026-10-11

- Clean shim + **all migration files** applied to isolated local `padel_clubs_1_2` on PostgreSQL 18: `ios/build/verification/clubs-clean-migrations.log`.
- **64 SQL tests passed**, including five club regressions for live roles/admin revocation, validated/clearable metadata, preserved names/IDs, official booking assertion, optimistic versions/audits, court retry/archive, actual event filtering, private scheduled-game filtering before pagination: `ios/build/verification/clubs-db.log`.
- **3 independent-session races passed**: conflicting club writes, duplicate court creation, conflicting court edits: `ios/build/verification/clubs-concurrency.log`. Runner refuses nonlocal hosts or database names outside `padel_clubs_…`.
- Node 22 TypeScript check passed: `ios/build/verification/clubs-typecheck.log`. **5 club gateway contract tests passed**, covering bearer forwarding, strict URL/body/path/query validation, explicit null clearing, real upstream permission/version errors and club filters; the combined app/Edge/club run passed **79 tests**: `ios/build/verification/clubs-server-all.log`.
- Supabase CLI local security advisors at warning level returned **no issues**: `ios/build/verification/clubs-advisors.log`; this is local shim evidence, not hosted Auth/production acceptance.

Nothing in this work applied hosted migrations, deployed, committed or pushed. Production still needs its separately authorized migration/gateway rollout and the iOS/real-device acceptance checks recorded in the release matrix.
