#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const root = process.argv[2] ?? process.cwd();
const git = (...args) => execFileSync("git", args, { cwd: root, encoding: "utf8" });
const files = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z").split("\0").filter(Boolean);
const read = (file) => git("show", `:${file}`);
const docs = "apps/chau7-macos/docs";
const failures = [];
for (const file of files.filter((file) => file.endsWith(".md"))) {
  const content = read(file);
  if (/\]\(\/(?:Users|home)\//.test(content)) failures.push(`${file}: absolute filesystem link`);
  if (content.includes("github.com/schiste/Chau7")) failures.push(`${file}: stale GitHub URL`);
  if (/\]\([^)]*docs\/remote-control\//.test(content)) failures.push(`${file}: moved documentation link`);
  if (file === "README.md" && content.includes("TODO:")) failures.push(`${file}: public TODO marker`);
}
// Consider user-facing implementation changes. Tooling and test changes do not
// require invented product features; their own documentation remains reviewable.
const behavioral = files.filter((file) =>
  /^(apps|services|tools)\//.test(file) &&
  !/(^|\/)(docs|Tests|tests|test|Scripts|scripts|git-hooks)\//.test(file) &&
  !/(_test\.go|\.(md|csv|json|lock|png|jpg|jpeg|gif|svg|ico|xcuserstate|xcscheme))$/.test(file) &&
  !/(^|\/)(Package\.(swift|resolved)|Cargo\.toml|go\.(mod|sum)|[^/]*config[^/]*)$/.test(file));
if (!process.env.CHAU7_SKIP_DOC_CHECK && behavioral.length && !files.includes(`${docs}/CHANGELOG.md`)) {
  const exemption = ".chau7/docs-exemption.json";
  let valid = false;
  if (files.includes(exemption)) {
    try {
      const entry = JSON.parse(read(exemption));
      valid = typeof entry.reason === "string" && entry.reason.trim().length >= 20 &&
        Array.isArray(entry.paths) && behavioral.every((file) => entry.paths.includes(file));
    } catch { /* Invalid exemptions fail closed below. */ }
  }
  if (!valid) failures.push(`Update ${docs}/CHANGELOG.md for behavioral changes, or stage ${exemption} with exact paths and a meaningful reason. FEATURES.md and feature inventory changes are needed only when capabilities change.`);
}
// Validate the committed/indexed pair, never unstaged working-tree metadata.
// Unchanged deterministic output is valid; staged stale output still fails.
if (!process.env.CHAU7_SKIP_DOC_CHECK && files.length) {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-docs-index-"));
  try {
    fs.mkdirSync(path.join(temp, docs), { recursive: true });
    for (const file of ["features.json", "features.csv"]) fs.writeFileSync(path.join(temp, docs, file), read(`${docs}/${file}`));
    execFileSync(process.execPath, [path.join(root, "scripts/generate-features-csv.mjs"), "--check"], { cwd: temp, stdio: "pipe" });
  } catch (error) { failures.push(`Indexed feature metadata is stale or invalid: ${error.stderr?.toString() ?? error.message}`); }
  finally { fs.rmSync(temp, { recursive: true, force: true }); }
}
if (failures.length) {
  process.stderr.write(`${failures.join("\n")}\n`);
  process.exitCode = 1;
}
