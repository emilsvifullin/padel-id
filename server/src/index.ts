// Vercel entrypoint: exports the Hono application as the default export.
import { Hono } from "hono";
import { createApp, type Deps } from "./api.js";
import { loadConfig } from "./config.js";
import { Upstream } from "./upstream.js";

let deps: Deps | undefined;

function resolveDeps(): Deps {
  if (!deps) {
    const config = loadConfig();
    deps = { config, upstream: new Upstream(config) };
  }
  return deps;
}

// The application is a Hono instance (the type annotation also lets the
// platform detect the framework entrypoint).
const app: Hono<{ Variables: { requestId: string } }> = createApp(resolveDeps);

export default app;
