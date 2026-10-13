import { gatewayURL } from "./gateway-url.js";

/** Independent public ingress for the existing production API. The shared
 * database secret remains in Vercel; this function never receives it.
 * This mode exposes the deployed API version, not local unreleased RPCs.
 */
export const EXISTING_API_ORIGIN = "https://padel-id-gamma.vercel.app";
const MAX_BYTES = 2 * 1024 * 1024;
const REQUEST_HEADERS = ["authorization", "content-type", "accept", "idempotency-key", "x-padelid-build"];

async function boundedBody(stream: ReadableStream<Uint8Array> | null, signal: AbortSignal): Promise<Uint8Array<ArrayBuffer> | undefined> {
  signal.throwIfAborted();
  if (!stream) return undefined;
  const reader = stream.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", cancel, { once: true });
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      signal.throwIfAborted();
      const { done, value } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_BYTES) { await reader.cancel(); throw new Error("body_too_large"); }
      chunks.push(value);
    }
  } finally {
    signal.removeEventListener("abort", cancel);
    reader.releaseLock();
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}

export interface RelayIdentity {
  /** The key configured on the API as PADELID_RELAY_KEY. */
  key: string;
  /** The caller address as the hosting platform reports it, never a client header. */
  address: (request: Request) => string | undefined;
}

/** `identity` lets the API rate-limit by the real caller instead of by this relay. */
export function createEdgeRelay(fetcher: typeof fetch = fetch, deadlineMs = 15_000, identity?: RelayIdentity) {
  return async (request: Request): Promise<Response> => {
    const headers = new Headers({ "cache-control": "no-store", "x-content-type-options": "nosniff",
      "x-request-id": crypto.randomUUID(), "x-padelid-edge-mode": "relay" });
    const failure = (status: number, code: string) => Response.json({ error: { code,
      message: code === "not_found" ? "Адрес не найден." : "Сервис временно недоступен." } }, { status, headers });
    const url = gatewayURL(request);
    if (!url.pathname.startsWith("/v1/") || !["GET", "POST", "PUT", "PATCH", "DELETE"].includes(request.method)) {
      return failure(404, "not_found");
    }
    const target = new URL(url.pathname + url.search, EXISTING_API_ORIGIN);
    const forwarded = new Headers();
    for (const name of REQUEST_HEADERS) {
      const value = request.headers.get(name);
      if (value !== null) forwarded.set(name, value);
    }
    // Client-supplied forwarding/platform headers cannot establish identity.
    // Without `identity` the API sees this relay as the caller and all its
    // users share one address budget.
    const address = identity?.address(request);
    if (identity && address) {
      forwarded.set("x-padelid-relay-key", identity.key);
      forwarded.set("x-padelid-relay-ip", address);
    }
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), deadlineMs);
    try {
      let body: Uint8Array<ArrayBuffer> | undefined;
      try { body = await boundedBody(request.body, controller.signal); }
      catch { return controller.signal.aborted ? failure(503, "service_unavailable") : failure(413, "request_too_large"); }
      // Never replay a mutation, including a timeout after upstream acceptance.
      const upstream = await fetcher(target, { method: request.method, headers: forwarded,
        ...(body ? { body } : {}), redirect: "manual", signal: controller.signal });
      if (upstream.status >= 300 && upstream.status < 400) {
        await upstream.body?.cancel();
        return failure(503, "service_unavailable");
      }
      const data = await boundedBody(upstream.body, controller.signal);
      for (const name of ["content-type", "retry-after"]) {
        const value = upstream.headers.get(name);
        if (value !== null) headers.set(name, value);
      }
      return new Response(upstream.status === 204 ? null : data, { status: upstream.status, headers });
    } catch { return failure(503, "service_unavailable"); }
    finally { clearTimeout(deadline); }
  };
}
