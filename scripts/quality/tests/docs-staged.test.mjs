import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const docs = "apps/chau7-macos/docs";
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-docs-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const git = (...args) => execFileSync("git", args, { cwd: root, stdio: "pipe" });
  git("init", "-q");
  const write = (file, text) => { fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true }); fs.writeFileSync(path.join(root, file), text); };
  for (const file of ["features.json", "features.csv"]) write(`${docs}/${file}`, fs.readFileSync(path.join(source, docs, file)));
  write("scripts/generate-features-csv.mjs", fs.readFileSync(path.join(source, "scripts/generate-features-csv.mjs")));
  write(`${docs}/CHANGELOG.md`, "Existing notes\n");
  git("add", docs, "scripts/generate-features-csv.mjs");
  git("-c", "user.name=Quality Tests", "-c", "user.email=quality@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture");
  const run = () => spawnSync(process.execPath, [path.join(source, "scripts/git/check-docs-staged.mjs"), root], { encoding: "utf8", env: { ...process.env, CHAU7_SKIP_DOC_CHECK: "" } });
  return { root, git, write, run };
}
test("tooling changes need no artificial feature or changelog edits", (t) => {
  const f = fixture(t); f.write("scripts/tool.mjs", "export const value = 1;\n"); f.git("add", "scripts/tool.mjs"); assert.equal(f.run().status, 0);
});
test("bugfix needs accurate changelog but unchanged feature inventory is valid", (t) => {
  const f = fixture(t); f.write("apps/chau7-macos/Sources/Chau7/Fix.swift", "// fixed\n"); f.git("add", "apps/chau7-macos/Sources/Chau7/Fix.swift"); assert.equal(f.run().status, 1);
  f.write(`${docs}/CHANGELOG.md`, "Fixed terminal hang.\n"); f.git("add", `${docs}/CHANGELOG.md`); assert.equal(f.run().status, 0);
});
test("stale staged CSV fails even when unstaged working tree is repaired", (t) => {
  const f = fixture(t); const file = `${docs}/features.csv`; const original = fs.readFileSync(path.join(f.root, file)); f.write(file, "stale\n"); f.git("add", file); f.write(file, original); assert.equal(f.run().status, 1);
});
test("reviewable exemption must explain and cover each changed implementation", (t) => {
  const f = fixture(t); const file = "services/example/main.go"; f.write(file, "package main\n"); f.git("add", file);
  f.write(".chau7/docs-exemption.json", JSON.stringify({ reason: "Internal cleanup preserves all product behavior", paths: [] })); f.git("add", ".chau7/docs-exemption.json"); assert.equal(f.run().status, 1);
  f.write(".chau7/docs-exemption.json", JSON.stringify({ reason: "Internal cleanup preserves all product behavior", paths: [file] })); f.git("add", ".chau7/docs-exemption.json"); assert.equal(f.run().status, 0);
});
test("document hygiene inspects staged contents", (t) => {
  const f = fixture(t); f.write("README.md", `[bad](${["", "Users", "person", "file"].join("/")})\n`); f.git("add", "README.md"); f.write("README.md", "repaired but unstaged\n"); assert.equal(f.run().status, 1);
});
