import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { acceptedAttestation, buildCacheKey, cacheDisabled, writeAttestation } from "../cache.mjs";

function makeRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-cache-"));
  execFileSync("git", ["init"], { cwd: root, stdio: "ignore" });
  execFileSync("git", ["config", "user.email", "quality@example.test"], { cwd: root });
  execFileSync("git", ["config", "user.name", "Quality Tests"], { cwd: root });
  fs.mkdirSync(path.join(root, "scripts/quality"), { recursive: true });
  for (const file of ["runner.mjs", "registry.mjs", "cache.mjs", "helpers.mjs"]) {
    fs.writeFileSync(path.join(root, "scripts/quality", file), `${file}\n`);
  }
  fs.writeFileSync(path.join(root, "config.json"), "{}\n");
  fs.writeFileSync(path.join(root, "input.txt"), "one\n");
  execFileSync("git", ["add", "."], { cwd: root });
  execFileSync("git", ["commit", "-m", "base"], { cwd: root, stdio: "ignore" });
  return root;
}

function context(root) {
  return {
    root,
    mode: "prepush",
    full: false,
    changedFiles: ["input.txt"],
  };
}

const gate = {
  id: "cache-test",
  scope: "changed",
  cacheable: true,
  inputs: ["config.json"],
};

test("cache key changes when registry code changes", () => {
  const root = makeRepo();
  const before = buildCacheKey(gate, context(root));
  fs.writeFileSync(path.join(root, "scripts/quality/registry.mjs"), "changed\n");
  const after = buildCacheKey(gate, context(root));
  assert.notEqual(before, after);
});

test("cache key changes when config input changes", () => {
  const root = makeRepo();
  const before = buildCacheKey(gate, context(root));
  fs.writeFileSync(path.join(root, "config.json"), "{\"changed\":true}\n");
  const after = buildCacheKey(gate, context(root));
  assert.notEqual(before, after);
});

test("cache key changes when untracked files appear in declared input directories", () => {
  const root = makeRepo();
  const dirGate = { ...gate, inputs: ["inputs"] };
  fs.mkdirSync(path.join(root, "inputs"));
  fs.writeFileSync(path.join(root, "inputs/tracked.txt"), "tracked\n");
  execFileSync("git", ["add", "inputs/tracked.txt"], { cwd: root });
  execFileSync("git", ["commit", "-m", "inputs"], { cwd: root, stdio: "ignore" });

  const before = buildCacheKey(dirGate, context(root));
  fs.writeFileSync(path.join(root, "inputs/untracked.txt"), "untracked\n");
  const after = buildCacheKey(dirGate, context(root));
  assert.notEqual(before, after);
});

test("cache disabled honors canonical and backward-compatible env vars", () => {
  const oldQuality = process.env.AEPTUS_QUALITY_DISABLE_CACHE;
  const oldPrepush = process.env.AEPTUS_PREPUSH_DISABLE_CACHE;
  try {
    delete process.env.AEPTUS_QUALITY_DISABLE_CACHE;
    delete process.env.AEPTUS_PREPUSH_DISABLE_CACHE;
    assert.equal(cacheDisabled(), false);
    process.env.AEPTUS_QUALITY_DISABLE_CACHE = "1";
    assert.equal(cacheDisabled(), true);
    delete process.env.AEPTUS_QUALITY_DISABLE_CACHE;
    process.env.AEPTUS_PREPUSH_DISABLE_CACHE = "1";
    assert.equal(cacheDisabled(), true);
  } finally {
    if (oldQuality === undefined) delete process.env.AEPTUS_QUALITY_DISABLE_CACHE;
    else process.env.AEPTUS_QUALITY_DISABLE_CACHE = oldQuality;
    if (oldPrepush === undefined) delete process.env.AEPTUS_PREPUSH_DISABLE_CACHE;
    else process.env.AEPTUS_PREPUSH_DISABLE_CACHE = oldPrepush;
  }
});

test("attestation acceptance and rejection depend on matching fingerprints", () => {
  const root = makeRepo();
  const ctx = {
    root,
    mode: "prepush-full",
    headSha: "head",
    repositoryFingerprint: "repo",
    registryFingerprint: "registry",
    runnerFingerprint: "runner",
    lockfileFingerprint: "locks",
  };
  const gate = { id: "expensive-gate", attestableBy: ["order66-full-rebuild-all"] };

  writeAttestation("order66-full-rebuild-all", ctx, ["expensive-gate"]);
  assert.equal(acceptedAttestation(gate, ctx)?.name, "order66-full-rebuild-all");
  assert.equal(acceptedAttestation(gate, { ...ctx, registryFingerprint: "changed" }), null);
});
