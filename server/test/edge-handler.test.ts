import { describe, expect, it } from "vitest";
import { createEdgeHandler, createEdgeNetworkProbe, type EdgeIngress } from "../src/edge-handler.js";
import { loadEdgeConfig } from "../src/edge-config.js";
import type { Config } from "../src/config.js";
import { Upstream, type FetchFn } from "../src/upstream.js";

const config: Config = {
  supabaseUrl: "https://example.supabase.co", supabaseKey: "sb_publishable_test",
  gatewaySecret: "g".repeat(48), minClientBuild: 3, upstreamTimeoutMs: 1000,
  signupsPerHour: 5, releaseCommit: "edge-test-revision",
};
const token = "t".repeat(40);
const conversation = "11111111-1111-1111-1111-111111111111";
const key = "22222222-2222-2222-2222-222222222222";
type Call = { path: string; headers: Headers; body: Record<string, unknown> };
function harness(respond: (call: Call) => { status: number; body: unknown } = () => ({ status: 200, body: true }), ingress: EdgeIngress = {}) {
  const calls: Call[] = [];
  const fake: FetchFn = async (input, init) => {
    const call = { path: new URL(String(input)).pathname, headers: new Headers(init?.headers), body: typeof init?.body === "string" ? JSON.parse(init.body) : {} };
    calls.push(call);
    const result = respond(call);
    return Response.json(result.body, { status: result.status });
  };
  const handle = createEdgeHandler(() => ({ config, upstream: new Upstream(config, fake) }), ingress);
  return { calls, request: (path: string, init: RequestInit = {}) => handle(new Request(`https://example.supabase.co${path}`, init)) };
}

describe("portable Edge Function gateway", () => {
  it("reports transport-only mode without claiming API or database readiness", async () => {
    const handle = createEdgeNetworkProbe("local-verification");
    const shallow = await handle(new Request("https://example.supabase.co/functions/v1/gateway/v1/health"));
    expect(shallow.status).toBe(200);
    expect(await shallow.json()).toEqual({ status: "configuration_required", mode: "network_verification", commit: "local-verification" });
    expect(shallow.headers.get("cache-control")).toBe("no-store");
    const deep = await handle(new Request("https://example.supabase.co/gateway/v1/health?deep=1"));
    expect(deep.status).toBe(503);
    expect(await deep.json()).toMatchObject({ status: "configuration_required", database: "not_checked" });
  });
  it("serves no API reads or mutations in transport-only mode and echoes no credentials", async () => {
    const handle = createEdgeNetworkProbe();
    for (const method of ["GET", "POST"]) {
      const response = await handle(new Request("https://example.supabase.co/gateway/v1/auth/login", {
        method, headers: { authorization: "Bearer private-client-token" },
        ...(method === "POST" ? { body: "private-password" } : {}),
      }));
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ error: { code: "gateway_not_configured", message: "Gateway configuration is incomplete." } });
    }
  });
  it("uses the platform's default publishable key without service-role credentials", () => {
    const edge = loadEdgeConfig({ SUPABASE_URL: config.supabaseUrl, PADELID_GATEWAY_SECRET: config.gatewaySecret,
      SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: "sb_publishable_platform" }), SUPABASE_SERVICE_ROLE_KEY: "privileged-never-used" });
    expect(edge.supabaseKey).toBe("sb_publishable_platform");
  });
  it("supports legacy platform anon keys and an explicit nonreserved override", () => {
    const env = { SUPABASE_URL: config.supabaseUrl, PADELID_GATEWAY_SECRET: config.gatewaySecret, SUPABASE_ANON_KEY: "legacy-anon" };
    expect(loadEdgeConfig(env).supabaseKey).toBe("legacy-anon");
    expect(loadEdgeConfig({ ...env, PADELID_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_override" }).supabaseKey).toBe("sb_publishable_override");
  });
  it("rejects malformed platform key configuration before serving requests", () => {
    expect(() => loadEdgeConfig({ SUPABASE_URL: config.supabaseUrl, PADELID_GATEWAY_SECRET: config.gatewaySecret, SUPABASE_PUBLISHABLE_KEYS: "invalid-json" })).toThrow();
  });
  it.each(["/functions/v1/gateway", "/gateway", ""])("routes public/deep health under %s with the same JSON and security headers", async (prefix) => {
    const h = harness();
    const shallow = await h.request(`${prefix}/v1/health`);
    expect(shallow.status).toBe(200);
    expect(await shallow.json()).toEqual({ status: "ok", commit: config.releaseCommit });
    expect(h.calls).toHaveLength(0);
    expect(shallow.headers.get("cache-control")).toBe("no-store");
    expect(shallow.headers.get("x-request-id")).toMatch(/^[0-9a-f-]{36}$/);
    const deep = await h.request(`${prefix}/v1/health?deep=1`);
    expect(await deep.json()).toEqual({ status: "ok", database: "ok", commit: config.releaseCommit });
    expect(h.calls[0]?.body.p_secret).toBe(config.gatewaySecret);
  });

  it("forwards the bearer, idempotency key and mutation body to the same RPC", async () => {
    const h = harness(() => ({ status: 200, body: { id: "message" } }));
    const response = await h.request(`/functions/v1/gateway/v1/conversations/${conversation}/messages`, {
      method: "POST", headers: { authorization: `Bearer ${token}`, "idempotency-key": key, "content-type": "application/json", "x-padelid-build": "3", "x-padelid-gateway": "spoofed" },
      body: JSON.stringify({ body: "Сохранённое сообщение" }),
    });
    expect(response.status).toBe(201);
    expect(h.calls).toHaveLength(1);
    expect(h.calls[0]?.path).toBe("/rest/v1/rpc/send_message");
    expect(h.calls[0]?.headers.get("authorization")).toBe(`Bearer ${token}`);
    expect(h.calls[0]?.body).toMatchObject({ p_conversation: conversation, p_client_id: key, p_body: "Сохранённое сообщение" });
  });

  it("rejects missing bearer before touching the upstream, and preserves the API error envelope", async () => {
    const h = harness();
    const response = await h.request(`/gateway/v1/conversations/${conversation}/messages`);
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: { code: "not_authenticated" } });
    expect(h.calls).toHaveLength(0);
  });

  it("keeps the minimum build gate for a prefixed URL", async () => {
    const h = harness();
    const response = await h.request("/gateway/v1/health", { headers: { "x-padelid-build": "2" } });
    expect(response.status).toBe(426);
    expect(await response.json()).toMatchObject({ error: { code: "client_outdated" } });
  });

  it("does not trust spoofed platform IP headers by default", async () => {
    const h = harness(call => call.path.includes("/rpc/") ? ({ status: 200, body: true }) : ({ status: 400, body: { error_code: "invalid_credentials" } }));
    await h.request("/gateway/v1/auth/login", { method: "POST", headers: {
      "content-type": "application/json", "x-real-ip": "1.1.1.1", "x-vercel-forwarded-for": "2.2.2.2", "x-forwarded-for": "3.3.3.3", "cf-connecting-ip": "4.4.4.4",
    }, body: JSON.stringify({ email: "anna@example.com", password: "testpass1" }) });
    expect(h.calls[0]?.body.p_bucket).toBe("login:ip:unknown");
  });

  it("accepts only a valid single IP from an explicitly trusted ingress", async () => {
    const h = harness(() => ({ status: 200, body: true }), { trustedClientIpHeader: "cf-connecting-ip" });
    for (const value of ["2001:db8::1", "1.2.3.4, 5.6.7.8"]) {
      await h.request("/gateway/v1/auth/refresh", { method: "POST", headers: { "content-type": "application/json", "cf-connecting-ip": value, "x-real-ip": "9.9.9.9" }, body: JSON.stringify({ refresh_token: "r".repeat(40) }) });
    }
    expect(h.calls.filter(call => call.path.endsWith("bff_rate_limit")).map(call => call.body.p_bucket)).toEqual(["refresh:ip:2001:db8::1", "refresh:ip:unknown"]);
  });

  it("does not strip a similar function name or expose other function routes", async () => {
    const h = harness();
    for (const path of ["/functions/v1/gateway-other/v1/health", "/functions/v1/account/signup"]) {
      const response = await h.request(path);
      expect(response.status).toBe(404);
    }
    expect(h.calls).toHaveLength(0);
  });

  it("preserves upstream service-unavailable status through the adapter", async () => {
    const h = harness(() => ({ status: 503, body: { code: "57014" } }));
    const response = await h.request("/gateway/v1/social/feed", { headers: { authorization: `Bearer ${token}` } });
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: { code: "service_unavailable" } });
  });
});
