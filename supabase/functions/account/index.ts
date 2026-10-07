// Padel ID privileged account service.
//
// Runs inside Supabase, where the service-role key is provided by the platform
// and never leaves it. Only the Padel ID API gateway (Vercel) may call this
// function: every request must carry the gateway secret, which is verified
// against its SHA-256 stored in the database.
//
// Actions: signup, recover, change_email, delete_account.

import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.116.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

type Json = Record<string, unknown>;

class ServiceError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

function respond(status: number, body: Json): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function normalizeEmail(value: unknown): string {
  if (typeof value !== "string") throw new ServiceError(400, "invalid_email");
  const email = value.trim().toLowerCase();
  if (email.length > 254 || !EMAIL_RE.test(email)) throw new ServiceError(400, "invalid_email");
  return email;
}

export function validatePassword(value: unknown): string {
  if (typeof value !== "string") throw new ServiceError(400, "weak_password");
  const bytes = new TextEncoder().encode(value).length;
  if (value.length < 8 || bytes > 72 || !/\p{L}/u.test(value) || !/\d/.test(value) || /^(.)\1+$/.test(value)) {
    throw new ServiceError(400, "weak_password");
  }
  return value;
}

function requireString(value: unknown, code: string, max = 512): string {
  if (typeof value !== "string" || value.length === 0 || value.length > max) throw new ServiceError(400, code);
  return value;
}

// Gateway secret verification with a short in-memory cache.
const verifiedSecrets = new Map<string, number>();
async function verifyGateway(req: Request): Promise<void> {
  const secret = req.headers.get("x-padelid-gateway") ?? "";
  if (secret.length < 32) throw new ServiceError(401, "unauthorized");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  const key = Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
  const cached = verifiedSecrets.get(key);
  if (cached && cached > Date.now()) return;
  const { data, error } = await admin.rpc("svc_bff_secret_valid", { p_secret: secret });
  if (error) throw new ServiceError(503, "service_unavailable");
  if (data !== true) throw new ServiceError(401, "unauthorized");
  verifiedSecrets.set(key, Date.now() + 5 * 60_000);
}

async function userFromToken(token: unknown): Promise<string> {
  const jwt = requireString(token, "not_authenticated", 4096);
  const { data, error } = await admin.auth.getUser(jwt);
  if (error || !data.user) throw new ServiceError(401, "not_authenticated");
  return data.user.id;
}

async function requirePassword(userId: string, password: unknown): Promise<void> {
  const value = requireString(password, "invalid_password", 200);
  const { data, error } = await admin.rpc("svc_check_password", { p_user: userId, p_password: value });
  if (error) throw new ServiceError(503, "service_unavailable");
  if (data !== true) throw new ServiceError(403, "invalid_password");
}

async function issueRecoveryKey(userId: string): Promise<string> {
  const { data, error } = await admin.rpc("svc_issue_recovery_key", { p_user: userId });
  if (error || typeof data !== "string") throw new ServiceError(503, "service_unavailable");
  return data;
}

function isEmailTaken(error: { message?: string; code?: string; status?: number } | null): boolean {
  if (!error) return false;
  return error.code === "email_exists" || error.status === 422 && /already|exists|registered/i.test(error.message ?? "");
}

async function signup(body: Json): Promise<Json> {
  const email = normalizeEmail(body.email);
  const password = validatePassword(body.password);
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (isEmailTaken(error)) throw new ServiceError(409, "email_taken");
  if (error || !data.user) throw new ServiceError(503, "service_unavailable");
  const recoveryKey = await issueRecoveryKey(data.user.id);
  return { user_id: data.user.id, recovery_key: recoveryKey };
}

async function recover(body: Json): Promise<Json> {
  const email = normalizeEmail(body.email);
  const key = requireString(body.recovery_key, "invalid_recovery", 64);
  const password = validatePassword(body.new_password);
  const { data: userId, error } = await admin.rpc("svc_check_recovery_key", { p_email: email, p_key: key });
  if (error) throw new ServiceError(503, "service_unavailable");
  if (typeof userId !== "string") throw new ServiceError(403, "invalid_recovery");
  const update = await admin.auth.admin.updateUserById(userId, { password });
  if (update.error) throw new ServiceError(503, "service_unavailable");
  const revoke = await admin.rpc("svc_revoke_sessions", { p_user: userId });
  if (revoke.error) throw new ServiceError(503, "service_unavailable");
  // A recovery key is single-use: issue a new one.
  return { recovery_key: await issueRecoveryKey(userId) };
}

async function changeEmail(body: Json): Promise<Json> {
  const userId = await userFromToken(body.access_token);
  await requirePassword(userId, body.password);
  const email = normalizeEmail(body.new_email);
  const { error } = await admin.auth.admin.updateUserById(userId, { email, email_confirm: true });
  if (isEmailTaken(error)) throw new ServiceError(409, "email_taken");
  if (error) throw new ServiceError(503, "service_unavailable");
  return { email };
}

async function deleteAccount(body: Json): Promise<Json> {
  const userId = await userFromToken(body.access_token);
  await requirePassword(userId, body.password);

  const anonymize = await admin.rpc("svc_anonymize_account", { p_user: userId });
  if (anonymize.error) throw new ServiceError(503, "service_unavailable");

  const listing = await admin.storage.from("avatars").list(userId, { limit: 100 });
  if (!listing.error && listing.data && listing.data.length > 0) {
    await admin.storage.from("avatars").remove(listing.data.map((f) => `${userId}/${f.name}`));
  }

  const revoke = await admin.rpc("svc_revoke_sessions", { p_user: userId });
  if (revoke.error) throw new ServiceError(503, "service_unavailable");
  const removed = await admin.auth.admin.deleteUser(userId);
  if (removed.error) throw new ServiceError(503, "service_unavailable");
  return { deleted: true };
}

const actions: Record<string, (body: Json) => Promise<Json>> = {
  signup,
  recover,
  change_email: changeEmail,
  delete_account: deleteAccount,
};

Deno.serve(async (req: Request) => {
  try {
    if (req.method !== "POST") throw new ServiceError(405, "method_not_allowed");
    await verifyGateway(req);
    let body: Json;
    try {
      body = await req.json();
    } catch {
      throw new ServiceError(400, "invalid_request");
    }
    const handler = typeof body?.action === "string" ? actions[body.action] : undefined;
    if (!handler) throw new ServiceError(400, "invalid_request");
    return respond(200, await handler(body));
  } catch (e) {
    if (e instanceof ServiceError) return respond(e.status, { error: { code: e.code } });
    console.error("account service failure", e instanceof Error ? e.name : "unknown");
    return respond(500, { error: { code: "internal" } });
  }
});
