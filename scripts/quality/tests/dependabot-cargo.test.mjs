import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const config = fs.readFileSync(path.join(root, ".github/dependabot.yml"), "utf8");

function cargoEntries() {
  const lines = config.split("\n");
  const starts = lines.flatMap((line, index) =>
    /^  - package-ecosystem: [a-z0-9-]+$/.test(line) ? [index] : [],
  );
  return starts
    .map((start, index) => {
      const end = starts[index + 1] ?? lines.length;
      return lines.slice(start, end).join("\n");
    })
    .filter((entry) => /^  - package-ecosystem: cargo$/m.test(entry));
}

function entryDirectory(entry) {
  return entry.match(/^    directory: ([^\n]+)$/m)?.[1] ?? null;
}

function groupBlock(entry, name) {
  const lines = entry.split("\n");
  const start = lines.findIndex((line) => line === "      " + name + ":");
  assert.notEqual(start, -1, "missing group " + name);
  let end = start + 1;
  while (end < lines.length && !/^      [a-z0-9-]+:$/.test(lines[end])) end += 1;
  return lines.slice(start, end).join("\n");
}

const workspaces = [
  {
    directory: "/crates",
    lockfile: "crates/Cargo.lock",
  },
  {
    directory: "/apps/chau7-next",
    lockfile: "apps/chau7-next/Cargo.lock",
  },
];

test("Dependabot has a separate Cargo entry for each tracked workspace lockfile", () => {
  const entries = cargoEntries();
  const configuredDirectories = entries.map(entryDirectory).sort();
  assert.deepEqual(
    configuredDirectories,
    workspaces.map(({ directory }) => directory).sort(),
  );

  for (const { directory, lockfile } of workspaces) {
    const matches = entries.filter((entry) => entryDirectory(entry) === directory);
    assert.equal(matches.length, 1, "expected one Cargo entry for " + directory);
    assert.ok(fs.existsSync(path.join(root, directory.slice(1), "Cargo.toml")));
    assert.ok(fs.existsSync(path.join(root, lockfile)));
    const tracked = execFileSync("git", ["ls-files", "--error-unmatch", "--", lockfile], {
      cwd: root,
      encoding: "utf8",
    }).trim();
    assert.equal(tracked, lockfile);
  }
});

test("Chau7 Next groups GPUI updates before the compatible-update group", () => {
  const next = cargoEntries().find((entry) => entryDirectory(entry) === "/apps/chau7-next");
  assert.ok(next, "missing Chau7 Next Cargo entry");
  assert.ok(next.includes("    schedule:\n      interval: weekly"));
  assert.ok(next.includes("    open-pull-requests-limit: 5"));

  const version = groupBlock(next, "coordinated-gpui-version-updates");
  const security = groupBlock(next, "coordinated-gpui-security-updates");
  const compatible = groupBlock(next, "compatible-updates");
  const versionIndex = next.indexOf("      coordinated-gpui-version-updates:");
  const securityIndex = next.indexOf("      coordinated-gpui-security-updates:");
  const compatibleIndex = next.indexOf("      compatible-updates:");
  assert.ok(versionIndex >= 0 && versionIndex < compatibleIndex);
  assert.ok(securityIndex >= 0 && securityIndex < compatibleIndex);
  assert.ok(version.includes("        applies-to: version-updates"));
  assert.ok(version.includes('        patterns: ["gpui*"]'));
  assert.ok(security.includes("        applies-to: security-updates"));
  assert.ok(security.includes('        patterns: ["gpui*"]'));
  assert.ok(compatible.includes("        applies-to: version-updates"));
  assert.ok(compatible.includes('        patterns: ["*"]'));
  assert.ok(compatible.includes("        update-types: [minor, patch]"));
});
