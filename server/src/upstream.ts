import type { Config } from "./config.js";
import { ApiError, apiError, isKnownCode } from "./errors.js";

export type FetchFn = typeof fetch;

export interface Session {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  expires_at: number;
  token_type: string;
  user: { id: string; email: string | null };
}

interface UpstreamResponse {
  status: number;
  body: unknown;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {};
}

/**
 * Typed access to the Supabase services the gateway relies on: PostgREST RPC,
 * Auth (GoTrue), Storage and the privileged account Edge Function.
 */
export class Upstream {
  constructor(
    private readonly config: Config,
    private readonly fetchImpl: FetchFn = fetch,
  ) {}

  private async request(path: string, init: RequestInit & { timeoutMs?: number }): Promise<UpstreamResponse> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.config.supabaseUrl}${path}`, {
        ...init,
        signal: AbortSignal.timeout(init.timeoutMs ?? this.config.upstreamTimeoutMs),
      });
    } catch {
      throw apiError("service_unavailable");
    }
    const text = await response.text();
    let body: unknown = null;
    if (text.length > 0) {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
    return { status: response.status, body };
  }

  private headers(accessToken?: string, extra: Record<string, string> = {}): Record<string, string> {
    return {
      apikey: this.config.supabaseKey,
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
      ...extra,
    };
  }

  /** Calls a PostgREST RPC function as the given user (or anonymously). */
  async rpc<T = unknown>(fn: string, args: Record<string, unknown>, accessToken?: string): Promise<T> {
    const res = await this.request(`/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: this.headers(accessToken, { "content-type": "application/json", accept: "application/json" }),
      body: JSON.stringify(args),
    });
    if (res.status >= 200 && res.status < 300) {
      return res.body as T;
    }
    throw Upstream.mapPostgrestError(res);
  }

  static mapPostgrestError(res: UpstreamResponse): ApiError {
    const body = asRecord(res.body);
    const code = typeof body.code === "string" ? body.code : "";
    const message = typeof body.message === "string" ? body.message : "";
    if (code === "P0001" && isKnownCode(message)) {
      return apiError(message, typeof body.details === "string" && body.details ? body.details : undefined);
    }
    if (code === "P0001" && message === "not_authenticated") {
      return apiError("not_authenticated");
    }
    if (res.status === 401 || code.startsWith("PGRST30")) {
      return apiError("session_expired");
    }
    if (code === "42501") {
      return apiError(res.status === 401 ? "session_expired" : "forbidden");
    }
    if (code === "22P02" || code === "22023" || code === "PGRST202" || code === "PGRST102") {
      return apiError("invalid_request");
    }
    if (res.status === 503 || res.status === 502 || res.status === 504 || code === "57014") {
      return apiError("service_unavailable");
    }
    return apiError("internal", `${res.status} ${code} ${message}`.slice(0, 300));
  }

  private static toSession(body: unknown): Session {
    const b = asRecord(body);
    const user = asRecord(b.user);
    if (typeof b.access_token !== "string" || typeof b.refresh_token !== "string" || typeof user.id !== "string") {
      throw apiError("service_unavailable");
    }
    const expiresIn = typeof b.expires_in === "number" ? b.expires_in : 3600;
    return {
      access_token: b.access_token,
      refresh_token: b.refresh_token,
      expires_in: expiresIn,
      expires_at: typeof b.expires_at === "number" ? b.expires_at : Math.floor(Date.now() / 1000) + expiresIn,
      token_type: "bearer",
      user: { id: user.id, email: typeof user.email === "string" ? user.email : null },
    };
  }

  private static authErrorCode(res: UpstreamResponse): string {
    const b = asRecord(res.body);
    const value = b.error_code ?? b.code ?? b.error;
    return typeof value === "string" ? value : "";
  }

  async passwordGrant(email: string, password: string): Promise<Session> {
    const res = await this.request("/auth/v1/token?grant_type=password", {
      method: "POST",
      headers: this.headers(undefined, { "content-type": "application/json" }),
      body: JSON.stringify({ email, password }),
    });
    if (res.status === 200) return Upstream.toSession(res.body);
    if (res.status === 429) throw apiError("rate_limited");
    if (res.status === 400 || res.status === 401 || res.status === 403 || res.status === 422) {
      throw apiError("invalid_credentials");
    }
    throw apiError("service_unavailable");
  }

  async refreshGrant(refreshToken: string): Promise<Session> {
    const res = await this.request("/auth/v1/token?grant_type=refresh_token", {
      method: "POST",
      headers: this.headers(undefined, { "content-type": "application/json" }),
      body: JSON.stringify({ refresh_token: refreshToken }),
    });
    if (res.status === 200) return Upstream.toSession(res.body);
    if (res.status === 429) throw apiError("rate_limited");
    if (res.status >= 400 && res.status < 500) throw apiError("session_expired");
    throw apiError("service_unavailable");
  }

  async logout(accessToken: string, scope: "local" | "global" | "others"): Promise<void> {
    const res = await this.request(`/auth/v1/logout?scope=${scope}`, {
      method: "POST",
      headers: this.headers(accessToken),
    });
    // 401/403/404: the session is already gone, which is the desired outcome.
    if (res.status >= 500) throw apiError("service_unavailable");
  }

  async updatePassword(accessToken: string, password: string): Promise<void> {
    const res = await this.request("/auth/v1/user", {
      method: "PUT",
      headers: this.headers(accessToken, { "content-type": "application/json" }),
      body: JSON.stringify({ password }),
    });
    if (res.status === 200) return;
    const code = Upstream.authErrorCode(res);
    if (code === "same_password") throw apiError("same_password");
    if (code === "weak_password") throw apiError("weak_password");
    if (res.status === 401 || res.status === 403) throw apiError("session_expired");
    if (res.status === 429) throw apiError("rate_limited");
    throw apiError("service_unavailable");
  }

  /** Invokes the privileged account Edge Function. */
  async account<T = Record<string, unknown>>(action: string, payload: Record<string, unknown>): Promise<T> {
    const res = await this.request("/functions/v1/account", {
      method: "POST",
      headers: this.headers(undefined, {
        "content-type": "application/json",
        "x-padelid-gateway": this.config.gatewaySecret,
      }),
      body: JSON.stringify({ action, ...payload }),
      timeoutMs: 20000,
    });
    if (res.status === 200) return res.body as T;
    const err = asRecord(asRecord(res.body).error);
    const code = typeof err.code === "string" ? err.code : "";
    if (isKnownCode(code)) throw apiError(code);
    throw apiError("service_unavailable", `account ${res.status}`);
  }

  async uploadAvatar(accessToken: string, path: string, bytes: Uint8Array<ArrayBuffer>): Promise<void> {
    const res = await this.request(`/storage/v1/object/avatars/${path}`, {
      method: "POST",
      headers: this.headers(accessToken, { "content-type": "image/jpeg", "cache-control": "max-age=31536000" }),
      body: bytes,
      timeoutMs: 20000,
    });
    if (res.status >= 200 && res.status < 300) return;
    if (res.status === 401 || res.status === 403) throw apiError("forbidden");
    if (res.status === 413) throw apiError("payload_too_large");
    if (res.status === 400) throw apiError("invalid_image");
    throw apiError("service_unavailable");
  }

  async deleteAvatars(accessToken: string, paths: string[]): Promise<void> {
    if (paths.length === 0) return;
    await this.request("/storage/v1/object/avatars", {
      method: "DELETE",
      headers: this.headers(accessToken, { "content-type": "application/json" }),
      body: JSON.stringify({ prefixes: paths }),
    });
  }

  /** Streams a public avatar from Storage. */
  async fetchAvatar(path: string): Promise<Response> {
    try {
      return await this.fetchImpl(`${this.config.supabaseUrl}/storage/v1/object/public/avatars/${path}`, {
        signal: AbortSignal.timeout(this.config.upstreamTimeoutMs),
      });
    } catch {
      throw apiError("service_unavailable");
    }
  }

  /** Gateway-authenticated rate limit check; fails open if the database is unreachable. */
  async rateLimit(bucket: string, limit: number, windowSeconds: number): Promise<boolean> {
    try {
      const allowed = await this.rpc<boolean>("bff_rate_limit", {
        p_secret: this.config.gatewaySecret,
        p_bucket: bucket,
        p_limit: limit,
        p_window_seconds: windowSeconds,
      });
      return allowed !== false;
    } catch (e) {
      if (e instanceof ApiError && e.code === "forbidden") throw apiError("service_unavailable", "gateway secret rejected");
      return true;
    }
  }
}
