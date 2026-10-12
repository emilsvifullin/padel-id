# Avatar privacy — local 1.2.0 implementation

Review found that protected `/v1/avatars/:owner/:file` alone did not close the
remembered Supabase public URL. Initial migration still made `avatars` public
and the server itself fetched `/storage/v1/object/public/avatars/...`.

CLI-created `20261011162125_private_avatar_storage.sql` makes the bucket private.
Storage's narrow `private.avatar_access` policy helper checks the same live Auth
session (including `not_after`), active player and bilateral visibility rules as
the API. The owner can manage their own valid JPEG paths; other viewers can read
only the profile's current avatar, never a leftover old object. Insert/update/
delete also require a live owner session. The server supplies the original user
bearer and publishable API key to the authenticated Storage endpoint; it never
uses a service-role credential to bypass visibility.

SELECT is limited to authenticated image/info requests and necessary owner
write operations. Writes allow only immediate upload/update/delete operations.
Signed download/upload URLs, copying/moving and bulk enumeration are denied:
signed links would retain access after a later block or session revocation.
The helper has explicit EXECUTE only for authenticated users and empty
`search_path`; it is in a non-exposed schema and introduces no schema USAGE grant.

Verified locally against actual Supabase Auth/PostgREST/Storage and Node gateway:

- Typecheck/build and 60 targeted API unit cases passed.
- `server/test/e2e/avatar-privacy.e2e.test.ts` passed: anonymous public/private
  URLs denied, live owner and visible viewer allowed, hide/block denied through
  both gateway and Storage, stale existing object denied to another user,
  expired Auth sessions denied reads and owner uploads, owner overwrite allowed
  and foreign overwrite/upload denied, signed download/upload denied for owner
  and viewer, fixture cleanup succeeded. Storage's update probe uses an upsert;
  INSERT permits that authenticated update operation while denying signed upload.
- Local security advisors returned no issues.

Proof logs are ignored under `ios/build/verification/avatar-private-*`. This is
local evidence; hosted Storage and production were not changed. The final clean
migration/CI run is recorded separately by the release acceptance journal.

## Production ordering and limits

The new client uses bearer-authenticated API avatar URLs. Read-only `git show
HEAD` of the previous client confirms that it also used `/v1/avatars/...`, but
its dedicated image URLSession sent no bearer and used persistent
`returnCacheDataElseLoad`; the previous gateway fetched public Storage internally.
The new protected API breaks that older anonymous image request contract, and
bucket privacy closes remembered raw public Storage URLs separately. The
protected API and update artifact must be available before that approved change.
Check the actual installed older binary, communicate the required update and
use the agreed maintenance/version gate; do not reopen the bucket for old clients.

Changing bucket privacy closes future public origin reads; it cannot recall
images already downloaded, browser/client copies or previously cached public
CDN responses. Audit the previous avatar cache policy and actual hosted cache
invalidation behavior before claiming immediate revocation. Previously issued
Storage signed URLs are a separate concern: Supabase says they remain valid
until expiry and Auth-key rotation does not revoke them. Audit whether any were
issued; if so, arrange the provider's supported revocation process. No signing
path is introduced by this release.

Official sources checked 11 October 2026:
[private downloads](https://supabase.com/docs/guides/storage/serving/downloads),
[access control](https://supabase.com/docs/guides/storage/security/access-control),
[operation helpers](https://supabase.com/docs/guides/storage/schema/helper-functions),
[operation names](https://github.com/supabase/storage/blob/master/src/http/routes/operations.ts).
