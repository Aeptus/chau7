import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { runQuality, checkDirtyWorktree } from "../runner.mjs";

function makeRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-runner-"));
  execFileSync("git", ["init"], { cwd: root, stdio: "ignore" });
  execFileSync("git", ["config", "user.email", "quality@example.test"], { cwd: root });
  execFileSync("git", ["config", "user.name", "Quality Tests"], { cwd: root });
  fs.writeFileSync(path.join(root, "README.md"), "base\n");
  execFileSync("git", ["add", "README.md"], { cwd: root });
  execFileSync("git", ["commit", "-m", "base"], { cwd: root, stdio: "ignore" });
  return root;
}

test("include filter runs only the requested gate", async () => {
  const summary = await runQuality(["--mode=staged", "--include=quality-registry-schema"], "");
  assert.equal(summary.ok, true);
  assert.deepEqual(summary.selected, ["quality-registry-schema"]);
});

test("skip filter removes a gate", async () => {
  const summary = await runQuality(
    ["--mode=staged", "--include=quality-registry-schema", "--skip=quality-registry-schema"],
    "",
  );
  assert.equal(summary.ok, true);
  assert.deepEqual(summary.selected, []);
});

test("tag and wave filters select deterministic registry gates", async () => {
  const summary = await runQuality(["--mode=staged", "--tags=registry", "--wave=preflight"], "");
  assert.equal(summary.ok, true);
  assert.deepEqual(summary.selected, ["quality-registry-schema"]);
});

test("JSON CLI output is valid", () => {
  const result = spawnSync(
    process.execPath,
    ["scripts/quality/runner.mjs", "--mode=staged", "--include=quality-registry-schema", "--json"],
    { cwd: process.cwd(), encoding: "utf8" },
  );
  assert.equal(result.status, 0, result.stderr);
  const parsed = JSON.parse(result.stdout);
  assert.equal(parsed.ok, true);
});

test("runner result metadata exposes rerun commands", async () => {
  const summary = await runQuality(
    ["--mode=staged", "--include=quality-registry-schema"],
    "",
  );
  assert.equal(summary.ok, true);
  assert.equal(summary.results[0].rerun, "pnpm quality:local --include=quality-registry-schema");
});

test("dirty worktree fails closed in non-interactive pre-push behavior", async () => {
  const root = makeRepo();
  fs.writeFileSync(path.join(root, "README.md"), "dirty\n");
  const result = await checkDirtyWorktree(root, { interactive: false });
  assert.equal(result.status, "failed");
  assert.match(result.summary, /dirty worktree/);
});

test("dirty worktree can be explicitly acknowledged by env", async () => {
  const root = makeRepo();
  fs.writeFileSync(path.join(root, "README.md"), "dirty\n");
  const old = process.env.AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM;
  try {
    process.env.AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM = "1";
    const result = await checkDirtyWorktree(root, { interactive: false });
    assert.equal(result.status, "passed");
  } finally {
    if (old === undefined) delete process.env.AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM;
    else process.env.AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM = old;
  }
});
