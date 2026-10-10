import { describe, expect, it } from "vitest";
import { createApp, isStrongPassword } from "../src/api.js";
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

/** In-memory stand-in for bff_rate_limit: counts hits per bucket against the requested limit. */
function memoryLimiter() {
  const hits = new Map<string, number>();
  const handler: Handler = (call) => {
    const { p_bucket, p_limit } = call.body as { p_bucket: string; p_limit: number };
    const n = (hits.get(p_bucket) ?? 0) + 1;
    hits.set(p_bucket, n);
    return { status: 200, body: n <= p_limit };
  };
  return { hits, handler };
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

  it("ends the session only when the refresh token is rejected", async () => {
    let status = 400;
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "grant_type=refresh_token": () => ({ status, body: { error_code: "x" } }),
      }),
    );
    const expected: Record<number, [number, string]> = {
      400: [401, "session_expired"],
      401: [401, "session_expired"],
      403: [401, "session_expired"],
      404: [503, "service_unavailable"],
      408: [503, "service_unavailable"],
      409: [503, "service_unavailable"],
      422: [503, "service_unavailable"],
      429: [429, "rate_limited"],
      500: [503, "service_unavailable"],
      502: [503, "service_unavailable"],
    };
    for (const [upstream, [httpStatus, code]] of Object.entries(expected)) {
      status = Number(upstream);
      const res = await h.request("/v1/auth/refresh", json({ refresh_token: "r".repeat(20) }));
      expect(res.status, `upstream ${upstream}`).toBe(httpStatus);
      expect((await res.json()).error.code, `upstream ${upstream}`).toBe(code);
    }
  });

  it("does not let sign-in attempts from other addresses lock an account out", async () => {
    const limiter = memoryLimiter();
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": limiter.handler,
        "grant_type=password": (call) =>
          (call.body as { password: string }).password === "Padel2026"
            ? { status: 200, body: session }
            : { status: 400, body: { error_code: "invalid_credentials" } },
      }),
    );
    const login = (password: string, ip: string) =>
      h.request("/v1/auth/login", json({ email: "anna@example.com", password }, { "x-real-ip": ip }));

    for (let i = 0; i < 10; i++) expect((await login("wrong-1", "6.6.6.6")).status).toBe(401);
    const blocked = await login("Padel2026", "6.6.6.6");
    expect(blocked.status).toBe(429);
    expect((await blocked.json()).error.code).toBe("rate_limited");
    // The owner, from their own address, still signs in.
    expect((await login("Padel2026", "1.2.3.4")).status).toBe(200);
    // Buckets never contain the address in plain text.
    expect([...limiter.hits.keys()].some((k) => k.includes("anna"))).toBe(false);
    expect([...limiter.hits.keys()].filter((k) => k.startsWith("login:email-ip:"))).toHaveLength(2);
  });

  it("caps sign-in attempts per email across addresses", async () => {
    const limiter = memoryLimiter();
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": limiter.handler,
        "grant_type=password": () => ({ status: 400, body: { error_code: "invalid_credentials" } }),
      }),
    );
    const login = (ip: string) => h.request("/v1/auth/login", json({ email: "anna@example.com", password: "x" }, { "x-real-ip": ip }));
    for (let ip = 0; ip < 10; ip++) {
      for (let i = 0; i < 10; i++) expect((await login(`10.0.0.${ip}`)).status).toBe(401);
    }
    expect((await login("10.0.1.1")).status).toBe(429);
    const ceiling = [...limiter.hits.entries()].find(([k]) => k.startsWith("login:email:"))!;
    expect(ceiling[1]).toBe(101);
    // Other accounts are unaffected.
    const other = await h.request("/v1/auth/login", json({ email: "boris@example.com", password: "x" }, { "x-real-ip": "10.0.1.1" }));
    expect(other.status).toBe(401);
  });

  it("keeps rate-limit buckets short for long addresses", async () => {
    const limiter = memoryLimiter();
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": limiter.handler,
        "grant_type=password": () => ({ status: 400, body: { error_code: "invalid_credentials" } }),
      }),
    );
    const longEmail = `${"a".repeat(64)}@${"b".repeat(180)}.com`;
    const res = await h.request("/v1/auth/login", json({ email: longEmail, password: "x" }, { "x-real-ip": "f".repeat(300) }));
    expect(res.status).toBe(401);
    for (const bucket of limiter.hits.keys()) expect(bucket.length).toBeLessThanOrEqual(200);
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

describe("account security", () => {
  const ip = { "x-real-ip": "1.2.3.4" };
  const del = (body: unknown, extra: Record<string, string> = {}) => ({ ...json(body, { ...auth, ...extra }), method: "DELETE" });
  const routes: Array<[string, () => RequestInit, string]> = [
    ["/v1/account/password", () => json({ current_password: "x", new_password: "Padel2027" }, { ...auth, ...ip }), "/rpc/verify_my_password"],
    ["/v1/account/email", () => json({ new_email: "new@example.com", password: "x" }, { ...auth, ...ip }), "/functions/v1/account"],
    ["/v1/account/recovery-key", () => json({ password: "x" }, { ...auth, ...ip }), "/rpc/regenerate_recovery_key"],
    ["/v1/account", () => del({ password: "x" }, ip), "/functions/v1/account"],
  ];

  it("limits password-protected actions per client address before checking the password", async () => {
    for (const [path, init, upstreamPath] of routes) {
      let allowed = false;
      const h = harness(routeTo({ "/rpc/bff_rate_limit": () => ({ status: 200, body: allowed }) }, () => ({ status: 200, body: {} })));
      const res = await h.request(path, init());
      expect(res.status, path).toBe(429);
      expect((await res.json()).error.code).toBe("rate_limited");
      expect(h.calls.some((c) => c.url.includes(upstreamPath)), path).toBe(false);
      const limitCall = h.calls.find((c) => c.url.includes("bff_rate_limit"))!;
      expect(limitCall.body).toMatchObject({ p_bucket: "password:ip:1.2.3.4", p_limit: 20, p_window_seconds: 900 });
    }
  });

  it("maps a wrong password reported by regenerate_recovery_key to invalid_password", async () => {
    let result: unknown = { error: "invalid_password" };
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "/rpc/regenerate_recovery_key": () => ({ status: 200, body: result }),
      }),
    );
    let res = await h.request("/v1/account/recovery-key", json({ password: "wrong" }, auth));
    expect(res.status).toBe(403);
    expect((await res.json()).error.code).toBe("invalid_password");

    result = { recovery_key: "AAAAA-BBBBB-CCCCC-DDDDD" };
    res = await h.request("/v1/account/recovery-key", json({ password: "Padel2026" }, auth));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ recovery_key: "AAAAA-BBBBB-CCCCC-DDDDD" });
  });

  it("passes the per-user password limit of the database through", async () => {
    const h = harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "/rpc/regenerate_recovery_key": () => ({ status: 400, body: { code: "P0001", message: "rate_limited", details: "" } }),
        "/functions/v1/account": () => ({ status: 429, body: { error: { code: "rate_limited" } } }),
      }),
    );
    let res = await h.request("/v1/account/recovery-key", json({ password: "x" }, auth));
    expect(res.status).toBe(429);
    res = await h.request("/v1/account", del({ password: "x" }));
    expect(res.status).toBe(429);
    expect((await res.json()).error.code).toBe("rate_limited");
  });

  function passwordChange(logout: Handler) {
    return harness(
      routeTo({
        "/rpc/bff_rate_limit": () => ({ status: 200, body: true }),
        "/rpc/verify_my_password": () => ({ status: 200, body: true }),
        "/auth/v1/user": () => ({ status: 200, body: { id: session.user.id } }),
        "/auth/v1/logout": logout,
      }),
    );
  }
  const change = () => json({ current_password: "Padel2026", new_password: "Padel2027" }, auth);
  const logoutCalls = (h: ReturnType<typeof harness>) => h.calls.filter((c) => c.url.includes("/auth/v1/logout?scope=others"));

  it("ends the other sessions after a password change", async () => {
    const h = passwordChange(() => ({ status: 204 }));
    const res = await h.request("/v1/account/password", change());
    expect(res.status).toBe(204);
    expect(logoutCalls(h)).toHaveLength(1);
    expect(h.calls.findIndex((c) => c.url.includes("/auth/v1/user"))).toBeLessThan(h.calls.indexOf(logoutCalls(h)[0]!));
  });

  it("retries ending the other sessions once", async () => {
    let attempt = 0;
    const h = passwordChange(() => (++attempt === 1 ? { status: 503 } : { status: 204 }));
    const res = await h.request("/v1/account/password", change());
    expect(res.status).toBe(204);
    expect(logoutCalls(h)).toHaveLength(2);
  });

  it("tells the user the password changed when the other sessions could not be ended", async () => {
    for (const failure of [
      () => ({ status: 502 }),
      () => ({ status: 429 }),
      () => {
        throw new TypeError("fetch failed");
      },
    ]) {
      const h = passwordChange(failure);
      const res = await h.request("/v1/account/password", change());
      expect(res.status).toBe(503);
      const body = await res.json();
      expect(body.error.code).toBe("password_changed_sessions_active");
      expect(body.error.message).toContain("Пароль изменён");
      expect(body.error.message).toContain("«Выйти на всех устройствах»");
      expect(logoutCalls(h)).toHaveLength(2);
      expect(h.calls.filter((c) => c.url.includes("/auth/v1/user"))).toHaveLength(1);
    }
  });

  it("treats an already ended session as signed out, and other logout failures as errors", async () => {
    const expected: Record<number, number> = { 204: 204, 401: 204, 403: 204, 404: 204, 429: 429, 400: 503, 500: 503 };
    for (const [upstream, status] of Object.entries(expected)) {
      const h = harness(routeTo({ "/auth/v1/logout": () => ({ status: Number(upstream) }) }));
      const res = await h.request("/v1/auth/logout", json({ scope: "global" }, auth));
      expect(res.status, `upstream ${upstream}`).toBe(status);
    }
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

  it("passes the history cursor, tolerating an unencoded plus sign", async () => {
    const h = harness(routeTo({ "/rpc/my_matches": (call) => ({ status: 200, body: call.body }) }));
    const id = "6F1C1A5E-6A4B-4C43-9E0B-1C3B9F0F9A11";
    let res = await h.request(`/v1/matches?scope=history&before=2026-10-01T18:30:00.123456Z&before_id=${id}`, { headers: auth });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      p_scope: "history",
      p_before: "2026-10-01T18:30:00.123456Z",
      p_before_id: id.toLowerCase(),
      p_limit: 30,
      p_type: null,
    });
    res = await h.request("/v1/matches?scope=history&before=2026-10-01T18:30:00+00:00", { headers: auth });
    expect(res.status).toBe(200);
    expect((await res.json()).p_before).toBe("2026-10-01T18:30:00+00:00");
    res = await h.request("/v1/matches?scope=history&before_id=nope", { headers: auth });
    expect(res.status).toBe(400);
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

describe("friendship and scheduled-game contracts", () => {
  const player = "11111111-1111-1111-1111-111111111111";
  const game = "6f1c1a5e-6a4b-4c43-9e0b-1c3b9f0f9a11";
  const key = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const create = {
    starts_at: "2026-10-12T19:00:00+03:00", city_id: 1, club_id: null,
    location: "  Центральный корт  ", match_type: "ranked", min_level: 2.5, max_level: 4,
    note: "Собираем пару",
  };

  it("requires authentication on every relationship and scheduled-game route", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    for (const [method, path] of [
      ["GET", "/v1/friends"], ["GET", `/v1/friends/${player}`],
      ["POST", `/v1/friends/${player}/request`], ["POST", `/v1/friends/${player}/respond`],
      ["DELETE", `/v1/friends/${player}`], ["GET", "/v1/upcoming-matches"],
      ["POST", "/v1/upcoming-matches"], ["GET", `/v1/upcoming-matches/${game}`],
      ...["join", "leave", "cancel", "result"].map((a) => ["POST", `/v1/upcoming-matches/${game}/${a}`]),
      ["POST", `/v1/upcoming-matches/${game}/requests/${player}/respond`],
    ]) {
      expect((await h.request(path!, { method })).status, path).toBe(401);
    }
    expect(h.calls).toHaveLength(0);
  });

  it("uses only the caller's token and maps friendship decisions explicitly", async () => {
    const h = harness((call) => ({ status: 200, body: call.body }));
    const res = await h.request("/v1/friends", { headers: auth });
    expect(res.status).toBe(200);
    expect(h.calls[0]!.url).toContain("/rpc/friendships");
    const actions: Array<[string, RequestInit, string]> = [
      [`/v1/friends/${player}/request`, { method: "POST", headers: auth }, "request"],
      [`/v1/friends/${player}/respond`, json({ decision: "accepted" }, auth), "accept"],
      [`/v1/friends/${player}/respond`, json({ decision: "rejected" }, auth), "reject"],
      [`/v1/friends/${player}`, { method: "DELETE", headers: auth }, "remove"],
    ];
    for (const [path, init, action] of actions) {
      const response = await h.request(path, init);
      expect(await response.json()).toEqual({ p_player: player, p_action: action });
      expect(h.calls.at(-1)!.url).toContain("/rpc/friendship_action");
      expect(h.calls.at(-1)!.headers.authorization).toBe(auth.authorization);
    }
    const status = await h.request(`/v1/friends/${player.toUpperCase()}`, { headers: auth });
    expect(await status.json()).toEqual({ p_player: player });
    expect(h.calls.at(-1)!.url).toContain("/rpc/friendship_status");
  });

  it("rejects malformed decisions and identifiers without calling the database", async () => {
    const h = harness(() => ({ status: 200 }));
    for (const path of [`/v1/friends/${player}/respond`, `/v1/upcoming-matches/${game}/requests/${player}/respond`]) {
      for (const body of [{ decision: "approved" }, { decision: "accepted", player_id: game }, {}]) {
        expect((await h.request(path, json(body, auth))).status).toBe(400);
      }
    }
    expect((await h.request("/v1/friends/not-uuid/request", { method: "POST", headers: auth })).status).toBe(404);
    expect((await h.request(`/v1/upcoming-matches/${game}/requests/not-uuid/respond`, json({ decision: "accepted" }, auth))).status).toBe(404);
    expect(h.calls).toHaveLength(0);
  });

  it("binds publication to its retry key and validates time, place and level boundaries", async () => {
    const h = harness((call) => ({ status: 200, body: call.body }));
    expect((await h.request("/v1/upcoming-matches", json(create, auth))).status).toBe(400);
    const headers = { ...auth, "idempotency-key": key.toUpperCase() };
    for (const patch of [
      { min_level: 4.1 }, { min_level: -0.1 }, { max_level: 7.1 },
      { starts_at: "2026-10-12" }, { starts_at: "2026-10-12T19:00:00" },
      { city_id: 1.5 }, { location: " " }, { location: "а".repeat(161) },
      { note: "а".repeat(501) }, { client_id: game }, { organizer_id: player },
    ]) {
      expect((await h.request("/v1/upcoming-matches", json({ ...create, ...patch }, headers))).status).toBe(400);
    }
    expect(h.calls).toHaveLength(0);
    const res = await h.request("/v1/upcoming-matches", json({ ...create, client_id: key, min_level: 0, max_level: 7 }, headers));
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ p: { ...create, location: "Центральный корт", client_id: key, min_level: 0, max_level: 7 } });
    expect(h.calls[0]!.url).toContain("/rpc/create_scheduled_match");
    expect(h.calls[0]!.headers.authorization).toBe(auth.authorization);
  });

  it("validates and preserves scheduled-game pagination and ownership scope", async () => {
    const h = harness((call) => ({ status: 200, body: call.body }));
    for (const query of ["scope=history", "scope=all", "city_id=-1", "limit=51", "offset=1.5", "accepted_only=1", "scope=open&accepted_only=true"]) {
      expect((await h.request(`/v1/upcoming-matches?${query}`, { headers: auth })).status).toBe(400);
    }
    expect(h.calls).toHaveLength(0);
    const res = await h.request("/v1/upcoming-matches?scope=mine&accepted_only=true&city_id=1&limit=20&offset=40", { headers: auth });
    expect(await res.json()).toEqual({ p: { scope: "mine", accepted_only: true, city_id: 1, limit: 20, offset: 40 } });
    expect(h.calls[0]!.url).toContain("/rpc/scheduled_matches");
  });

  it("routes participation and organizer review to separate authorized RPCs", async () => {
    const h = harness((call) => ({ status: 200, body: call.body }));
    for (const action of ["join", "leave", "cancel"]) {
      const res = await h.request(`/v1/upcoming-matches/${game}/${action}`, { method: "POST", headers: auth });
      expect(await res.json()).toEqual({ p_match: game });
      expect(h.calls.at(-1)!.url).toContain(`/rpc/${action}_scheduled_match`);
      expect(h.calls.at(-1)!.headers.authorization).toBe(auth.authorization);
    }
    const review = await h.request(`/v1/upcoming-matches/${game}/requests/${player}/respond`, json({ decision: "accepted" }, auth));
    expect(await review.json()).toEqual({ p_match: game, p_player: player, p_decision: "accepted" });
    expect(h.calls.at(-1)!.url).toContain("/rpc/review_scheduled_application");
  });

  it("keeps the played-result body and outbox retry key intact", async () => {
    const h = harness((call) => ({ status: 200, body: call.body }));
    const result = { match_type: "friendly", format: "best_of_3", played_at: "2026-10-12T21:00:00Z", players: [], sets: [] };
    const path = `/v1/upcoming-matches/${game}/result`;
    expect((await h.request(path, json(result, auth))).status).toBe(400);
    expect(h.calls).toHaveLength(0);
    const res = await h.request(path, json(result, { ...auth, "idempotency-key": key }));
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ p_match: game, p: result, p_idempotency_key: key });
    expect(h.calls[0]!.url).toContain("/rpc/submit_scheduled_result");
  });

  it("preserves actionable privacy, capacity and replay errors from the database", async () => {
    for (const [code, status] of Object.entries({
      friendship_self: 400, friendship_not_incoming: 409, friendship_not_pending: 409,
      scheduled_match_not_found: 404, scheduled_match_full: 409, organizer_required: 403,
      level_out_of_range: 403, scheduled_match_not_started: 409, scheduled_match_not_full: 409,
      scheduled_lineup_mismatch: 400, scheduled_result_mismatch: 409, scheduled_match_closed: 409,
    })) {
      const h = harness(() => ({ status: 400, body: { code: "P0001", message: code } }));
      const res = await h.request(`/v1/upcoming-matches/${game}/join`, { method: "POST", headers: auth });
      expect(res.status, code).toBe(status);
      expect((await res.json()).error.code).toBe(code);
    }
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

  it("accepts photos larger than the JSON body limit and rejects ones over 1 MB", async () => {
    const userId = "11111111-1111-1111-1111-111111111111";
    const h = harness(
      routeTo({
        "/rpc/me": () => ({ status: 200, body: { user_id: userId, profile: { avatar_path: null } } }),
        "/storage/v1/object/avatars/": () => ({ status: 200, body: { Key: "x" } }),
        "/rpc/set_avatar": () => ({ status: 200, body: { ok: true } }),
      }),
    );
    const photo = new Uint8Array(600 * 1024);
    photo.set([0xff, 0xd8, 0xff, 0xe0]);
    let res = await h.request("/v1/me/avatar", { method: "PUT", headers: { ...auth, "content-type": "image/jpeg" }, body: photo });
    expect(res.status).toBe(200);

    const tooLarge = new Uint8Array(1024 * 1024 + 1);
    tooLarge.set([0xff, 0xd8, 0xff, 0xe0]);
    res = await h.request("/v1/me/avatar", { method: "PUT", headers: { ...auth, "content-type": "image/jpeg" }, body: tooLarge });
    expect(res.status).toBe(413);
    expect((await res.json()).error.code).toBe("payload_too_large");
  });

  it("keeps the 64 KB limit for JSON bodies", async () => {
    const h = harness(() => ({ status: 200, body: {} }));
    const res = await h.request("/v1/me", {
      method: "PATCH",
      headers: { ...auth, "content-type": "application/json" },
      body: JSON.stringify({ bio: "x".repeat(70 * 1024) }),
    });
    expect(res.status).toBe(413);
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
