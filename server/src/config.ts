export interface Config {
  /** Base URL of the Supabase project, e.g. https://<ref>.supabase.co */
  supabaseUrl: string;
  /** Publishable (anon) key. Not a secret, but kept server-side so the client never talks to Supabase. */
  supabaseKey: string;
  /** Shared secret authenticating this gateway to the database and the account service. */
  gatewaySecret: string;
  /** Oldest iOS build number still supported (requests from older builds get 426). */
  minClientBuild: number;
  /** Upstream request timeout in milliseconds. */
  upstreamTimeoutMs: number;
  /** Account registrations allowed per client IP per hour. */
  signupsPerHour: number;
}

export function loadConfig(env: Record<string, string | undefined> = process.env): Config {
  const supabaseUrl = env.SUPABASE_URL?.replace(/\/+$/, "");
  const supabaseKey = env.SUPABASE_PUBLISHABLE_KEY;
  const gatewaySecret = env.PADELID_GATEWAY_SECRET;
  if (!supabaseUrl || !supabaseKey || !gatewaySecret) {
    throw new Error("Missing required configuration: SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, PADELID_GATEWAY_SECRET");
  }
  if (gatewaySecret.length < 32) {
    throw new Error("PADELID_GATEWAY_SECRET must be at least 32 characters");
  }
  return {
    supabaseUrl,
    supabaseKey,
    gatewaySecret,
    minClientBuild: Number.parseInt(env.PADELID_MIN_CLIENT_BUILD ?? "1", 10) || 1,
    upstreamTimeoutMs: Number.parseInt(env.PADELID_UPSTREAM_TIMEOUT_MS ?? "12000", 10) || 12000,
    signupsPerHour: Number.parseInt(env.PADELID_SIGNUPS_PER_HOUR ?? "5", 10) || 5,
  };
}
