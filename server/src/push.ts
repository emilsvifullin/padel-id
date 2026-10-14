import type { Context, Hono } from "hono";
import { z } from "zod";
import type { Upstream } from "./upstream.js";

type Env = { Variables: { requestId: string } };
interface RouteTools {
  up: () => Upstream;
  bearer: (c: Context<Env>) => string;
  parseJson: <T extends z.ZodType>(c: Context<Env>, schema: T) => Promise<z.infer<T>>;
  pathUuid: (c: Context<Env>, name: string) => string;
}
const registration = z.strictObject({
  // Apple device tokens are opaque variable-length bytes, not assumed to be 32 bytes.
  device_token: z.string().regex(/^[a-fA-F0-9]{2,1024}$/).refine(v => v.length % 2 === 0).transform(v => v.toLowerCase()),
  enabled: z.boolean(),
});
/** Portable client routes; no provider credentials, Node imports or worker routes. */
export function registerPushRoutes(app: Hono<Env>, {up,bearer,parseJson,pathUuid}: RouteTools): void {
  app.put("/v1/me/push-devices/:installation",async c => {
    const token = bearer(c), id = pathUuid(c,"installation"), p = await parseJson(c,registration);
    return c.json(await up().rpc("register_push_device",{p_installation:id,p_token:p.device_token,p_enabled:p.enabled},token));
  });
  app.delete("/v1/me/push-devices/:installation",async c => {
    const token = bearer(c), id = pathUuid(c,"installation");
    return c.json(await up().rpc("revoke_push_device",{p_installation:id},token));
  });
}
