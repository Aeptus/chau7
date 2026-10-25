import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
// The script resolves the repository from its own location, so each fixture
// gets a copy of it inside the temporary repository.
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-antislop-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
  const git = (...args) => execFileSync("git", args, { cwd: root, stdio: "pipe" });
  const write = (file, text) => { fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true }); fs.writeFileSync(path.join(root, file), text); };
  git("init", "-q");
  write("scripts/check-anti-slop", fs.readFileSync(path.join(source, "scripts/check-anti-slop"), "utf8"));
  fs.chmodSync(path.join(root, "scripts/check-anti-slop"), 0o755);
  write("lib/Old.swift", 'let greeting = "done!"\nlet value = cached!\n');
  git("add", "-A");
  git("-c", "user.name=Quality Tests", "-c", "user.email=quality@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture");
  const run = () => spawnSync(path.join(root, "scripts/check-anti-slop"), { cwd: root, encoding: "utf8", env: { ...process.env, CHAU7_SKIP_ANTISLOP: "" } });
  return { git, write, run };
}
test("moving a file does not report its untouched lines", (t) => {
  const f = fixture(t); f.git("mv", "lib/Old.swift", "lib/New.swift");
  const result = f.run(); assert.equal(result.status, 0, result.stderr);
});
test("lines added to a moved file are still checked", (t) => {
  const f = fixture(t); f.git("mv", "lib/Old.swift", "lib/New.swift");
  f.write("lib/New.swift", 'let greeting = "done!"\nlet value = cached!\nlet other = fresh!\n'); f.git("add", "lib/New.swift");
  const result = f.run(); assert.equal(result.status, 1); assert.match(result.stderr, /lib\/New\.swift:3 +\[swift\/force-unwrap\]/);
});
test("many staged renames do not abort the scan", (t) => {
  // Enough rename records to exceed a pipe buffer (64 KiB), as moving a
  // whole app does.
  const f = fixture(t);
  const long = "a-deliberately-long-file-name-segment-for-the-rename-list";
  for (let i = 0; i < 1500; i += 1) f.write(`before/${long}-${i}.txt`, `file ${i}\n`);
  f.git("add", "-A"); f.git("-c", "user.name=Quality Tests", "-c", "user.email=quality@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "many");
  f.git("mv", "before", "after-the-move");
  f.git("mv", "lib/Old.swift", "lib/New.swift");
  const result = f.run(); assert.equal(result.status, 0, `${result.status} ${result.stderr}`);
});
