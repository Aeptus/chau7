import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const sourceScript = fileURLToPath(new URL("../../check-forbidden-files", import.meta.url));

function createRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-forbidden-files-"));
  const scriptsDir = path.join(root, "scripts");
  fs.mkdirSync(scriptsDir);
  const script = path.join(scriptsDir, "check-forbidden-files");
  fs.copyFileSync(sourceScript, script);
  fs.chmodSync(script, 0o755);
  execFileSync("git", ["init", "--quiet", "--initial-branch=main"], { cwd: root });
  return { root, script };
}

function runGuard(root, script, env = process.env) {
  return spawnSync(script, [], { cwd: root, env, encoding: "utf8" });
}

test("forbidden-file guard rejects staged credential paths and honors its documented bypass", () => {
  const { root, script } = createRepo();
  try {
    fs.writeFileSync(path.join(root, "server.pem"), "fixture certificate material\n");
    execFileSync("git", ["add", "--", "server.pem"], { cwd: root });

    const rejected = runGuard(root, script);
    assert.equal(rejected.status, 1);
    const output = `${rejected.stdout}\n${rejected.stderr}`;
    assert.match(output, /Forbidden file staged/);
    assert.match(output, /server\.pem/);

    const bypassed = runGuard(root, script, { ...process.env, CHAU7_SKIP_FORBIDDEN_CHECK: "1" });
    assert.equal(bypassed.status, 0);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("forbidden-file guard rejects staged blobs at five MiB or larger", () => {
  const { root, script } = createRepo();
  try {
    fs.writeFileSync(path.join(root, "large.bin"), Buffer.alloc(5 * 1024 * 1024, 0x61));
    execFileSync("git", ["add", "--", "large.bin"], { cwd: root });

    const rejected = runGuard(root, script);
    assert.equal(rejected.status, 1);
    const output = `${rejected.stdout}\n${rejected.stderr}`;
    assert.match(output, /Oversized file staged/);
    assert.match(output, /large\.bin/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
