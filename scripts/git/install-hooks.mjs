#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { repoRoot } from "../quality/helpers.mjs";

const root = repoRoot();
const hooksDir = path.join(root, ".husky");

for (const hook of ["pre-commit", "pre-push", "post-commit"]) {
  const file = path.join(hooksDir, hook);
  if (!fs.existsSync(file)) {
    throw new Error(`missing hook file: ${file}`);
  }
  fs.chmodSync(file, 0o755);
}

execFileSync("git", ["config", "core.hooksPath", ".husky"], { cwd: root, stdio: "inherit" });
process.stdout.write("Git hooks installed: core.hooksPath -> .husky\n");
