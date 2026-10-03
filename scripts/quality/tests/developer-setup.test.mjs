import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-setup-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (file, body) => { fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true }); fs.writeFileSync(path.join(root, file), body); };
  const git = (...args) => execFileSync("git", args, { cwd: root, stdio: "pipe" });
  write("scripts/git/install-hooks.mjs", fs.readFileSync(path.join(source, "scripts/git/install-hooks.mjs")));
  for (const hook of ["pre-commit", "pre-push", "post-commit"]) write(`.husky/${hook}`, "#!/bin/sh\nexit 1\n");
  const run = (...args) => spawnSync(process.execPath, [path.join(root, "scripts/git/install-hooks.mjs"), ...args], { cwd: root, encoding: "utf8", env: { ...process.env, CI: "" } });
  return { root, write, git, run };
}
test("prepare skips copied package outside its own Git root", (t) => {
  const f = fixture(t); assert.equal(f.run("--if-repository").status, 0); assert.equal(f.run().status, 1);
});
test("clone hooks install, check missing configuration, reject an invalid commit and share across worktrees", (t) => {
  const f = fixture(t); f.git("init", "-q"); assert.equal(f.run("--check").status, 1); assert.equal(f.run().status, 0); assert.equal(f.run("--check").status, 0);
  f.write("file", "fixture\n"); f.git("add", "file", ".husky", "scripts");
  const invalid = spawnSync("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "invalid"], { cwd: f.root }); assert.notEqual(invalid.status, 0);
  f.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture");
  const worktree = path.join(f.root, "worktree"); f.git("worktree", "add", "-qb", "other", worktree);
  const result = spawnSync(process.execPath, [path.join(worktree, "scripts/git/install-hooks.mjs"), "--check"], { cwd: worktree, encoding: "utf8" }); assert.equal(result.status, 0, result.stderr);
});
test("compatibility post-commit delegates maintenance", (t) => {
  const f = fixture(t); const bin = path.join(f.root, "bin"); fs.mkdirSync(bin); const log = path.join(f.root, "log");
  fs.writeFileSync(path.join(bin, "pnpm"), '#!/bin/sh\nprintf "%s\\n" "$*" > "$HOOK_TEST_LOG"\n', { mode: 0o755 });
  const result = spawnSync("/bin/sh", [path.join(source, "tools/git-hooks/post-commit")], { env: { ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`, HOOK_TEST_LOG: log } }); assert.equal(result.status, 0); assert.match(fs.readFileSync(log, "utf8"), /quality:postcommit/);
});
test("source packaging rejects missing terminal backend before bundle creation or compiler invocation", (t) => {
  const f = fixture(t); const app = "apps/chau7-macos";
  for (const file of ["build-app.sh", "logging.sh", "signing.sh"]) f.write(`${app}/Scripts/${file}`, fs.readFileSync(path.join(source, app, "Scripts", file)));
  f.write(`${app}/.build/release/Chau7`, "synthetic binary\n");
  const result = spawnSync("/bin/bash", [path.join(f.root, app, "Scripts/build-app.sh")], { encoding: "utf8", env: { ...process.env, CHAU7_LOG_COLOR: "0" } });
  assert.equal(result.status, 1); assert.match(result.stdout + result.stderr, /Required terminal emulator missing/); assert.match(result.stdout + result.stderr, /build-rust.sh --release/); assert.equal(fs.existsSync(path.join(f.root, app, "build/Chau7.app")), false);
});
