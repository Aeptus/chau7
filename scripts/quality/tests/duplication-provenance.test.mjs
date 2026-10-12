import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { duplicationConfiguration } from "../run-duplication.mjs";

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const vendor = "apps/chau7-next/vendor";
const original = `${vendor}/gpui-pre/src/action.rs`;
function ownedRepository(run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-duplication-test-"));
  try {
    fs.mkdirSync(path.join(root, "scripts"));
    fs.copyFileSync(path.join(repository, "scripts/.jscpd.json"), path.join(root, "scripts/.jscpd.json"));
    fs.cpSync(path.join(repository, vendor), path.join(root, vendor), { recursive: true });
    return run(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("only byte-identical upstream originals are excluded; options and source config remain intact", () => {
  const raw = fs.readFileSync(path.join(repository, "scripts/.jscpd.json"), "utf8");
  const before = JSON.parse(raw);
  const result = duplicationConfiguration(repository);
  assert(result.excludedPaths.includes(original));
  assert(!result.excludedPaths.includes(`${vendor}/gpui-pre-apple/src/metal_renderer.rs`));
  const { ignore: _ignore, ...options } = result.config;
  const { ignore: _originalIgnore, ...originalOptions } = before;
  assert.deepEqual(options, originalOptions);
  assert.equal(result.config.threshold, 2);
  assert.deepEqual(result.config.ignore, [...before.ignore, ...result.excludedPaths]);
  assert.equal(fs.readFileSync(path.join(repository, "scripts/.jscpd.json"), "utf8"), raw);
});

test("changed originals and newly added renderer files stay in the scan", () => ownedRepository((root) => {
  const bytes = fs.readFileSync(path.join(root, original));
  bytes[0] ^= 1; // Same size: only the actual content hash proves an original.
  fs.writeFileSync(path.join(root, original), bytes);
  const added = `${vendor}/gpui-pre-macos/src/renderer/owned-new.rs`;
  fs.mkdirSync(path.dirname(path.join(root, added)), { recursive: true });
  fs.writeFileSync(path.join(root, added), "pub fn owned() {}\n");
  const result = duplicationConfiguration(root);
  assert(!result.config.ignore.includes(original));
  assert(!result.config.ignore.includes(added));
  assert(!result.config.ignore.some((entry) => entry.includes("**/vendor/**")));
}));

test("changing the original inventory cannot hide a new file", () => ownedRepository((root) => {
  fs.appendFileSync(path.join(root, vendor, "gpui-provenance.json"), " ");
  assert.throws(() => duplicationConfiguration(root), /provenance changed/);
}));

test("missing originals fail closed", () => ownedRepository((root) => {
  fs.rmSync(path.join(root, original));
  assert.throws(() => duplicationConfiguration(root), { code: "ENOENT" });
}));

test("file and directory symlinks cannot become excluded originals", () => ownedRepository((root) => {
  const source = path.join(root, original);
  const moved = path.join(root, "owned-action.rs");
  fs.renameSync(source, moved);
  fs.symlinkSync(moved, source);
  assert.throws(() => duplicationConfiguration(root), /regular file/);
  fs.rmSync(source);
  fs.renameSync(moved, source);
  const directory = path.join(root, vendor, "gpui-pre/src");
  const relocated = path.join(root, "owned-src");
  fs.renameSync(directory, relocated);
  fs.symlinkSync(relocated, directory);
  assert.throws(() => duplicationConfiguration(root), /real directories/);
}));


test("manifest symlinks fail before reading even byte-identical content", () => ownedRepository((root) => {
  const source = path.join(root, vendor, "gpui-provenance.json");
  const moved = path.join(root, "owned-manifest.json");
  fs.renameSync(source, moved);
  fs.symlinkSync(moved, source);
  assert.throws(() => duplicationConfiguration(root), /regular file/);
}));

test("missing manifest fails closed for the locked dependency audit", () => ownedRepository((root) => {
  fs.rmSync(path.join(root, vendor, "gpui-provenance.json"));
  assert.throws(() => duplicationConfiguration(root), { code: "ENOENT" });
}));
