#!/usr/bin/env node
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

// Immutable original package inventory. Updating the locked upstream snapshot
// requires a reviewed update here; editing a manifest cannot hide new sources.
const PROVENANCE_SHA256 = "600e884a3e4d59802466e27c5e9a8c0a97546faaaae3d4806c8d2d3d55ecef76";
const vendor = "apps/chau7-next/vendor";
const sha256 = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");

function regularSource(root, relative) {
  const absolute = path.resolve(root, relative);
  const within = path.relative(root, absolute);
  if (within === "" || within === ".." || within.startsWith(`..${path.sep}`) || path.isAbsolute(within)) {
    throw new Error("Locked GPUI source must stay inside the repository");
  }
  let ancestor = path.dirname(absolute);
  while (true) {
    const metadata = fs.lstatSync(ancestor);
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
      throw new Error("Locked GPUI source ancestors must be real directories");
    }
    if (ancestor === root) break;
    ancestor = path.dirname(ancestor);
  }
  const metadata = fs.lstatSync(absolute);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error("Locked GPUI original must be a regular file");
  }
  return { absolute, metadata };
}

export function duplicationConfiguration(repository) {
  const root = path.resolve(repository);
  const config = JSON.parse(fs.readFileSync(path.join(root, "scripts/.jscpd.json"), "utf8"));
  const manifest = regularSource(root, `${vendor}/gpui-provenance.json`);
  const raw = fs.readFileSync(manifest.absolute);
  if (sha256(raw) !== PROVENANCE_SHA256) {
    throw new Error("Locked GPUI provenance changed; review the original inventory before filtering duplication");
  }
  const provenance = JSON.parse(raw);
  const excludedPaths = [];
  for (const pkg of provenance.packages) {
    // Exact pinned original paths only. Reject file/ancestor links before
    // reading, and fail on missing originals rather than silently skipping.
    for (const file of pkg.files) {
      const relative = `${vendor}/${pkg.name}/${file.path}`;
      const { absolute, metadata } = regularSource(root, relative);
      if (metadata.size === file.bytes && sha256(fs.readFileSync(absolute)) === file.sha256) {
        excludedPaths.push(relative);
      }
    }
  }
  return { config: { ...config, ignore: [...config.ignore, ...excludedPaths] }, excludedPaths };
}

export function runDuplication(root, outputDirectory) {
  const { config, excludedPaths } = duplicationConfiguration(root);
  if (outputDirectory !== undefined) config.output = outputDirectory;
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-duplication-"));
  try {
    const configuration = path.join(temporary, "jscpd.json");
    fs.writeFileSync(configuration, `${JSON.stringify(config, null, 2)}\n`);
    console.log(`Duplication: ${excludedPaths.length} byte-identical locked upstream files excluded; modified/new sources and threshold unchanged`);
    const result = spawnSync("jscpd", ["--config", configuration], { cwd: root, stdio: "inherit" });
    if (result.error) throw result.error;
    return result.status ?? 1;
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
  try {
    process.exitCode = runDuplication(root);
  } catch (error) {
    console.error(`Duplication failed: ${error.message}`);
    process.exitCode = 1;
  }
}
