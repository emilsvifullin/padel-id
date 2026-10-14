import { serve } from "@hono/node-server";
import { createEdgeRelay } from "./edge-relay.js";

// Optional direct HTTPS ingress behind the prepared Caddy proxy. No database,
// Apple or gateway credential is required by this verification relay.
const port = Number.parseInt(process.env.PORT ?? "8787", 10);
serve({ fetch: createEdgeRelay(), port }, (info) => {
  console.log(`Padel ID relay listening on port ${info.port}`);
});
