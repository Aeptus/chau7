import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import {
  classifyBackendImpact,
  classifyFrontendImpact,
  discoverStagedFiles,
  filterQualityPaths,
  parsePrepushUpdates,
  resolveChangedFilesFromPrepush,
  resolveFallbackBase,
  shouldForceFullPrepush,
} from "../helpers.mjs";

function makeRepo() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-"));
  execFileSync("git", ["init"], { cwd: root, stdio: "ignore" });
  execFileSync("git", ["config", "user.email", "quality@example.test"], { cwd: root });
  execFileSync("git", ["config", "user.name", "Quality Tests"], { cwd: root });
  return root;
}

function commit(root, file, content, message = "commit") {
  const absolute = path.join(root, file);
  fs.mkdirSync(path.dirname(absolute), { recursive: true });
  fs.writeFileSync(absolute, content);
  execFileSync("git", ["add", file], { cwd: root });
  execFileSync("git", ["commit", "-m", message], { cwd: root, stdio: "ignore" });
  return execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
}

test("staged file discovery uses ACMR staged scope and ignores local artifacts", () => {
  const root = makeRepo();
  commit(root, "README.md", "base\n");
  fs.writeFileSync(path.join(root, "Sources.swift"), "let value = 1\n");
  fs.mkdirSync(path.join(root, "node_modules/pkg"), { recursive: true });
  fs.writeFileSync(path.join(root, "node_modules/pkg/index.js"), "ignored\n");
  execFileSync("git", ["add", "Sources.swift"], { cwd: root });

  assert.deepEqual(discoverStagedFiles(root), ["Sources.swift"]);
});

test("pre-push stdin update lines resolve changed files", () => {
  const root = makeRepo();
  const base = commit(root, "a.txt", "a\n", "base");
  const head = commit(root, "b.txt", "b\n", "head");
  const input = `refs/heads/main ${head} refs/heads/main ${base}\n`;

  const resolved = resolveChangedFilesFromPrepush(input, root);
  assert.deepEqual(resolved.files, ["b.txt"]);
  assert.equal(resolved.updates[0].localSha, head);
});

test("fallback diff base resolves HEAD parent when no upstream exists", () => {
  const root = makeRepo();
  const base = commit(root, "a.txt", "a\n", "base");
  commit(root, "b.txt", "b\n", "head");

  assert.equal(resolveFallbackBase(root), base);
});

test("high-impact changes force full pre-push", () => {
  const result = shouldForceFullPrepush({
    changedFiles: ["scripts/quality/runner.mjs", "apps/chau7-macos/Sources/App.swift"],
  });

  assert.equal(result.full, true);
  assert.match(result.reasons[0], /high-impact/);
});

test("normal source changes do not force full pre-push", () => {
  const result = shouldForceFullPrepush({
    changedFiles: ["apps/chau7-macos/Sources/Chau7/AppModel.swift"],
  });

  assert.equal(result.full, false);
});

test("frontend impact graph fans out global config to all frontend apps", () => {
  const impact = classifyFrontendImpact(["services/chau7-relay/tsconfig.json"]);
  assert.deepEqual(impact.apps, ["issues", "relay"]);
  assert.ok(impact.groups.includes("global-frontend-config"));
});

test("backend impact classification detects Go, tests, and dependency files", () => {
  const impact = classifyBackendImpact([
    "apps/chau7-macos/chau7-proxy/router_test.go",
    "services/chau7-remote/go.mod",
  ]);

  assert.deepEqual(impact.groups, ["backend-dependencies", "backend-tests", "go-proxy", "go-remote"]);
});

test("quality path filter removes generated local cache directories", () => {
  assert.deepEqual(filterQualityPaths([".aeptus-cache/quality/x", "services/chau7-relay/src/worker.ts"]), [
    "services/chau7-relay/src/worker.ts",
  ]);
});

test("pre-push parser reads refs and shas without policy decisions", () => {
  assert.deepEqual(parsePrepushUpdates("refs/heads/a abc refs/heads/a def\n"), [
    { localRef: "refs/heads/a", localSha: "abc", remoteRef: "refs/heads/a", remoteSha: "def" },
  ]);
});

