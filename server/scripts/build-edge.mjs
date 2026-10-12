import { readdir, readFile, mkdir, writeFile, rm } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import ts from "typescript";

const server = fileURLToPath(new URL("../", import.meta.url));
const target = resolve(server, "../supabase/functions/gateway/_shared");
const check = spawnSync(process.execPath, [resolve(server, "node_modules/typescript/bin/tsc"), "-p", resolve(server, "tsconfig.json"), "--noEmit"], { stdio: "inherit" });
if (check.status !== 0) process.exit(check.status ?? 1);
await rm(target, { recursive: true, force: true });
await mkdir(target, { recursive: true });
const names = (await readdir(resolve(server, "src"))).filter(name => name.endsWith(".ts") && !["index.ts", "dev-server.ts", "relay-server.ts", "push-provider.ts", "push-worker.ts"].includes(name)).sort();
for (const name of names) {
  const source = await readFile(resolve(server, "src", name), "utf8");
  const result = ts.transpileModule(source, {
    fileName: name,
    compilerOptions: { target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.ESNext, verbatimModuleSyntax: true },
  });
  await writeFile(resolve(target, name.replace(/\.ts$/, ".js")), result.outputText);
}
// Version mappings come from the server manifest, never an independent fork.
const { dependencies } = JSON.parse(await readFile(resolve(server, "package.json"), "utf8"));
await writeFile(resolve(target, "../deno.json"), JSON.stringify({ imports: {
  hono: `npm:hono@${dependencies.hono}`,
  "hono/body-limit": `npm:hono@${dependencies.hono}/body-limit`,
  zod: `npm:zod@${dependencies.zod}`,
} }, null, 2) + "\n");
console.log(`Generated ${names.length} modules for gateway from server/src (no credentials).`);
