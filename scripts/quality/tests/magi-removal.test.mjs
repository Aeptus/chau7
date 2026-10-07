import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
test("the native package and shipped skills no longer expose MAGI", () => {
  const manifest = JSON.parse(execFileSync("swift", ["package", "dump-package"], { cwd: path.join(root, "apps/chau7-macos"), encoding: "utf8", env: { ...process.env, CHAU7_CORE_TESTS_ONLY: "0" } }));
  assert.equal(manifest.products.some((product) => /magi/i.test(product.name)), false);
  assert.equal(manifest.targets.some((target) => /magi/i.test(target.name)), false);
  for (const file of ["Sources/MagiCLI", "Sources/Chau7Core/Magi", "Resources/Skills/chau7-magi", "Scripts/install-magi-cli.sh"]) assert.equal(fs.existsSync(path.join(root, "apps/chau7-macos", file)), false);
  const mcp = fs.readFileSync(path.join(root, "apps/chau7-macos/Sources/Chau7/MCP/MCPSession.swift"), "utf8");
  assert.doesNotMatch(mcp, /name: "magi[^"\n]*"/i);
});
