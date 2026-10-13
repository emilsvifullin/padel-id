// Packages the relay for Yandex Cloud Functions: three modules, no
// dependencies and no credentials. Output: deploy/yandex/build/function.zip
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";
import ts from "typescript";

const server = fileURLToPath(new URL("../", import.meta.url));
const out = resolve(server, "deploy/yandex/build");
const check = spawnSync(process.execPath, [resolve(server, "node_modules/typescript/bin/tsc"), "-p", resolve(server, "tsconfig.json"), "--noEmit"], { stdio: "inherit" });
if (check.status !== 0) process.exit(check.status ?? 1);
await rm(out, { recursive: true, force: true });
await mkdir(out, { recursive: true });
const names = ["yandex-function.ts", "edge-relay.ts", "gateway-url.ts"];
for (const name of names) {
  const source = await readFile(resolve(server, "src", name), "utf8");
  const result = ts.transpileModule(source, {
    fileName: name,
    compilerOptions: { target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.ESNext, verbatimModuleSyntax: true },
  });
  await writeFile(resolve(out, name.replace(/\.ts$/, ".js")), result.outputText);
}
await writeFile(resolve(out, "package.json"), JSON.stringify({ name: "padel-id-ingress", private: true, type: "module" }, null, 2) + "\n");
const zip = spawnSync("zip", ["-q", "-X", "function.zip", "package.json", ...names.map(name => name.replace(/\.ts$/, ".js"))], { cwd: out, stdio: "inherit" });
if (zip.status !== 0) process.exit(zip.status ?? 1);
console.log(`Packaged ${names.length} modules into deploy/yandex/build/function.zip (entry point: yandex-function.handler).`);
