import { createEdgeRelay } from '../../../dist/edge-relay.js';

// This isolated probe cannot authenticate users, expose profiles or mutate data.
// A non-ok health status also prevents selection by the app's API route chooser.
export default async function networkProbe(request) {
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.pathname !== '/v1/health' ||
      [...url.searchParams].some(([key, value]) => key !== 'deep' || value !== '1')) {
    return Response.json({ error: { code: 'not_found' } }, { status: 404, headers: { 'cache-control': 'no-store' } });
  }
  const response = await createEdgeRelay()(new Request(url, { method: 'GET', headers: { accept: 'application/json' } }));
  if (response.status !== 200) return response;
  try {
    const body = await response.json();
    if (body.status !== 'ok') throw new Error('unhealthy');
    return Response.json({ status: 'configuration_required', mode: 'network_verification',
      upstream_status: body.status, database: body.database ?? 'not_checked', commit: body.commit ?? null },
      { headers: { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' } });
  } catch {
    return Response.json({ error: { code: 'service_unavailable' } }, { status: 503, headers: { 'cache-control': 'no-store' } });
  }
}
export const config = { path: '/v1/health' };
