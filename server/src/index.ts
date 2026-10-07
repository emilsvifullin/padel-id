import { createApp, type Deps } from "./app.js";
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

const app = createApp(resolveDeps);

export default app;
