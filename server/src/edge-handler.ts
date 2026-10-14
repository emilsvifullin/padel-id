import { isIP } from "node:net";
import { createApp, type Deps } from "./api.js";
import { gatewayURL } from "./gateway-url.js";
export { gatewayURL } from "./gateway-url.js";

export interface EdgeIngress {
  /** Enable only for an ingress that overwrites this header on every request. */
  trustedClientIpHeader?: "cf-connecting-ip";
}

/** Explicit reachability check while the existing database credential is unavailable.
 * The non-ok status prevents iOS from selecting this endpoint for API traffic.
 * No Auth, Storage or database request is made in this mode.
 */
export function createEdgeNetworkProbe(commit?: string) {
  return async (request: Request): Promise<Response> => {
    const url = gatewayURL(request);
    const health = request.method === "GET" && url.pathname === "/v1/health";
    const deep = url.searchParams.get("deep") === "1";
    const body = health
      ? { status: "configuration_required", mode: "network_verification", ...(deep ? { database: "not_checked" } : {}), ...(commit ? { commit } : {}) }
      : { error: { code: "gateway_not_configured", message: "Gateway configuration is incomplete." } };
    return Response.json(body, {
      status: health && !deep ? 200 : 503,
      headers: { "cache-control": "no-store", "x-content-type-options": "nosniff", "x-request-id": crypto.randomUUID() },
    });
  };
}

/** Same API and upstream services, mounted beneath the Edge Function URL. */
export function createEdgeHandler(resolveDeps: () => Deps, ingress: EdgeIngress = {}) {
  const app = createApp(resolveDeps);
  return async (request: Request): Promise<Response> => {
    const url = gatewayURL(request);
    const headers = new Headers(request.headers);
    const candidate = ingress.trustedClientIpHeader ? headers.get(ingress.trustedClientIpHeader) : null;
    // Neither client-provided platform headers nor a first XFF entry establish
    // client identity. An unverified ingress shares the existing bounded bucket.
    for (const name of ["x-real-ip", "x-forwarded-for", "x-vercel-forwarded-for", "cf-connecting-ip", "x-padelid-gateway"]) {
      headers.delete(name);
    }
    if (candidate && isIP(candidate)) headers.set("x-real-ip", candidate);
    const routed = new Request(url, request);
    return app.fetch(new Request(routed, { headers }));
  };
}
