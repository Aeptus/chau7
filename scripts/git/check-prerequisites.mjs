#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const pins = fs.readFileSync(path.join(root, "mise.toml"), "utf8");
const versions = Object.fromEntries([...pins.matchAll(/^"?([^"\s=]+)"? = "([^"\n]+)"$/gm)].map((match) => [match[1], match[2]]));
const specs = [
  ["node", "node", ["--version"]], ["pnpm", "npm:pnpm", ["--version"]],
  ["go", "go", ["version"]], ["python3", "python", ["--version"]],
  ["swiftformat", "aqua:nicklockwood/SwiftFormat", ["--version"]],
  ["swiftlint", "aqua:realm/SwiftLint", ["version"]],
  ["gitleaks", "aqua:gitleaks/gitleaks", ["version"]],
  ["shellcheck", "aqua:koalaman/shellcheck", ["--version"]],
  ["ruff", "aqua:astral-sh/ruff", ["--version"]],
  ["golangci-lint", "aqua:golangci/golangci-lint", ["version"]],
  ["periphery", "aqua:peripheryapp/periphery", ["version"]],
  ["cargo", "cargo:cargo-deny", ["deny", "--version"]],
  ["jscpd", "npm:jscpd", ["--version"]], ["pip-audit", "pipx:pip-audit", ["--version"]],
];
let failed = false;
for (const [command, key, args] of specs) {
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8", timeout: 10000 });
  const output = `${result.stdout ?? ""} ${result.stderr ?? ""}`;
  const expected = versions[key];
  if (result.status !== 0 || !new RegExp(`(^|[^0-9.])${expected.replaceAll(".", "\\.")}([^0-9.]|$)`).test(output)) {
    failed = true; process.stderr.write(`${command}: required baseline ${expected}; ${result.error?.message ?? output.trim()}. Install: mise install && mise exec -- pnpm setup:check\n`);
  }
}
const rust = spawnSync("rustc", ["--version"], { cwd: path.join(root, "apps/chau7-macos/rust"), encoding: "utf8", timeout: 10000 });
if (rust.status !== 0 || !rust.stdout.includes(`rustc ${versions.rust} `)) {
  failed = true; process.stderr.write(`Rust workspace requires ${versions.rust}. Run mise install or rustup toolchain install ${versions.rust} --component rustfmt,clippy.\n`);
}
if (process.platform === "darwin") {
  const xcode = spawnSync("xcodebuild", ["-version"], { encoding: "utf8", timeout: 10000 });
  if (xcode.status !== 0 || !xcode.stdout.includes("Xcode 26.6\n")) {
    failed = true; process.stderr.write("Select Xcode 26.6 (CI baseline): sudo xcode-select --switch /Applications/Xcode_26.6.app/Contents/Developer\n");
  }
} else { failed = true; process.stderr.write("The native app requires macOS with Xcode 26.6; Core-only and tooling tests have a smaller surface.\n"); }
for (const field of ["user.name", "user.email"]) {
  const identity = spawnSync("git", ["config", "--get", field], { cwd: root, encoding: "utf8" });
  if (identity.status !== 0 || /Quality Tests|quality@example\./i.test(identity.stdout)) {
    failed = true; process.stderr.write(`Configure a real Git ${field}; fixture identity must not author product changes.\n`);
  }
}
const hooks = spawnSync(process.execPath, [path.join(root, "scripts/git/install-hooks.mjs"), "--check"], { stdio: "inherit" });
if (hooks.status !== 0) failed = true;
process.exitCode = failed ? 1 : 0;
