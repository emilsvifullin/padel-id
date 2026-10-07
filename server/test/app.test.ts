import { describe, expect, it } from "vitest";
import { createApp, isStrongPassword } from "../src/app.js";
import type { Config } from "../src/config.js";
import { Upstream, type FetchFn } from "../src/upstream.js";

const config: Config = {
  supabaseUrl: "https://example.supabase.co",
  supabaseKey: "sb_publishable_test",
  gatewaySecret: "g".repeat(48),
  minClientBuild: 5,
  upstreamTimeoutMs: 1000,
  signupsPerHour: 5,
};

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

type Handler = (call: Call) => { status: number; body?: unknown } | Promise<{ status: number; body?: unknown }>;

function harness(handler: Handler) {
  const calls: Call[] = [];
  const fakeFetch: FetchFn = async (input, init) => {
    const headers: Record<string, string> = {};
    new Headers(init?.headers).forEach((v, k) => (headers[k] = v));
    let body: unknown = init?.body;
    if (typeof body === "string") {
      try {
        body = JSON.parse(body);
      } catch {
        /* keep text */
      }
    }
    const call = { url: String(input), method: init?.method ?? "GET", headers, body };
    calls.push(call);
    const res = await handler(call);
    return new Response(res.body === undefined ? null : JSON.stringify(res.body), {
      status: res.status,
      headers: { "content-type": "application/json" },
    });
  };
  const app = createApp(() => ({ config, upstream: new Upstream(config, fakeFetch) }));
  const request = (path: string, init: RequestInit = {}) => app.request(path, init);
  return { calls, request };
}

const session = {
  access_token: "a".repeat(40),
  refresh_token: "r".repeat(20),
  expires_in: 3600,
  expires_at: 2_000_000_000,
  user: { id: "11111111-1111-1111-1111-111111111111", email: "anna@example.com" },
};

const json = (body: unknown, extra: Record<string, string> = {}) => ({
  method: "POST",
  headers: { "content-type": "application/json", ...extra },
  body: JSON.stringify(body),
});

const auth = { authorization: `Bearer ${"t".repeat(40)}` };

function routeTo(map: Record<string, Handler>, fallback: Handler = () => ({ status: 500 })): Handler {
  return (call) => {
    for (const [fragment, handler] of Object.entries(map)) {
      if (call.url.includes(fragment)) return handler(call);
    }
    return fallback(call);
  };
}

describe("password policy", () => {
  it("requires length, letters and digits", () => {
    expect(isStrongPassword("short1")).toBe(false);
    expect(isStrongPassword("onlyletters")).toBe(false);
    expect(isStrongPassword("12345678")).toBe(false);
    expect(isStrongPassword("Падел2026")).toBe(true);
    expect(isStrongPassword("correct horse 7")).toBe(true);
    expect(isStrongPassword("a1".repeat(40))).toBe(false);
  });
});

describe("service endpoints", () => {
  it("reports health without touching upstream", async () => {
    const h = harness(() => ({ status: 500 }));
    const res = await h.request("/v1/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok", commit: null });
    expect(h.calls).toHaveLength(0);
    expect(res.headers.get("cache-control")).toBe("no-store");
    expect(res.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("returns a structured 404 for unknown routes", async () => {
    const h = harness(() => ({ status: 500 }));
    const res = await h.request("/v1/nope");
    expect(res.status).toBe(404);
    expect((await res.json()).error.code).toBe("not_found");
  });

  it("rejects outdated clients", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    const res = await h.request("/v1/me", { headers: { ...auth, "x-padelid-build": "4" } });
    expect(res.status).toBe(426);
    expect((await res.json()).error.code).toBe("client_outdated");
  });
});

describe("authentication", () => {
  it("validates signup input before calling upstream", async () => {
    const h = harness(() => ({ status: 500 }));
    let res = await h.request("/v1/auth/signup", json({ email: "not-an-email", password: "Padel2026" }));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("invalid_email");
    res = await h.request("/v1/auth/signup", json({ email: "anna@example.com", password: "weak" }));
    expect((await res.json()).error.code).toBe("weak_password");
    res = await h.request("/v1/auth/signup", { method: "POST", body: "{broken" });
    expect((await res.json()).error.code).toBe("invalid_request");
    expect(h.calls).toHaveLength(0);
  });

  it("creates the account, signs in and returns the recovery key", async () => {
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "/functions/v1/account": () => ({ status: 200, body: { user_id: session.user.id, recovery_key: "AAAAA-BBBBB-CCCCC-DDDDD" } }),
        "grant_type=password": () => ({ status: 200, body: session }),
      }),
    );
    const res = await h.request("/v1/auth/signup", json({ email: " Anna@Example.com ", password: "Padel2026" }, { "x-real-ip": "1.2.3.4" }));
    expect(res.status).toBe(201);
    const body = await res.json();
    expect(body.recovery_key).toBe("AAAAA-BBBBB-CCCCC-DDDDD");
    expect(body.session.access_token).toBe(session.access_token);
    const accountCall = h.calls.find((c) => c.url.endsWith("/functions/v1/account"))!;
    expect(accountCall.headers["x-padelid-gateway"]).toBe(config.gatewaySecret);
    expect((accountCall.body as Record<string, unknown>).email).toBe("anna@example.com");
    const limitCall = h.calls.find((c) => c.url.includes("bff_rate_limit"))!;
    expect((limitCall.body as Record<string, unknown>).p_bucket).toBe("signup:ip:1.2.3.4");
  });

  it("still returns the recovery key when the follow-up sign in fails", async () => {
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "/functions/v1/account": () => ({ status: 200, body: { user_id: session.user.id, recovery_key: "KEY" } }),
        "grant_type=password": () => ({ status: 503 }),
      }),
    );
    const res = await h.request("/v1/auth/signup", json({ email: "anna@example.com", password: "Padel2026" }));
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ session: null, recovery_key: "KEY" });
  });

  it("maps duplicate email from the account service", async () => {
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "/functions/v1/account": () => ({ status: 409, body: { error: { code: "email_taken" } } }),
      }),
    );
    const res = await h.request("/v1/auth/signup", json({ email: "anna@example.com", password: "Padel2026" }));
    expect(res.status).toBe(409);
    const body = await res.json();
    expect(body.error.code).toBe("email_taken");
    expect(body.error.message).toMatch(/уже существует/);
  });

  it("maps invalid credentials and rate limits", async () => {
    let allowed = true;
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: allowed }),
        "grant_type=password": () => ({ status: 400, body: { error_code: "invalid_credentials" } }),
      }),
    );
    let res = await h.request("/v1/auth/login", json({ email: "anna@example.com", password: "nope" }));
    expect(res.status).toBe(401);
    expect((await res.json()).error.code).toBe("invalid_credentials");
    allowed = false;
    res = await h.request("/v1/auth/login", json({ email: "anna@example.com", password: "nope" }));
    expect(res.status).toBe(429);
  });

  it("fails open when the rate limiter is unreachable", async () => {
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 503 }),
        "grant_type=password": () => ({ status: 200, body: session }),
      }),
    );
    const res = await h.request("/v1/auth/login", json({ email: "anna@example.com", password: "Padel2026" }));
    expect(res.status).toBe(200);
  });

  it("turns refresh failures into session_expired", async () => {
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "grant_type=refresh_token": () => ({ status: 400, body: { error_code: "refresh_token_already_used" } }),
      }),
    );
    const res = await h.request("/v1/auth/refresh", json({ refresh_token: "r".repeat(20) }));
    expect(res.status).toBe(401);
    expect((await res.json()).error.code).toBe("session_expired");
  });

  it("requires a bearer token for protected routes", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    const res = await h.request("/v1/me");
    expect(res.status).toBe(401);
    expect((await res.json()).error.code).toBe("not_authenticated");
    expect(h.calls).toHaveLength(0);
  });

  it("verifies the current password before changing it", async () => {
    const h = harness(routeTo({ "/rpc/verify_my_password": () => ({ status: 200, body: false }) }));
    const res = await h.request("/v1/account/password", json({ current_password: "x", new_password: "Padel2027" }, auth));
    expect(res.status).toBe(403);
    expect((await res.json()).error.code).toBe("invalid_password");
    expect(h.calls.some((c) => c.url.includes("/auth/v1/user"))).toBe(false);
  });
});

describe("data API", () => {
  it("forwards the user token to PostgREST and returns the payload", async () => {
    const h = harness(routeTo({ "/rpc/me": () => ({ status: 200, body: { user_id: "u", needs_onboarding: true } }) }));
    const res = await h.request("/v1/me", { headers: auth });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ user_id: "u", needs_onboarding: true });
    expect(h.calls[0]!.headers.authorization).toBe(auth.authorization);
    expect(h.calls[0]!.headers.apikey).toBe(config.supabaseKey);
  });

  it("maps database application errors to HTTP statuses", async () => {
    const h = harness(
      routeTo({ "/rpc/confirm_match": () => ({ status: 400, body: { code: "P0001", message: "version_conflict", details: "3" } }) }),
    );
    const res = await h.request(
      "/v1/matches/6f1c1a5e-6a4b-4c43-9e0b-1c3b9f0f9a11/confirm",
      json({ version: 2 }, auth),
    );
    expect(res.status).toBe(409);
    const body = await res.json();
    expect(body.error.code).toBe("version_conflict");
    expect(body.error.message).toMatch(/изменился/);
  });

  it("treats expired JWTs as session_expired", async () => {
    const h = harness(routeTo({ "/rpc/home": () => ({ status: 401, body: { code: "PGRST301", message: "JWT expired" } }) }));
    const res = await h.request("/v1/home", { headers: auth });
    expect(res.status).toBe(401);
    expect((await res.json()).error.code).toBe("session_expired");
  });

  it("requires an idempotency key to create matches", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    let res = await h.request("/v1/matches", json({ match_type: "ranked" }, auth));
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("idempotency_key_required");
    const h2 = harness(routeTo({ "/rpc/create_match": (call) => ({ status: 200, body: { id: "m", echo: call.body } }) }));
    res = await h2.request("/v1/matches", json({ match_type: "ranked" }, { ...auth, "idempotency-key": "6f1c1a5e-6a4b-4c43-9e0b-1c3b9f0f9a11" }));
    expect(res.status).toBe(201);
    expect((await res.json()).echo.p_idempotency_key).toBe("6f1c1a5e-6a4b-4c43-9e0b-1c3b9f0f9a11");
  });

  it("validates path identifiers and query parameters", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    let res = await h.request("/v1/players/not-a-uuid", { headers: auth });
    expect(res.status).toBe(404);
    res = await h.request("/v1/players/search?min_level=9", { headers: auth });
    expect(res.status).toBe(400);
    res = await h.request("/v1/matches?scope=everything", { headers: auth });
    expect(res.status).toBe(400);
    expect(h.calls).toHaveLength(0);
  });

  it("passes search filters as typed values", async () => {
    const h = harness(routeTo({ "/rpc/search_players": (call) => ({ status: 200, body: call.body }) }));
    const res = await h.request("/v1/players/search?query=%D0%B0%D0%BD%D0%BD%D0%B0&city_id=1&min_level=2.5&max_level=4&side=left&reliable_only=true&sort=level_desc&limit=10&offset=20", {
      headers: auth,
    });
    const body = await res.json();
    expect(body.p).toMatchObject({ query: "анна", city_id: 1, min_level: 2.5, max_level: 4, side: "left", reliable_only: true, sort: "level_desc", limit: 10, offset: 20 });
  });

  it("rejects oversized JSON bodies", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    const res = await h.request("/v1/me", { method: "PATCH", headers: { ...auth, "content-type": "application/json" }, body: JSON.stringify({ bio: "x".repeat(70_000) }) });
    expect(res.status).toBe(413);
  });

  it("returns 503 when Supabase is unreachable", async () => {
    const h = harness(() => {
      throw new TypeError("fetch failed");
    });
    const res = await h.request("/v1/home", { headers: auth });
    expect(res.status).toBe(503);
    expect((await res.json()).error.code).toBe("service_unavailable");
  });
});

describe("avatars", () => {
  it("accepts only JPEG uploads", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    const png = new Uint8Array(200).fill(1);
    const res = await h.request("/v1/me/avatar", { method: "PUT", headers: { ...auth, "content-type": "image/jpeg" }, body: png });
    expect(res.status).toBe(400);
    expect((await res.json()).error.code).toBe("invalid_image");
  });

  it("uploads to the user's folder and removes the previous file", async () => {
    const userId = "11111111-1111-1111-1111-111111111111";
    const h = harness(
      routeTo({
        "/rpc/me": () => ({ status: 200, body: { user_id: userId, profile: { avatar_path: `${userId}/oldfile123.jpg` } } }),
        "/storage/v1/object/avatars/": () => ({ status: 200, body: { Key: "x" } }),
        "/rpc/set_avatar": (call) => ({ status: 200, body: { ok: true, path: (call.body as Record<string, unknown>).p_path } }),
        "/storage/v1/object/avatars": () => ({ status: 200, body: [] }),
      }),
    );
    const jpeg = new Uint8Array(500);
    jpeg.set([0xff, 0xd8, 0xff, 0xe0]);
    const res = await h.request("/v1/me/avatar", { method: "PUT", headers: { ...auth, "content-type": "image/jpeg" }, body: jpeg });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.path).toMatch(new RegExp(`^${userId}/[A-Za-z0-9_-]{24}\\.jpg$`));
    const del = h.calls.find((c) => c.method === "DELETE")!;
    expect(del.body).toEqual({ prefixes: [`${userId}/oldfile123.jpg`] });
  });

  it("serves avatars with immutable caching and validates paths", async () => {
    const h = harness(() => ({ status: 200, body: "jpeg-bytes" }));
    let res = await h.request("/v1/avatars/11111111-1111-1111-1111-111111111111/abcdefgh12.jpg");
    expect(res.status).toBe(200);
    expect(res.headers.get("cache-control")).toContain("immutable");
    res = await h.request("/v1/avatars/../../etc/passwd");
    expect(res.status).toBe(404);
    res = await h.request("/v1/avatars/11111111-1111-1111-1111-111111111111/evil.png");
    expect(res.status).toBe(404);
  });
});
