// Each independent full-stack suite receives a fresh shared IP budget.
// Assertions within a suite retain the real production limits. This reset is
// restricted to the disposable local stack; smoke tests never access SQL.
import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import pg from 'pg';
import { fileURLToPath } from 'node:url';
const vitest = fileURLToPath(new URL('../node_modules/vitest/vitest.mjs', import.meta.url));
const run = (files) => spawnSync(process.execPath, [vitest, 'run', ...files], { stdio: 'inherit', env: process.env }).status ?? 1;
const local = host => ['127.0.0.1', 'localhost', '[::1]'].includes(host);
const api = process.env.E2E_API_URL;
if (!api || process.env.E2E_MODE === 'smoke') {
  process.exit(run(['test/e2e']));
}
if (!local(new URL(api).hostname)) throw new Error('Full E2E suites require a disposable local API. Use smoke mode for hosted read-only checks.');
const database = process.env.E2E_DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const address = new URL(database);
if (!local(address.hostname) || address.port !== '54322' || address.pathname !== '/postgres') {
  throw new Error('Full E2E fixture isolation requires the disposable local Supabase database on port 54322.');
}
const db = new pg.Client({ connectionString: database });
await db.connect();
let status = 0;
try {
  const files = (await readdir(new URL('../test/e2e', import.meta.url))).filter(name => name.endsWith('.test.ts')).sort();
  for (const file of files) {
    // Account fixtures share the local ingress address. Cross-file traffic must
    // not consume another suite's budget (including its cleanup requests).
    await db.query("delete from private.rate_limits where bucket like any($1::text[])",
      [['password', 'login', 'signup', 'recover', 'refresh'].map(action => `bff:${action}:ip:%`)]);
    console.log(`Independent local E2E suite: ${file}`);
    const result = run(['test/e2e/' + file]);
    if (result) status = result;
  }
} finally { await db.end(); }
process.exit(status);
