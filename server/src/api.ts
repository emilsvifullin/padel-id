import { Hono, type Context } from "hono";
import { bodyLimit } from "hono/body-limit";
import { z } from "zod";
import type { Config } from "./config.js";
import { ApiError, apiError, errorBody } from "./errors.js";
import { Upstream, type Session } from "./upstream.js";

export interface Deps {
  config: Config;
  upstream: Upstream;
}

type Env = { Variables: { requestId: string } };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const AVATAR_FILE_RE = /^[A-Za-z0-9_-]{8,64}\.jpg$/;
const MAX_AVATAR_BYTES = 1024 * 1024;

const email = z
  .string()
  .trim()
  .toLowerCase()
  .max(254)
  .refine((v) => EMAIL_RE.test(v), { message: "invalid_email" });

export function isStrongPassword(value: string): boolean {
  const bytes = new TextEncoder().encode(value).length;
  return value.length >= 8 && bytes <= 72 && /\p{L}/u.test(value) && /\d/.test(value) && !/^(.)\1+$/.test(value);
}

const newPassword = z.string().refine(isStrongPassword, { message: "weak_password" });
const anyPassword = z.string().min(1).max(200);
const uuid = z.string().regex(UUID_RE);
const version = z.number().int().min(1);

const schemas = {
  signup: z.object({ email, password: newPassword }),
  login: z.object({ email, password: anyPassword }),
  refresh: z.object({ refresh_token: z.string().min(10).max(2048) }),
  logout: z.object({ scope: z.enum(["local", "global"]).default("local") }),
  recover: z.object({ email, recovery_key: z.string().min(10).max(64), new_password: newPassword }),
  changePassword: z.object({ current_password: anyPassword, new_password: newPassword }),
  changeEmail: z.object({ new_email: email, password: anyPassword }),
  passwordOnly: z.object({ password: anyPassword }),
  version: z.object({ version }),
  dispute: z.object({
    version,
    reason: z.enum(["wrong_score", "wrong_players", "wrong_type", "not_played", "other"]),
    // The database limits the comment to 140 code points; UTF-16 needs up to twice as many units.
    comment: z.string().max(280).nullish(),
  }),
  updateMatch: z.object({ version, match: z.record(z.string(), z.unknown()) }),
  club: z.object({ city_id: z.number().int().positive(), name: z.string().min(1).max(120) }),
  review: z.object({ decision: z.enum(["approved", "rejected", "revoked"]), note: z.string().max(300).nullish() }),
  object: z.record(z.string(), z.unknown()),
};

function issueCode(err: z.ZodError): string {
  for (const issue of err.issues) {
    if (issue.message === "weak_password" || issue.message === "invalid_email") return issue.message;
    if (issue.path[0] === "email" || issue.path[0] === "new_email") return "invalid_email";
  }
  return "invalid_request";
}

async function parseJson<T extends z.ZodType>(c: Context<Env>, schema: T): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw apiError("invalid_request");
  }
  const result = schema.safeParse(raw);
  if (!result.success) throw apiError(issueCode(result.error));
  return result.data;
}

function bearer(c: Context<Env>): string {
  const header = c.req.header("authorization") ?? "";
  const match = /^Bearer\s+([A-Za-z0-9._~+/=-]{20,4096})$/.exec(header);
  if (!match?.[1]) throw apiError("not_authenticated");
  return match[1];
}

function pathUuid(c: Context<Env>, name: string): string {
  const value = c.req.param(name) ?? "";
  if (!UUID_RE.test(value)) throw apiError("not_found");
  return value.toLowerCase();
}

function idempotencyKey(c: Context<Env>): string {
  const value = c.req.header("idempotency-key") ?? "";
  if (!UUID_RE.test(value)) throw apiError("idempotency_key_required");
  return value.toLowerCase();
}

function clientIp(c: Context<Env>): string {
  const real = c.req.header("x-real-ip") ?? c.req.header("x-vercel-forwarded-for") ?? c.req.header("x-forwarded-for") ?? "";
  return real.split(",")[0]?.trim() || "unknown";
}

function intQuery(c: Context<Env>, name: string, min: number, max: number): number | undefined {
  const raw = c.req.query(name);
  if (raw === undefined || raw === "") return undefined;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) throw apiError("invalid_request");
  return value;
}

function numberQuery(c: Context<Env>, name: string, min: number, max: number): number | undefined {
  const raw = c.req.query(name);
  if (raw === undefined || raw === "") return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) throw apiError("invalid_request");
  return value;
}

function isoQuery(c: Context<Env>, name: string): string | undefined {
  let raw = c.req.query(name);
  if (raw === undefined || raw === "") return undefined;
  // An unencoded "+" in an offset ("…+00:00") arrives as a space.
  raw = raw.replace(/ (\d{2}(?::?\d{2})?)$/, "+$1");
  if (Number.isNaN(Date.parse(raw))) throw apiError("invalid_request");
  return raw;
}

function uuidQuery(c: Context<Env>, name: string): string | undefined {
  const raw = c.req.query(name);
  if (raw === undefined || raw === "") return undefined;
  if (!UUID_RE.test(raw)) throw apiError("invalid_request");
  return raw.toLowerCase();
}

function randomFileName(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(18));
  return Buffer.from(bytes).toString("base64url") + ".jpg";
}

function sessionBody(session: Session) {
  return {
    access_token: session.access_token,
    refresh_token: session.refresh_token,
    expires_in: session.expires_in,
    expires_at: session.expires_at,
    user: session.user,
  };
}

export function createApp(resolveDeps: () => Deps): Hono<Env> {
  const app = new Hono<Env>();

  app.use("*", async (c, next) => {
    const requestId = crypto.randomUUID();
    c.set("requestId", requestId);
    const started = Date.now();
    await next();
    c.header("x-request-id", requestId);
    c.header("x-content-type-options", "nosniff");
    c.header("strict-transport-security", "max-age=63072000; includeSubDomains");
    c.header("referrer-policy", "no-referrer");
    if (!c.res.headers.has("cache-control")) c.header("cache-control", "no-store");
    // Structured access log without bodies, tokens or personal data.
    console.log(JSON.stringify({ id: requestId, method: c.req.method, route: c.req.routePath, status: c.res.status, ms: Date.now() - started }));
  });

  app.use("/v1/*", async (c, next) => {
    const build = c.req.header("x-padelid-build");
    if (build !== undefined) {
      const n = Number.parseInt(build, 10);
      if (Number.isFinite(n) && n < resolveDeps().config.minClientBuild) throw apiError("client_outdated");
    }
    await next();
  });

  // JSON bodies are small; the avatar upload has its own 1 MB limit below.
  const jsonBodyLimit = bodyLimit({
    maxSize: 64 * 1024,
    onError: () => {
      throw apiError("payload_too_large");
    },
  });
  app.use("/v1/*", async (c, next) => {
    if (c.req.method === "PUT" && c.req.path === "/v1/me/avatar") return next();
    return jsonBodyLimit(c, next);
  });

  app.onError((err, c) => {
    if (err instanceof ApiError) {
      if (err.status >= 500) {
        console.error(JSON.stringify({ id: c.get("requestId"), error: err.code, detail: err.detail }));
      }
      return c.json(errorBody(err), err.status as 400);
    }
    console.error(JSON.stringify({ id: c.get("requestId"), error: "unhandled", name: err instanceof Error ? err.name : "unknown" }));
    return c.json(errorBody(apiError("internal")), 500);
  });

  app.notFound((c) => c.json(errorBody(apiError("not_found")), 404));

  const up = () => resolveDeps().upstream;

  async function limit(bucket: string, max: number, windowSeconds: number): Promise<void> {
    if (!(await up().rateLimit(bucket, max, windowSeconds))) throw apiError("rate_limited");
  }

  // ---------------------------------------------------------------------
  // Service
  // ---------------------------------------------------------------------

  app.get("/v1/health", async (c) => {
    const commit = process.env.VERCEL_GIT_COMMIT_SHA ?? null;
    if (c.req.query("deep") !== "1") return c.json({ status: "ok", commit });
    const database = await up().rateLimit("health", 1_000_000, 60);
    return c.json({ status: "ok", commit, database: database ? "ok" : "degraded" });
  });

  // ---------------------------------------------------------------------
  // Authentication
  // ---------------------------------------------------------------------

  app.post("/v1/auth/signup", async (c) => {
    const body = await parseJson(c, schemas.signup);
    await limit(`signup:ip:${clientIp(c)}`, resolveDeps().config.signupsPerHour, 3600);
    const created = await up().account<{ user_id: string; recovery_key: string }>("signup", {
      email: body.email,
      password: body.password,
    });
    let session: Session | null = null;
    try {
      session = await up().passwordGrant(body.email, body.password);
    } catch {
      // The account exists; the client signs in separately and still shows the key.
      session = null;
    }
    return c.json({ session: session ? sessionBody(session) : null, recovery_key: created.recovery_key }, 201);
  });

  app.post("/v1/auth/login", async (c) => {
    const body = await parseJson(c, schemas.login);
    await limit(`login:ip:${clientIp(c)}`, 30, 600);
    await limit(`login:email:${body.email}`, 10, 600);
    const session = await up().passwordGrant(body.email, body.password);
    return c.json(sessionBody(session));
  });

  app.post("/v1/auth/refresh", async (c) => {
    const body = await parseJson(c, schemas.refresh);
    await limit(`refresh:ip:${clientIp(c)}`, 300, 600);
    const session = await up().refreshGrant(body.refresh_token);
    return c.json(sessionBody(session));
  });

  app.post("/v1/auth/logout", async (c) => {
    const token = bearer(c);
    let scope: "local" | "global" = "local";
    if ((c.req.header("content-length") ?? "0") !== "0") {
      scope = (await parseJson(c, schemas.logout)).scope;
    }
    await up().logout(token, scope);
    return c.body(null, 204);
  });

  app.post("/v1/auth/recover", async (c) => {
    const body = await parseJson(c, schemas.recover);
    await limit(`recover:ip:${clientIp(c)}`, 10, 3600);
    await limit(`recover:email:${body.email}`, 5, 3600);
    const result = await up().account<{ recovery_key: string }>("recover", {
      email: body.email,
      recovery_key: body.recovery_key,
      new_password: body.new_password,
    });
    let session: Session | null = null;
    try {
      session = await up().passwordGrant(body.email, body.new_password);
    } catch {
      session = null;
    }
    return c.json({ session: session ? sessionBody(session) : null, recovery_key: result.recovery_key });
  });

  // ---------------------------------------------------------------------
  // Account security
  // ---------------------------------------------------------------------

  app.post("/v1/account/password", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.changePassword);
    const ok = await up().rpc<boolean>("verify_my_password", { p_password: body.current_password }, token);
    if (ok !== true) throw apiError("invalid_password");
    await up().updatePassword(token, body.new_password);
    await up().logout(token, "others");
    return c.body(null, 204);
  });

  app.post("/v1/account/email", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.changeEmail);
    await up().account("change_email", { access_token: token, password: body.password, new_email: body.new_email });
    return c.json(await up().rpc("me", {}, token));
  });

  app.post("/v1/account/recovery-key", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.passwordOnly);
    return c.json(await up().rpc("regenerate_recovery_key", { p_password: body.password }, token));
  });

  app.delete("/v1/account", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.passwordOnly);
    await up().account("delete_account", { access_token: token, password: body.password });
    return c.body(null, 204);
  });

  // ---------------------------------------------------------------------
  // Me
  // ---------------------------------------------------------------------

  app.get("/v1/me", async (c) => c.json(await up().rpc("me", {}, bearer(c))));

  app.post("/v1/me/onboarding", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("complete_onboarding", { p: body }, token));
  });

  app.patch("/v1/me", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("update_profile", { p: body }, token));
  });

  app.get("/v1/me/username-check", async (c) => {
    const token = bearer(c);
    const username = (c.req.query("username") ?? "").slice(0, 40);
    return c.json(await up().rpc("check_username", { p_username: username }, token));
  });

  app.put("/v1/me/dna-self", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("set_dna_self", { p_answers: body }, token));
  });

  app.put(
    "/v1/me/avatar",
    bodyLimit({
      maxSize: MAX_AVATAR_BYTES,
      onError: () => {
        throw apiError("payload_too_large");
      },
    }),
    async (c) => {
      const token = bearer(c);
      if (!(c.req.header("content-type") ?? "").startsWith("image/jpeg")) throw apiError("invalid_image");
      const bytes = new Uint8Array(await c.req.arrayBuffer()) as Uint8Array<ArrayBuffer>;
      if (bytes.length < 100 || bytes.length > MAX_AVATAR_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
        throw apiError("invalid_image");
      }
      const me = await up().rpc<{ user_id: string; profile: { avatar_path: string | null } | null }>("me", {}, token);
      if (!me.profile) throw apiError("onboarding_required");
      const path = `${me.user_id}/${randomFileName()}`;
      await up().uploadAvatar(token, path, bytes);
      const updated = await up().rpc("set_avatar", { p_path: path }, token);
      if (me.profile.avatar_path) await up().deleteAvatars(token, [me.profile.avatar_path]).catch(() => undefined);
      return c.json(updated);
    },
  );

  app.delete("/v1/me/avatar", async (c) => {
    const token = bearer(c);
    const me = await up().rpc<{ profile: { avatar_path: string | null } | null }>("me", {}, token);
    const updated = await up().rpc("set_avatar", { p_path: null }, token);
    if (me.profile?.avatar_path) await up().deleteAvatars(token, [me.profile.avatar_path]).catch(() => undefined);
    return c.json(updated);
  });

  app.get("/v1/home", async (c) => c.json(await up().rpc("home", {}, bearer(c))));

  // ---------------------------------------------------------------------
  // Players
  // ---------------------------------------------------------------------

  app.get("/v1/players/search", async (c) => {
    const token = bearer(c);
    const side = c.req.query("side");
    if (side !== undefined && side !== "" && !["left", "right", "both"].includes(side)) throw apiError("invalid_request");
    const sort = c.req.query("sort");
    if (sort !== undefined && sort !== "" && !["compatibility", "level_desc", "level_asc", "recent", "name"].includes(sort)) {
      throw apiError("invalid_request");
    }
    const p = {
      query: (c.req.query("query") ?? "").slice(0, 60),
      city_id: intQuery(c, "city_id", 1, 1_000_000),
      club_id: intQuery(c, "club_id", 1, Number.MAX_SAFE_INTEGER),
      min_level: numberQuery(c, "min_level", 0, 7),
      max_level: numberQuery(c, "max_level", 0, 7),
      side: side || undefined,
      reliable_only: c.req.query("reliable_only") === "true",
      coaches_only: c.req.query("coaches_only") === "true",
      sort: sort || undefined,
      limit: intQuery(c, "limit", 1, 50),
      offset: intQuery(c, "offset", 0, 1000),
    };
    return c.json(await up().rpc("search_players", { p }, token));
  });

  app.get("/v1/players/recent", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("recent_players", { p_limit: intQuery(c, "limit", 1, 50) ?? 20 }, token));
  });

  app.get("/v1/players/:id", async (c) => c.json(await up().rpc("player_profile", { p_player: pathUuid(c, "id") }, bearer(c))));

  app.get("/v1/players/:id/rating-history", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("rating_history", { p_player: pathUuid(c, "id"), p_days: intQuery(c, "days", 1, 3650) ?? null }, token));
  });

  app.get("/v1/players/:id/matches", async (c) => {
    const token = bearer(c);
    const type = c.req.query("type");
    if (type !== undefined && type !== "" && type !== "ranked" && type !== "friendly") throw apiError("invalid_request");
    return c.json(
      await up().rpc(
        "player_matches",
        {
          p_player: pathUuid(c, "id"),
          p_before: isoQuery(c, "before") ?? null,
          p_before_id: uuidQuery(c, "before_id") ?? null,
          p_limit: intQuery(c, "limit", 1, 50) ?? 30,
          p_type: type || null,
        },
        token,
      ),
    );
  });

  app.get("/v1/players/:id/dna", async (c) => c.json(await up().rpc("player_dna", { p_player: pathUuid(c, "id") }, bearer(c))));

  app.get("/v1/players/:id/compatibility", async (c) =>
    c.json(await up().rpc("compatibility", { p_player: pathUuid(c, "id") }, bearer(c))),
  );

  app.post("/v1/players/:id/coach-assessments", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("submit_coach_assessment", { p_player: pathUuid(c, "id"), p: body }, token));
  });

  // ---------------------------------------------------------------------
  // Matches
  // ---------------------------------------------------------------------

  app.get("/v1/matches", async (c) => {
    const token = bearer(c);
    const scope = c.req.query("scope") ?? "open";
    if (scope !== "open" && scope !== "history") throw apiError("invalid_request");
    const type = c.req.query("type");
    if (type !== undefined && type !== "" && type !== "ranked" && type !== "friendly") throw apiError("invalid_request");
    return c.json(
      await up().rpc(
        "my_matches",
        {
          p_scope: scope,
          p_before: isoQuery(c, "before") ?? null,
          p_before_id: uuidQuery(c, "before_id") ?? null,
          p_limit: intQuery(c, "limit", 1, 50) ?? 30,
          p_type: type || null,
        },
        token,
      ),
    );
  });

  app.post("/v1/matches", async (c) => {
    const token = bearer(c);
    const key = idempotencyKey(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("create_match", { p: body, p_idempotency_key: key }, token), 201);
  });

  app.post("/v1/matches/preview", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("preview_match", { p: body }, token));
  });

  app.get("/v1/matches/:id", async (c) => c.json(await up().rpc("match_detail", { p_match: pathUuid(c, "id") }, bearer(c))));

  app.put("/v1/matches/:id", async (c) => {
    const token = bearer(c);
    const key = idempotencyKey(c);
    const body = await parseJson(c, schemas.updateMatch);
    return c.json(
      await up().rpc("update_match", { p_match: pathUuid(c, "id"), p_version: body.version, p: body.match, p_idempotency_key: key }, token),
    );
  });

  app.post("/v1/matches/:id/confirm", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.version);
    return c.json(await up().rpc("confirm_match", { p_match: pathUuid(c, "id"), p_version: body.version }, token));
  });

  app.post("/v1/matches/:id/dispute", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.dispute);
    return c.json(
      await up().rpc(
        "dispute_match",
        { p_match: pathUuid(c, "id"), p_version: body.version, p_reason: body.reason, p_comment: body.comment ?? null },
        token,
      ),
    );
  });

  app.post("/v1/matches/:id/cancel", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.version);
    return c.json(await up().rpc("cancel_match", { p_match: pathUuid(c, "id"), p_version: body.version }, token));
  });

  app.put("/v1/matches/:id/feedback", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("submit_match_feedback", { p_match: pathUuid(c, "id"), p: body }, token));
  });

  // ---------------------------------------------------------------------
  // Reference data
  // ---------------------------------------------------------------------

  app.get("/v1/cities", async (c) => {
    const token = bearer(c);
    return c.json(await up().rpc("list_cities", { p_query: (c.req.query("query") ?? "").slice(0, 60) }, token));
  });

  app.get("/v1/clubs", async (c) => {
    const token = bearer(c);
    const city = intQuery(c, "city_id", 1, 1_000_000);
    if (city === undefined) throw apiError("invalid_request");
    return c.json(await up().rpc("list_clubs", { p_city_id: city, p_query: (c.req.query("query") ?? "").slice(0, 60) }, token));
  });

  app.post("/v1/clubs", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.club);
    return c.json(await up().rpc("create_club", { p_city_id: body.city_id, p_name: body.name }, token), 201);
  });

  // ---------------------------------------------------------------------
  // Coaches & administration
  // ---------------------------------------------------------------------

  app.get("/v1/coach/application", async (c) => c.json(await up().rpc("coach_application", {}, bearer(c))));

  app.put("/v1/coach/application", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.object);
    return c.json(await up().rpc("submit_coach_application", { p: body }, token));
  });

  app.get("/v1/admin/coach-applications", async (c) => {
    const token = bearer(c);
    const status = c.req.query("status") ?? "pending";
    if (!["pending", "approved", "rejected", "revoked"].includes(status)) throw apiError("invalid_request");
    return c.json(await up().rpc("admin_coach_applications", { p_status: status }, token));
  });

  app.post("/v1/admin/coach-applications/:id", async (c) => {
    const token = bearer(c);
    const body = await parseJson(c, schemas.review);
    return c.json(
      await up().rpc("admin_review_coach", { p_player: pathUuid(c, "id"), p_decision: body.decision, p_note: body.note ?? null }, token),
    );
  });

  // ---------------------------------------------------------------------
  // Avatars (public, immutable objects)
  // ---------------------------------------------------------------------

  app.get("/v1/avatars/:owner/:file", async (c) => {
    const owner = c.req.param("owner");
    const file = c.req.param("file");
    if (!UUID_RE.test(owner) || !AVATAR_FILE_RE.test(file)) throw apiError("not_found");
    const res = await up().fetchAvatar(`${owner.toLowerCase()}/${file}`);
    if (res.status === 404 || res.status === 400) throw apiError("not_found");
    if (!res.ok || !res.body) throw apiError("service_unavailable");
    return new Response(res.body, {
      status: 200,
      headers: {
        "content-type": "image/jpeg",
        "cache-control": "public, max-age=31536000, immutable",
        "x-content-type-options": "nosniff",
      },
    });
  });

  return app;
}
