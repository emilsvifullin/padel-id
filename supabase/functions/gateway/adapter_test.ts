// Run after server build:edge. Exercises the actual generated modules in Deno.
import { createEdgeHandler, createEdgeNetworkProbe } from "./_shared/edge-handler.js";
import { loadConfig } from "./_shared/config.js";
import { Upstream } from "./_shared/upstream.js";

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}

Deno.test("network verification starts without credentials and cannot be selected as a ready API", async () => {
  const handler = createEdgeNetworkProbe("deno-network-check");
  const shallow = await handler(new Request("https://example.supabase.co/gateway/v1/health"));
  assert(shallow.status === 200 && (await shallow.json()).status === "configuration_required", "probe claimed readiness");
  const deep = await handler(new Request("https://example.supabase.co/gateway/v1/health?deep=1"));
  assert(deep.status === 503 && (await deep.json()).database === "not_checked", "probe claimed database success");
  const mutation = await handler(new Request("https://example.supabase.co/gateway/v1/auth/login", { method: "POST", body: "password" }));
  assert(mutation.status === 503 && (await mutation.json()).error.code === "gateway_not_configured", "probe accepted API traffic");
});

Deno.test("generated API executes prefixed health and authenticated mutation in Deno", async () => {
  const config = loadConfig({
    SUPABASE_URL: "https://example.supabase.co", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
    PADELID_GATEWAY_SECRET: "g".repeat(48), PADELID_RELEASE_COMMIT: "deno-smoke",
  });
  const token = "t".repeat(40);
  const key = "22222222-2222-2222-2222-222222222222";
  let count = 0;
  const upstream = new Upstream(config, async (input: RequestInfo | URL, init?: RequestInit) => {
    count++;
    assert(String(input).endsWith("/rpc/send_message"), "wrong upstream route");
    assert(new Headers(init?.headers).get("authorization") === `Bearer ${token}`, "bearer changed");
    const body = JSON.parse(String(init?.body));
    assert(body.p_client_id === key && body.p_body === "Deno test", "idempotency/body changed");
    return Response.json({ id: 1, body: body.p_body });
  });
  const handler = createEdgeHandler(() => ({ config, upstream }));
  const health = await handler(new Request("https://example.supabase.co/functions/v1/gateway/v1/health"));
  assert(health.status === 200 && (await health.json()).commit === "deno-smoke", "health/revision mismatch");
  assert(count === 0, "shallow health contacted upstream");
  const response = await handler(new Request("https://example.supabase.co/functions/v1/gateway/v1/conversations/11111111-1111-1111-1111-111111111111/messages", {
    method: "POST", headers: { authorization: `Bearer ${token}`, "idempotency-key": key, "content-type": "application/json" },
    body: JSON.stringify({ body: "Deno test" }),
  }));
  assert(response.status === 201 && (await response.json()).body === "Deno test", "mutation mismatch");
  assert(Number(count) === 1, "mutation did not execute exactly once");
});

Deno.test("Node crypto hashing and fail-closed IP handling execute in Deno", async () => {
  const config = loadConfig({ SUPABASE_URL: "https://example.supabase.co", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test", PADELID_GATEWAY_SECRET: "g".repeat(48) });
  const buckets: string[] = [];
  const upstream = new Upstream(config, async (input: RequestInfo | URL, init?: RequestInit) => {
    if (String(input).endsWith("/rpc/bff_rate_limit")) {
      const body = JSON.parse(String(init?.body));
      assert(body.p_secret === config.gatewaySecret, "gateway secret omitted");
      buckets.push(body.p_bucket);
      return Response.json(true);
    }
    return Response.json({ error_code: "invalid_credentials" }, { status: 400 });
  });
  const handler = createEdgeHandler(() => ({ config, upstream }));
  await handler(new Request("https://example.supabase.co/gateway/v1/auth/login", {
    method: "POST", headers: { "content-type": "application/json", "x-real-ip": "1.1.1.1" },
    body: JSON.stringify({ email: "anna@example.com", password: "testpass1" }),
  }));
  assert(buckets[0] === "login:ip:unknown", "spoofed IP accepted");
  assert(buckets[2]?.match(/^login:email:[A-Za-z0-9_-]{43}$/), "Node sha256/base64url unavailable");
});

Deno.test("binary avatar request and Node Buffer filename execute in Deno", async () => {
  const config = loadConfig({ SUPABASE_URL: "https://example.supabase.co", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test", PADELID_GATEWAY_SECRET: "g".repeat(48) });
  const player = "11111111-1111-1111-1111-111111111111";
  const bytes = new Uint8Array(100);
  bytes.set([0xff, 0xd8, 0xff]);
  let uploaded = false;
  const upstream = new Upstream(config, async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (url.endsWith("/rpc/me")) return Response.json({ user_id: player, profile: { avatar_path: null } });
    if (url.includes("/storage/v1/object/avatars/")) {
      assert(url.match(new RegExp(`/avatars/${player}/[A-Za-z0-9_-]{24}\\.jpg$`)), "Node Buffer filename mismatch");
      assert(init?.body instanceof Uint8Array && init.body.every((value, index) => bytes[index] === value), "binary body changed");
      uploaded = true;
      return Response.json({});
    }
    assert(url.endsWith("/rpc/set_avatar"), "unexpected avatar upstream route");
    return Response.json({ avatar_path: JSON.parse(String(init?.body)).p_path });
  });
  const handler = createEdgeHandler(() => ({ config, upstream }));
  const response = await handler(new Request("https://example.supabase.co/functions/v1/gateway/v1/me/avatar", {
    method: "PUT", headers: { "content-type": "image/jpeg", authorization: `Bearer ${"t".repeat(40)}` }, body: bytes,
  }));
  assert(response.status === 200 && uploaded, "binary avatar mutation failed");
  await response.json();
});

Deno.test("relay preserves credentials only for the fixed API and refuses redirects", async () => {
  const { createEdgeRelay, EXISTING_API_ORIGIN } = await import("./_shared/edge-relay.js");
  let count = 0;
  const relay = createEdgeRelay(async (input, init) => {
    count++;
    assert(String(input) === EXISTING_API_ORIGIN + "/v1/me", "relay target changed");
    const headers = new Headers(init?.headers);
    assert(headers.get("authorization") === "Bearer opaque-token", "bearer changed");
    assert(!headers.has("x-real-ip") && !headers.has("x-padelid-gateway"), "spoofed headers passed");
    assert(init?.redirect === "manual", "redirects allowed");
    return new Response(null, { status: 307, headers: { location: "https://untrusted.test" } });
  });
  const result = await relay(new Request("https://example.supabase.co/gateway/v1/me", {
    headers: { authorization: "Bearer opaque-token", "x-real-ip": "1.2.3.4", "x-padelid-gateway": "spoof" },
  }));
  assert(count === 1 && result.status === 503, "redirect replayed or accepted");
  assert(!result.headers.has("location"), "redirect target exposed");
});

Deno.test("relay deadline cancels an unfinished body in the actual runtime", async () => {
  const { createEdgeRelay } = await import("./_shared/edge-relay.js");
  let count = 0, cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    start(controller) { controller.enqueue(new Uint8Array([1])); },
    cancel() { cancelled = true; },
  });
  const relay = createEdgeRelay(async () => { count++; return Response.json({}); }, 25);
  const response = await relay(new Request("https://example.supabase.co/gateway/v1/auth/login", { method: "POST", body }));
  assert(response.status === 503 && cancelled && count === 0, "unfinished upload did not expire safely");
});
