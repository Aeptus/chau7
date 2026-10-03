#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync, execFileSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const probe = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd: root, encoding: "utf8" });
const repository = probe.status === 0 && fs.realpathSync(probe.stdout.trim()) === fs.realpathSync(root);
const optional = process.argv.includes("--if-repository");
if (!repository || (optional && process.env.CI)) {
  if (!optional) { process.stderr.write("Hook installation requires the Chau7 repository root (clone or worktree).\n"); process.exit(1); }
  process.stdout.write("Hook prepare skipped: non-repository install or CI; CI gates remain authoritative.\n");
} else {
  for (const hook of ["pre-commit", "pre-push", "post-commit"]) {
    const file = path.join(root, ".husky", hook);
    if (!fs.existsSync(file)) throw new Error(`missing hook file: ${file}`);
    fs.chmodSync(file, 0o755);
  }
  if (process.argv.includes("--check")) {
    const configured = spawnSync("git", ["config", "--get", "core.hooksPath"], { cwd: root, encoding: "utf8" });
    if (configured.stdout.trim() !== ".husky") {
      process.stderr.write("Missing Chau7 hooks. Run pnpm hooks:install.\n"); process.exit(1);
    }
    process.stdout.write("Chau7 hooks verified.\n");
  } else {
    execFileSync("git", ["config", "--local", "core.hooksPath", ".husky"], { cwd: root, stdio: "inherit" });
    process.stdout.write("Git hooks installed: core.hooksPath -> .husky (shared by repository worktrees).\n");
  }
}
