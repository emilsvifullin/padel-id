import { loadConfig, type Config } from "./config.js";

/** Supabase reserves SUPABASE_* names and supplies plural JSON key dictionaries. */
export function loadEdgeConfig(env: Record<string, string | undefined>): Config {
  let defaultKey: unknown;
  if (env.SUPABASE_PUBLISHABLE_KEYS) {
    const keys = JSON.parse(env.SUPABASE_PUBLISHABLE_KEYS) as Record<string, unknown>;
    defaultKey = keys.default;
  }
  return loadConfig({
    ...env,
    SUPABASE_PUBLISHABLE_KEY: env.PADELID_SUPABASE_PUBLISHABLE_KEY
      ?? (typeof defaultKey === "string" ? defaultKey : undefined)
      ?? env.SUPABASE_ANON_KEY,
  });
}
