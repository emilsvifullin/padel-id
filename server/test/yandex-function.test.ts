import { describe, expect, it } from "vitest";
import { createYandexHandler } from "../src/yandex-function.js";
import { EXISTING_API_ORIGIN } from "../src/edge-relay.js";

function upstream(reply: () => Response = () => Response.json({ status: "ok" })) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), init });
    return reply();
  }) as typeof fetch;
  return { calls, fetcher };
}
const decode = (body: string) => Buffer.from(body, "base64").toString("utf8");

describe("Yandex Cloud ingress", () => {
  it("relays an API Gateway request with its path, repeated query values and body, and reports the caller under the key", async () => {
    const up = upstream(() => Response.json({ id: "canonical" }, { status: 201 }));
    const handler = createYandexHandler("k".repeat(40), up.fetcher);
    const payload = JSON.stringify({ body: "Привет" });
    const result = await handler({
      httpMethod: "POST", path: "/{proxy+}", pathParams: { proxy: "v1/conversations/id/messages" },
      multiValueQueryStringParameters: { tag: ["a", "b"] }, queryStringParameters: { tag: "b", offset: "30" },
      headers: { Authorization: "Bearer opaque-token", "Content-Type": "application/json", "Idempotency-Key": "same-key",
        "X-Forwarded-For": "9.9.9.9", "x-padelid-relay-ip": "9.9.9.9", "x-padelid-relay-key": "guess" },
      requestContext: { identity: { sourceIp: "203.0.113.7" } },
      body: Buffer.from(payload).toString("base64"), isBase64Encoded: true,
    });
    expect(up.calls).toHaveLength(1);
    expect(up.calls[0]!.url).toBe(EXISTING_API_ORIGIN + "/v1/conversations/id/messages?tag=a&tag=b&offset=30");
    const sent = new Headers(up.calls[0]!.init?.headers);
    expect(sent.get("authorization")).toBe("Bearer opaque-token");
    expect(sent.get("idempotency-key")).toBe("same-key");
    expect(sent.get("x-padelid-relay-ip")).toBe("203.0.113.7");
    expect(sent.get("x-padelid-relay-key")).toBe("k".repeat(40));
    expect(sent.get("x-forwarded-for")).toBeNull();
    expect(new TextDecoder().decode(up.calls[0]!.init?.body as Uint8Array)).toBe(payload);
    expect(result.statusCode).toBe(201);
    expect(result.isBase64Encoded).toBe(true);
    expect(JSON.parse(decode(result.body))).toEqual({ id: "canonical" });
    expect(result.headers["cache-control"]).toBe("no-store");
  });

  it("accepts a direct function URL, where the path follows the function id", async () => {
    const up = upstream();
    const result = await createYandexHandler(undefined, up.fetcher)({
      httpMethod: "GET", url: "/d4e000000000000000/v1/health?deep=1", headers: {},
      requestContext: { identity: { sourceIp: "203.0.113.7" } },
    });
    expect(up.calls[0]!.url).toBe(EXISTING_API_ORIGIN + "/v1/health?deep=1");
    // Without a configured key the relay makes no claim about the caller.
    expect(new Headers(up.calls[0]!.init?.headers).get("x-padelid-relay-ip")).toBeNull();
    expect(result.statusCode).toBe(200);
  });

  it("returns binary responses intact and refuses anything outside the API", async () => {
    const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9]);
    const up = upstream(() => new Response(jpeg, { headers: { "content-type": "image/jpeg" } }));
    const handler = createYandexHandler("k".repeat(40), up.fetcher);
    const avatar = await handler({ httpMethod: "GET", path: "/{proxy+}", pathParams: { proxy: "v1/avatars/owner/file.jpg" }, headers: {} });
    expect([...Buffer.from(avatar.body, "base64")]).toEqual([...jpeg]);
    expect(avatar.headers["content-type"]).toBe("image/jpeg");
    for (const proxy of ["", "admin", "rest/v1/profiles"]) {
      const result = await handler({ httpMethod: "GET", path: "/{proxy+}", pathParams: { proxy }, headers: {} });
      expect(result.statusCode).toBe(404);
    }
    expect(up.calls).toHaveLength(1);
  });

  it("does not pass on a caller address that is not an address", async () => {
    const up = upstream();
    await createYandexHandler("k".repeat(40), up.fetcher)({
      httpMethod: "GET", url: "/v1/me", headers: {}, requestContext: { identity: { sourceIp: "not-an-address" } },
    });
    const sent = new Headers(up.calls[0]!.init?.headers);
    expect(sent.get("x-padelid-relay-ip")).toBeNull();
    expect(sent.get("x-padelid-relay-key")).toBeNull();
  });
});
