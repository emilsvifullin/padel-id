/** Normalize supported gateway mounts without importing the application API. */
export function gatewayURL(request: Request): URL {
  const url = new URL(request.url);
  for (const prefix of ["/functions/v1/gateway", "/gateway"]) {
    if (url.pathname === prefix || url.pathname.startsWith(`${prefix}/`)) {
      url.pathname = url.pathname.slice(prefix.length) || "/";
      break;
    }
  }
  return url;
}
