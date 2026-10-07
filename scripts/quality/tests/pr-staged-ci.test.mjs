import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const workflow = fs.readFileSync(path.join(source, ".github/workflows/ci.yml"), "utf8");
function step(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert.notEqual(start, -1);
  const end = workflow.indexOf("\n      - name:", start + 1);
  const block = workflow.slice(start, end < 0 ? undefined : end);
  const inline = block.match(/^        run: (?!\|)(.+)$/m);
  if (inline) return inline[1];
  const body = block.split("        run: |\n")[1];
  assert.ok(body);
  return body.split("\n").filter((line) => line.startsWith("          ")).map((line) => line.slice(10)).join("\n");
}
function fixture(t, changelog) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-pr-staged-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: "pipe" }).trim();
  const write = (file, content) => {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), content);
  };
  const commit = () => {
    git("add", ".");
    git("-c", "user.name=Quality Tests", "-c", "user.email=quality@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture");
  };
  git("init", "-q");
  const docs = "apps/chau7-macos/docs";
  const app = "apps/chau7-macos/Sources/Chau7/Fix.swift";
  for (const file of ["features.json", "features.csv"]) write(`${docs}/${file}`, fs.readFileSync(path.join(source, docs, file)));
  write("scripts/generate-features-csv.mjs", fs.readFileSync(path.join(source, "scripts/generate-features-csv.mjs")));
  write(`${docs}/CHANGELOG.md`, "Existing notes\n");
  write(app, "// original\n");
  commit();
  const base = git("rev-parse", "HEAD");
  write(app, "// bug fixed\n");
  if (changelog) write(`${docs}/CHANGELOG.md`, "Fixed the bug.\n");
  commit();
  const head = git("rev-parse", "HEAD");
  const tree = git("rev-parse", "HEAD^{tree}");
  write("test-bin/pnpm", `#!/bin/sh\ngit diff --cached --name-only > selected.txt\nif [ "\${TEST_REWRITE:-}" = 1 ]; then\n  echo '// rewritten' >> '${app}'\n  git add '${app}'\n  exit 0\nfi\nexec "$TEST_NODE" "$TEST_DOC_CHECK" "$PWD"\n`);
  fs.chmodSync(path.join(root, "test-bin/pnpm"), 0o755);
  const env = {
    ...process.env,
    BASE_SHA: base,
    GITHUB_ENV: path.join(root, "ci-env"),
    PATH: `${path.join(root, "test-bin")}${path.delimiter}${process.env.PATH}`,
    TEST_NODE: process.execPath,
    TEST_DOC_CHECK: path.join(source, "scripts/git/check-docs-staged.mjs"),
    CHAU7_SKIP_DOC_CHECK: "",
  };
  const run = (name) => spawnSync("bash", ["-e", "-c", step(name)], { cwd: root, encoding: "utf8", env });
  const pipeline = () => {
    const staged = run("Stage the pull request diff for staged gates");
    assert.equal(staged.status, 0, staged.stderr);
    assert.equal(git("rev-parse", "HEAD"), base);
    assert.equal(git("write-tree"), tree);
    for (const line of fs.readFileSync(env.GITHUB_ENV, "utf8").trim().split("\n")) {
      const separator = line.indexOf("=");
      env[line.slice(0, separator)] = line.slice(separator + 1);
    }
    const checked = run("Run staged quality gates");
    const verified = checked.status === 0 ? run("Verify staged gates did not rewrite the pull request") : null;
    const restored = run("Restore the checked-out commit after staged gates");
    assert.equal(restored.status, 0, restored.stderr);
    assert.equal(git("rev-parse", "HEAD"), head);
    return { checked, verified, selected: fs.readFileSync(path.join(root, "selected.txt"), "utf8") };
  };
  return { pipeline, env, git, tree, app };
}
test("PR staged checks reject committed app changes without a changelog", (t) => {
  const f = fixture(t, false);
  const result = f.pipeline();
  assert.equal(result.checked.status, 1);
  assert.match(result.checked.stderr, /CHANGELOG/);
  assert.ok(result.selected.includes(f.app));
  assert.equal(f.git("write-tree"), f.tree);
});
test("PR staged checks accept an accurate snapshot and restore the original commit", (t) => {
  const f = fixture(t, true);
  const result = f.pipeline();
  assert.equal(result.checked.status, 0, result.checked.stderr);
  assert.equal(result.verified.status, 0, result.verified.stderr);
  assert.ok(result.selected.includes(f.app));
  assert.equal(f.git("write-tree"), f.tree);
});
test("PR CI rejects gate rewrites while still restoring the original commit", (t) => {
  const f = fixture(t, true);
  f.env.TEST_REWRITE = "1";
  const result = f.pipeline();
  assert.equal(result.checked.status, 0);
  assert.equal(result.verified.status, 1);
  assert.match(result.verified.stderr, /rewrote the pull request/);
  assert.notEqual(f.git("write-tree"), f.tree);
  assert.match(workflow, /if: always\(\) && env\.CHAU7_CI_HEAD != ''/);
});
