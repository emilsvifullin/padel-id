import { Buffer } from "node:buffer";
import { isIP } from "node:net";
import { createEdgeRelay } from "./edge-relay.js";

/**
 * Entry point for Yandex Cloud Functions behind Yandex API Gateway: the
 * ingress for networks where the Vercel hostnames stall. It relays to the
 * production API and holds no database credential.
 */
export interface YandexHttpEvent {
  httpMethod?: string;
  url?: string;
  path?: string;
  params?: Record<string, string | undefined>;
  pathParams?: Record<string, string | undefined>;
  headers?: Record<string, string | undefined>;
  queryStringParameters?: Record<string, string | undefined>;
  multiValueQueryStringParameters?: Record<string, string[] | undefined>;
  /** `identity.sourceIp` on a direct call and payload 1.0, `http.sourceIp` on payload 2.0. */
  requestContext?: { identity?: { sourceIp?: string }; http?: { sourceIp?: string } };
  body?: string;
  isBase64Encoded?: boolean;
}

export interface YandexHttpResult {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  isBase64Encoded: boolean;
}

/** The API path and query of the request, wherever the gateway mounted it. */
function target(event: YandexHttpEvent): string {
  const raw = event.url ?? `/${event.pathParams?.proxy ?? event.params?.proxy ?? event.path ?? ""}`;
  const parsed = new URL(raw, "https://relay.invalid");
  // A direct function URL puts the function id first; nothing else is stripped,
  // so a path that merely contains "/v1/" further in is not turned into an API path.
  const pathname = parsed.pathname.replace(/^\/[a-z0-9]{10,40}(?=\/v1\/)/, "");
  if (event.url !== undefined) return pathname + parsed.search;
  const query = new URLSearchParams();
  const multi = event.multiValueQueryStringParameters ?? {};
  for (const [name, values] of Object.entries(multi)) for (const value of values ?? []) query.append(name, value);
  for (const [name, value] of Object.entries(event.queryStringParameters ?? {})) {
    if (value !== undefined && !(name in multi)) query.append(name, value);
  }
  const search = query.toString();
  return pathname + (search ? `?${search}` : "");
}

export function createYandexHandler(relayKey: string | undefined, fetcher: typeof fetch = fetch) {
  return async (event: YandexHttpEvent): Promise<YandexHttpResult> => {
    // The gateway reports the caller; a client cannot set this field.
    const source = event.requestContext?.identity?.sourceIp ?? event.requestContext?.http?.sourceIp;
    const address = source && isIP(source) ? source : undefined;
    const relay = createEdgeRelay(fetcher, 15_000, relayKey ? { key: relayKey, address: () => address } : undefined);
    const method = (event.httpMethod ?? "GET").toUpperCase();
    const headers = new Headers();
    for (const [name, value] of Object.entries(event.headers ?? {})) {
      if (value !== undefined) headers.set(name, value);
    }
    const hasBody = event.body !== undefined && event.body !== "" && method !== "GET" && method !== "HEAD";
    const body = hasBody ? Buffer.from(event.body!, event.isBase64Encoded ? "base64" : "utf8") : undefined;
    const response = await relay(new Request(new URL(target(event), "https://relay.invalid"), {
      method, headers, ...(body ? { body: new Uint8Array(body) } : {}),
    }));
    const out: Record<string, string> = {};
    response.headers.forEach((value, name) => { out[name] = value; });
    return {
      statusCode: response.status,
      headers: out,
      body: Buffer.from(await response.arrayBuffer()).toString("base64"),
      isBase64Encoded: true,
    };
  };
}

export const handler = createYandexHandler(process.env.PADELID_RELAY_KEY);
