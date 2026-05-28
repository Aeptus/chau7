import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import {
  CACHE_SCHEMA_VERSION,
  QUALITY_CACHE_DIR,
  ensureDir,
  filterQualityPaths,
  readTextIfExists,
  repoRoot,
  runGit,
  sha256,
  stableJson,
  toolVersion,
} from "./helpers.mjs";

const CACHE_DISABLE_ENVS = ["AEPTUS_QUALITY_DISABLE_CACHE", "AEPTUS_PREPUSH_DISABLE_CACHE"];
const RUNNER_INPUTS = [
  "scripts/quality/runner.mjs",
  "scripts/quality/registry.mjs",
  "scripts/quality/cache.mjs",
  "scripts/quality/helpers.mjs",
];
const LOCKFILE_INPUTS = [
  "pnpm-lock.yaml",
  "package-lock.json",
  "services/chau7-relay/package-lock.json",
  "apps/chau7-macos/Package.resolved",
  "apps/chau7-macos/rust/Cargo.lock",
  "apps/chau7-macos/chau7-proxy/go.sum",
  "services/chau7-remote/go.sum",
];

export function cacheDisabled() {
  return CACHE_DISABLE_ENVS.some((key) => process.env[key] && process.env[key] !== "0");
}

export function cacheRoot(root = repoRoot()) {
  return path.join(root, QUALITY_CACHE_DIR);
}

export function cacheResultPath(key, root = repoRoot()) {
  return path.join(cacheRoot(root), "results", `${key}.json`);
}

export function outputLogPath(gateId, timestamp, root = repoRoot()) {
  return path.join(cacheRoot(root), "outputs", `${gateId}-${timestamp}.log`);
}

export function artifactRoot(root = repoRoot()) {
  return path.join(cacheRoot(root), "artifacts");
}

export function attestationsRoot(root = repoRoot()) {
  return path.join(cacheRoot(root), "attestations");
}

export function initCache(root = repoRoot()) {
  ensureDir(path.join(cacheRoot(root), "results"));
  ensureDir(path.join(cacheRoot(root), "outputs"));
  ensureDir(path.join(cacheRoot(root), "artifacts"));
  ensureDir(attestationsRoot(root));
}

function fileFingerprint(root, relPath) {
  const absolute = path.join(root, relPath);
  if (!fs.existsSync(absolute)) {
    return { path: relPath, missing: true };
  }
  const stat = fs.statSync(absolute);
  if (stat.isDirectory()) {
    return { path: relPath, directory: true, entries: directoryFingerprint(root, relPath) };
  }
  return {
    path: relPath,
    sha256: sha256(fs.readFileSync(absolute)),
  };
}

function directoryFingerprint(root, relDir) {
  let files = [];
  try {
    const tracked = runGit(["ls-files", "--", relDir], { cwd: root });
    files = tracked ? tracked.split(/\r?\n/) : [];
    const untracked = runGit(["ls-files", "--others", "--exclude-standard", "--", relDir], { cwd: root });
    if (untracked) files.push(...untracked.split(/\r?\n/));
  } catch {
    files = walkFiles(path.join(root, relDir)).map((file) => path.relative(root, file).replaceAll(path.sep, "/"));
  }

  return filterQualityPaths(files).map((file) => fileFingerprint(root, file));
}

function walkFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const output = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const absolute = path.join(dir, entry.name);
    if (entry.isDirectory()) output.push(...walkFiles(absolute));
    else if (entry.isFile()) output.push(absolute);
  }
  return output;
}

export function buildCacheKey(gate, context) {
  const root = context.root;
  const changedInputFiles = context.changedFiles ?? [];
  const scopedFiles = gate.scope === "staged" || gate.scope === "changed" ? changedInputFiles : [];
  const declaredInputs = [
    ...RUNNER_INPUTS,
    ...LOCKFILE_INPUTS,
    ...(gate.inputs ?? []),
    ...scopedFiles,
  ];

  const payload = {
    schema: CACHE_SCHEMA_VERSION,
    gate: gate.id,
    mode: context.mode,
    full: context.full,
    node: process.version,
    pnpm: toolVersion("pnpm", ["--version"], root),
    python: toolVersion("python3", ["--version"], root),
    env: Object.fromEntries((gate.cacheEnv ?? []).map((key) => [key, process.env[key] ?? ""])),
    files: [...new Set(declaredInputs)].sort().map((input) => fileFingerprint(root, input)),
  };

  return sha256(stableJson(payload));
}

export function readCacheEntry(gate, context) {
  if (!gate.cacheable || cacheDisabled()) {
    return { hit: false, disabled: cacheDisabled() };
  }
  const key = buildCacheKey(gate, context);
  const file = cacheResultPath(key, context.root);
  if (!fs.existsSync(file)) {
    return { hit: false, key };
  }
  try {
    const entry = JSON.parse(fs.readFileSync(file, "utf8"));
    if (entry?.status !== "passed") return { hit: false, key };
    return { hit: true, key, entry };
  } catch {
    return { hit: false, key };
  }
}

export function writeCacheEntry(gate, context, result, key) {
  if (!gate.cacheable || cacheDisabled() || result.status !== "passed") return;
  initCache(context.root);
  const entry = {
    schema: CACHE_SCHEMA_VERSION,
    gate: gate.id,
    mode: context.mode,
    status: "passed",
    summary: result.summary ?? "",
    writtenAt: new Date().toISOString(),
  };
  fs.writeFileSync(cacheResultPath(key, context.root), `${JSON.stringify(entry, null, 2)}\n`);
}

export function cacheStatus(root = repoRoot()) {
  const base = cacheRoot(root);
  const results = path.join(base, "results");
  const outputs = path.join(base, "outputs");
  const attestations = path.join(base, "attestations");
  const count = (dir) => (fs.existsSync(dir) ? fs.readdirSync(dir).length : 0);
  return {
    root: base,
    disabled: cacheDisabled(),
    results: count(results),
    outputs: count(outputs),
    attestations: count(attestations),
  };
}

export function clearCache(root = repoRoot()) {
  fs.rmSync(cacheRoot(root), { recursive: true, force: true });
}

export function pruneOldLogs(root = repoRoot(), now = Date.now()) {
  const logsDir = path.join(root, "logs");
  const outputDir = path.join(cacheRoot(root), "outputs");
  const cutoff = now - 7 * 24 * 60 * 60 * 1000;
  for (const dir of [logsDir, outputDir]) {
    if (!fs.existsSync(dir)) continue;
    for (const entry of fs.readdirSync(dir)) {
      const absolute = path.join(dir, entry);
      const stat = fs.statSync(absolute);
      if (stat.mtimeMs < cutoff) fs.rmSync(absolute, { force: true });
    }
  }
}

export function acceptedAttestation(gate, context) {
  if (!gate.attestableBy?.length) return null;
  const maxAgeMinutes = Number(process.env.AEPTUS_ORDER66_ATTESTATION_MAX_AGE_MINUTES ?? "30");
  const maxAgeMs = maxAgeMinutes * 60 * 1000;
  for (const name of gate.attestableBy) {
    const file = path.join(attestationsRoot(context.root), `${name}.json`);
    if (!fs.existsSync(file)) continue;
    try {
      const attestation = JSON.parse(readTextIfExists(file));
      if (Date.now() - Date.parse(attestation.writtenAt ?? 0) > maxAgeMs) continue;
      if (attestation.head !== context.headSha) continue;
      if (attestation.repository !== context.repositoryFingerprint) continue;
      if (attestation.registry !== context.registryFingerprint) continue;
      if (attestation.runner !== context.runnerFingerprint) continue;
      if (attestation.lockfiles !== context.lockfileFingerprint) continue;
      if (!attestation.gates?.includes(gate.id)) continue;
      return { name, file, reason: `accepted ${name} attestation` };
    } catch {
      // Ignore malformed attestations.
    }
  }
  return null;
}

export function writeAttestation(name, context, gateIds) {
  initCache(context.root);
  const payload = {
    name,
    head: context.headSha,
    repository: context.repositoryFingerprint,
    registry: context.registryFingerprint,
    runner: context.runnerFingerprint,
    lockfiles: context.lockfileFingerprint,
    gates: [...gateIds].sort(),
    writtenAt: new Date().toISOString(),
  };
  const file = path.join(attestationsRoot(context.root), `${name}.json`);
  fs.writeFileSync(file, `${JSON.stringify(payload, null, 2)}\n`);
  return file;
}

