import { createEdgeHandler, createEdgeNetworkProbe } from "./_shared/edge-handler.js";
import { loadEdgeConfig } from "./_shared/edge-config.js";
import { Upstream } from "./_shared/upstream.js";
import { createEdgeRelay } from "./_shared/edge-relay.js";

if (Deno.env.get("PADELID_EDGE_NETWORK_PROBE_ONLY") === "true") {
  Deno.serve(createEdgeNetworkProbe(Deno.env.get("PADELID_RELEASE_COMMIT")));
} else if (Deno.env.get("PADELID_EDGE_RELAY_EXISTING_API") === "true") {
  Deno.serve(createEdgeRelay());
} else {
  const config = loadEdgeConfig(Deno.env.toObject());
  const upstream = new Upstream(config);
  // Default is fail-closed. Do not opt into trusting a header until the deployed
  // ingress has been checked to overwrite even a deliberately spoofed value.
  const ingress = Deno.env.get("PADELID_EDGE_TRUST_CF_CONNECTING_IP") === "true"
    ? { trustedClientIpHeader: "cf-connecting-ip" as const }
    : {};
  Deno.serve(createEdgeHandler(() => ({ config, upstream }), ingress));
}
