// Local runner used by the CI end-to-end suite (Node + @hono/node-server).
import { serve } from "@hono/node-server";
import app from "./index.js";

const port = Number.parseInt(process.env.PORT ?? "8787", 10);
serve({ fetch: app.fetch, port }, (info) => {
  console.log(`Padel ID API listening on http://localhost:${info.port}`);
});
