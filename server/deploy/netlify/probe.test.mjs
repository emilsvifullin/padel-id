import { test, afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import networkProbe from './functions/network-probe.mjs';
afterEach(() => mock.restoreAll());
test('only read-only health can leave the probe; arbitrary paths and mutations are rejected', async () => {
  const fetch = mock.method(globalThis, 'fetch', () => { throw new Error('unexpected upstream'); });
  for (const [method, path] of [['GET', '/v1/me'], ['POST', '/v1/health'], ['GET', '/v1/health?target=https://example.org'], ['GET', '/v1/health?deep=0']]) {
    assert.equal((await networkProbe(new Request('https://probe.test' + path, { method }))).status, 404);
  }
  assert.equal(fetch.mock.callCount(), 0);
});
test('fixed upstream health receives no bearer or spoofed identity; probe cannot become an app route', async () => {
  const fetch = mock.method(globalThis, 'fetch', async (input, options) => {
    assert.equal(String(input), 'https://padel-id-gamma.vercel.app/v1/health?deep=1');
    assert.equal(options.method, 'GET'); assert.equal(options.redirect, 'manual');
    for (const name of ['authorization', 'x-real-ip', 'x-forwarded-for', 'cookie']) assert.equal(options.headers.get(name), null);
    return Response.json({ status: 'ok', database: 'ok', commit: 'current-revision' });
  });
  const response = await networkProbe(new Request('https://probe.test/v1/health?deep=1', { headers: { authorization: 'Bearer caller-token', 'x-real-ip': '192.0.2.1', cookie: 'session=caller' } }));
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await response.json(), { status: 'configuration_required', mode: 'network_verification', upstream_status: 'ok', database: 'ok', commit: 'current-revision' });
  assert.equal(fetch.mock.callCount(), 1);
});
test('upstream redirect is never followed', async () => {
  mock.method(globalThis, 'fetch', async () => new Response(null, { status: 302, headers: { location: 'https://example.org' } }));
  assert.equal((await networkProbe(new Request('https://probe.test/v1/health'))).status, 503);
});
test('invalid upstream JSON fails closed', async () => {
  mock.method(globalThis, 'fetch', async () => new Response('<html>invalid</html>'));
  assert.equal((await networkProbe(new Request('https://probe.test/v1/health'))).status, 503);
});
