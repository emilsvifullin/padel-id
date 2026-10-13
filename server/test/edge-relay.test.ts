import { describe, expect, it } from "vitest";
import { createEdgeRelay, EXISTING_API_ORIGIN } from "../src/edge-relay.js";

describe("existing API relay", () => {
  it("preserves authenticated mutation, idempotency, query and bytes while stripping spoofed platform headers", async () => {
    const calls: { url: string; init?: RequestInit }[] = [];
    const relay = createEdgeRelay(async (input, init) => {
      calls.push({ url: String(input), init });
      return Response.json({ id: "canonical" }, { status: 201, headers: { "set-cookie": "secret=private", "location": "https://elsewhere.test" } });
    });
    const payload = '{"body":"Привет"}';
    const result = await relay(new Request("https://example.supabase.co/functions/v1/gateway/v1/conversations/id/messages?offset=30", {
      method: "POST", body: payload, headers: { authorization: "Bearer opaque-token", "content-type": "application/json",
        "idempotency-key": "same-key", "x-padelid-build": "3", "x-real-ip": "1.2.3.4", "cf-connecting-ip": "1.2.3.4",
        "x-padelid-gateway": "spoof", cookie: "private" },
    }));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(EXISTING_API_ORIGIN + "/v1/conversations/id/messages?offset=30");
    expect(calls[0]!.init?.redirect).toBe("manual");
    const sent = new Headers(calls[0]!.init?.headers);
    expect([...sent.keys()].sort()).toEqual(["authorization", "content-type", "idempotency-key", "x-padelid-build"]);
    expect(sent.get("authorization")).toBe("Bearer opaque-token");
    expect(sent.get("idempotency-key")).toBe("same-key");
    expect(new TextDecoder().decode(calls[0]!.init?.body as Uint8Array)).toBe(payload);
    expect(result.status).toBe(201);
    expect(await result.json()).toEqual({ id: "canonical" });
    expect(result.headers.get("set-cookie")).toBeNull();
    expect(result.headers.get("location")).toBeNull();
    expect(result.headers.get("cache-control")).toBe("no-store");
  });
  it("reports the platform's caller address with the relay key and never forwards a client's own claim", async () => {
    const sent: Headers[] = [];
    const fetcher = async (_input: RequestInfo | URL, init?: RequestInit) => { sent.push(new Headers(init?.headers)); return Response.json({}); };
    const spoof = { "x-padelid-relay-key": "guess", "x-padelid-relay-ip": "9.9.9.9" };
    await createEdgeRelay(fetcher, 1000, { key: "k".repeat(40), address: () => "203.0.113.7" })(
      new Request("https://relay.test/v1/me", { headers: spoof }));
    expect(sent[0]!.get("x-padelid-relay-key")).toBe("k".repeat(40));
    expect(sent[0]!.get("x-padelid-relay-ip")).toBe("203.0.113.7");
    await createEdgeRelay(fetcher, 1000)(new Request("https://relay.test/v1/me", { headers: spoof }));
    await createEdgeRelay(fetcher, 1000, { key: "k".repeat(40), address: () => undefined })(
      new Request("https://relay.test/v1/me", { headers: spoof }));
    for (const headers of sent.slice(1)) {
      expect(headers.get("x-padelid-relay-key")).toBeNull();
      expect(headers.get("x-padelid-relay-ip")).toBeNull();
    }
  });
  it("preserves upstream authorization refusal and empty DELETE response", async () => {
    for (const status of [401, 403, 404, 204]) {
      const relay = createEdgeRelay(async () => new Response(status === 204 ? null : "denied", { status }));
      const result = await relay(new Request("https://example.test/gateway/v1/account", { method: "DELETE" }));
      expect(result.status).toBe(status);
      expect(await result.text()).toBe(status === 204 ? "" : "denied");
    }
  });
  it("rejects redirects and ambiguous transport failures without retrying or exposing upstream details", async () => {
    for (const redirected of [true, false]) {
      let count = 0;
      const relay = createEdgeRelay(async () => {
        count++;
        if (redirected) return new Response(null, { status: 307, headers: { location: "https://secret.test" } });
        throw new Error("private-upstream-detail");
      });
      const result = await relay(new Request("https://example.test/gateway/v1/auth/login", { method: "POST", body: "secret-body" }));
      expect(count).toBe(1);
      expect(result.status).toBe(503);
      expect(await result.json()).toMatchObject({ error: { code: "service_unavailable" } });
    }
  });
  it("rejects non-API paths and oversize bodies before contacting the fixed origin", async () => {
    let count = 0;
    const relay = createEdgeRelay(async () => { count++; return Response.json({}); });
    const invalid = await relay(new Request("https://example.test/gateway/https://attacker.test"));
    expect(invalid.status).toBe(404);
    const huge = await relay(new Request("https://example.test/gateway/v1/me/avatar", { method: "PUT", body: new Uint8Array(2 * 1024 * 1024 + 1) }));
    expect(huge.status).toBe(413);
    expect(count).toBe(0);
  });
  it("limits oversized upstream bodies and preserves the deployed health revision", async () => {
    const health = createEdgeRelay(async () => Response.json({ status: "ok", commit: "deployed-version" }));
    const response = await health(new Request("https://example.test/gateway/v1/health"));
    expect(await response.json()).toEqual({ status: "ok", commit: "deployed-version" });
    expect(response.headers.get("x-padelid-edge-mode")).toBe("relay");
    const oversized = createEdgeRelay(async () => new Response(new Uint8Array(2 * 1024 * 1024 + 1)));
    expect((await oversized(new Request("https://example.test/gateway/v1/me"))).status).toBe(503);
  });
  it("cancels a stalled upload at the absolute deadline before contacting the API", async () => {
    let calls = 0, cancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(new TextEncoder().encode("partial")); },
      cancel() { cancelled = true; },
    });
    const relay = createEdgeRelay(async () => { calls++; return Response.json({}); }, 25);
    const init = { method: "POST", body, duplex: "half" };
    const result = await relay(new Request("https://example.test/v1/auth/login", init));
    expect(result.status).toBe(503);
    expect(await result.json()).toMatchObject({ error: { code: "service_unavailable" } });
    expect(cancelled).toBe(true);
    expect(calls).toBe(0);
  });
  it("cancels a stalled response body without replaying an accepted mutation", async () => {
    let calls = 0, cancelled = false;
    const relay = createEdgeRelay(async () => {
      calls++;
      return new Response(new ReadableStream<Uint8Array>({
        start(controller) { controller.enqueue(new TextEncoder().encode("{\"partial\":")); },
        cancel() { cancelled = true; },
      }), { status: 201 });
    }, 25);
    const result = await relay(new Request("https://example.test/v1/posts", { method: "POST", body: "{}" }));
    expect(result.status).toBe(503);
    expect(cancelled).toBe(true);
    expect(calls).toBe(1);
  });
});
