#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";
import { gates, registryDigest } from "./registry.mjs";
import {
  WAVE_ORDER,
  changedFilesBetween,
  classifyBackendImpact,
  classifyFrontendImpact,
  defaultConcurrency,
  discoverStagedFiles,
  ensureDir,
  filterQualityPaths,
  isWorktreeDirty,
  repoRoot,
  resolveChangedFilesFromPrepush,
  resolveFallbackBase,
  sha256,
  spawnCapture,
  stableJson,
  toolVersion,
} from "./helpers.mjs";
import {
  acceptedAttestation,
  buildCacheKey,
  cacheDisabled,
  initCache,
  outputLogPath,
  pruneOldLogs,
  readCacheEntry,
  writeCacheEntry,
} from "./cache.mjs";

function parseArgs(argv) {
  const options = {
    mode: "local",
    include: new Set(),
    skip: new Set(),
    tags: new Set(),
    skipTags: new Set(),
    wave: "",
    json: false,
    debugCache: false,
    concurrency: defaultConcurrency(),
    full: false,
  };

  for (const arg of argv) {
    if (arg === "--json") options.json = true;
    else if (arg === "--debug-cache") options.debugCache = true;
    else if (arg === "--full") options.full = true;
    else if (arg.startsWith("--mode=")) options.mode = arg.slice("--mode=".length);
    else if (arg.startsWith("--include=")) arg.slice("--include=".length).split(",").filter(Boolean).forEach((id) => options.include.add(id));
    else if (arg.startsWith("--skip=")) arg.slice("--skip=".length).split(",").filter(Boolean).forEach((id) => options.skip.add(id));
    else if (arg.startsWith("--tags=")) arg.slice("--tags=".length).split(",").filter(Boolean).forEach((tag) => options.tags.add(tag));
    else if (arg.startsWith("--skip-tags=")) arg.slice("--skip-tags=".length).split(",").filter(Boolean).forEach((tag) => options.skipTags.add(tag));
    else if (arg.startsWith("--wave=")) options.wave = arg.slice("--wave=".length);
    else if (arg.startsWith("--concurrency=")) options.concurrency = Number(arg.slice("--concurrency=".length));
    else throw new Error(`Unknown quality runner argument: ${arg}`);
  }

  if (!Number.isFinite(options.concurrency) || options.concurrency < 1) {
    options.concurrency = defaultConcurrency();
  }
  options.concurrency = Math.max(1, Math.min(Math.floor(options.concurrency), 12));
  return options;
}

function readStdinIfAvailable() {
  if (process.stdin.isTTY) return "";
  return fs.readFileSync(0, "utf8");
}

function git(root, args, options = {}) {
  try {
    const stdout = execFileSync("git", args, {
      cwd: root,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { ok: true, stdout: stdout.trimEnd(), stderr: "", exitCode: 0 };
  } catch (error) {
    if (options.allowFailure) {
      return {
        ok: false,
        stdout: error.stdout?.toString?.() ?? "",
        stderr: error.stderr?.toString?.() ?? error.message,
        exitCode: error.status ?? 1,
      };
    }
    throw error;
  }
}

function hashExistingFiles(root, files) {
  const payload = {};
  for (const file of files) {
    const absolute = path.join(root, file);
    payload[file] = fs.existsSync(absolute) ? sha256(fs.readFileSync(absolute)) : "missing";
  }
  return sha256(stableJson(payload));
}

function createPrinter({ root, mode, json, debugCache }) {
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const shouldLog = !json && (mode !== "staged" || debugCache);
  const logFile = path.join(root, "logs", `quality-${mode}-${timestamp}.log`);
  if (shouldLog) ensureDir(path.dirname(logFile));

  const write = (message = "") => {
    if (!json) process.stdout.write(`${message}\n`);
    if (shouldLog) fs.appendFileSync(logFile, `${message}\n`);
  };
  return { write, logFile: shouldLog ? logFile : "" };
}

async function buildContext(options, stdin) {
  const root = repoRoot();
  const headSha = git(root, ["rev-parse", "HEAD"], { allowFailure: true }).stdout || "no-head";
  const registryFingerprint = sha256(stableJson(registryDigest()));
  const runnerFingerprint = hashExistingFiles(root, [
    "scripts/quality/runner.mjs",
    "scripts/quality/cache.mjs",
    "scripts/quality/helpers.mjs",
  ]);
  const lockfileFingerprint = hashExistingFiles(root, [
    "pnpm-lock.yaml",
    "services/chau7-relay/package-lock.json",
    "apps/chau7-macos/Package.resolved",
    "apps/chau7-macos/rust/Cargo.lock",
    "apps/chau7-macos/chau7-proxy/go.sum",
    "services/chau7-remote/go.sum",
  ]);
  const repositoryFingerprint = sha256(`${root}\n${git(root, ["config", "--get", "remote.origin.url"], { allowFailure: true }).stdout}`);

  let mode = options.mode;
  let stagedFiles = [];
  let changedFiles = [];
  let prepushUpdates = [];
  let prepushRanges = [];
  let fullReasons = [];

  if (mode === "staged") {
    stagedFiles = discoverStagedFiles(root);
    changedFiles = stagedFiles;
  } else if (mode === "prepush" || mode === "prepush-full") {
    const resolved = stdin.trim()
      ? resolveChangedFilesFromPrepush(stdin, root)
      : { files: [], updates: [], ranges: [] };
    changedFiles = resolved.files;
    prepushUpdates = resolved.updates;
    prepushRanges = resolved.ranges;

    if (!changedFiles.length) {
      const base = resolveFallbackBase(root);
      changedFiles = base ? changedFilesBetween(base, "HEAD", root) : [];
      if (base) prepushRanges.push({ base, head: "HEAD", update: null });
    }

    const highImpact = await import("./helpers.mjs").then((helpers) =>
      helpers.shouldForceFullPrepush({ explicitFull: options.full || mode === "prepush-full", changedFiles }),
    );
    if (highImpact.full) {
      mode = "prepush-full";
      fullReasons = highImpact.reasons;
    }
  } else {
    changedFiles = filterQualityPaths(git(root, ["ls-files"], { allowFailure: true }).stdout.split(/\r?\n/));
  }

  return {
    root,
    mode,
    requestedMode: options.mode,
    full: mode === "prepush-full",
    fullReasons,
    stagedFiles,
    changedFiles,
    prepushUpdates,
    prepushRanges,
    allGates: gates,
    frontendImpact: classifyFrontendImpact(changedFiles),
    backendImpact: classifyBackendImpact(changedFiles),
    headSha,
    repositoryFingerprint,
    registryFingerprint,
    runnerFingerprint,
    lockfileFingerprint,
    git: (args, gitOptions = {}) => git(root, args, gitOptions),
    checkDirtyWorktree: () => checkDirtyWorktree(root),
  };
}

export async function checkDirtyWorktree(root, options = {}) {
  if (!isWorktreeDirty(root)) {
    return { status: "passed", summary: "worktree clean" };
  }
  if (process.env.AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM === "1") {
    return { status: "passed", summary: "dirty worktree explicitly allowed by AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM=1" };
  }
  const interactive = options.interactive ?? (process.stdin.isTTY && process.stderr.isTTY);
  if (!interactive) {
    return {
      status: "failed",
      summary:
        "dirty worktree detected before pre-push in non-interactive mode. Commit/stash changes or set AEPTUS_SKIP_DIRTY_WORKTREE_CONFIRM=1 deliberately.",
    };
  }
  fs.writeSync(2, "Dirty worktree detected before pre-push. Continue? [y/N] ");
  const answer = fs.readFileSync(0, "utf8").trim().toLowerCase();
  if (answer === "y" || answer === "yes") {
    return { status: "passed", summary: "dirty worktree confirmed interactively" };
  }
  return { status: "failed", summary: "dirty worktree push declined" };
}

function gateAllowedByFilters(gate, context, options) {
  if (!gate.modes.includes(context.mode)) return false;
  if (options.include.size && !options.include.has(gate.id)) return false;
  if (options.skip.has(gate.id)) return false;
  if (options.tags.size && !gate.tags.some((tag) => options.tags.has(tag))) return false;
  if (gate.tags.some((tag) => options.skipTags.has(tag))) return false;
  if (options.wave && gate.wave !== options.wave) return false;
  return true;
}

function conciseFailureReason(output) {
  const lines = output
    .split(/\r?\n/)
    .map((line) => line.trimEnd())
    .filter(Boolean);
  return lines.slice(-12).join("\n").slice(0, 4000) || "command failed";
}

async function executeGate(gate, baseContext, printer, options, timestamp) {
  let gateOutput = "";
  const context = {
    ...baseContext,
    exec: async (command, args = [], execOptions = {}) => {
      const cwd = execOptions.cwd ? path.join(baseContext.root, execOptions.cwd) : baseContext.root;
      const rendered = `$ ${quoteCommand(command, args, execOptions.cwd)}`;
      gateOutput += `${rendered}\n`;
      const result = await spawnCapture(command, args, {
        cwd,
        env: execOptions.env,
        onOutput: (chunk) => {
          gateOutput += chunk;
        },
      });
      if (!result.ok) {
        return {
          status: "failed",
          summary: conciseFailureReason(`${result.stdout}\n${result.stderr}`),
          command: rendered,
          exitCode: result.exitCode,
          output: `${result.stdout}\n${result.stderr}`,
        };
      }
      return { status: "passed", summary: "command passed", command: rendered, output: `${result.stdout}\n${result.stderr}` };
    },
  };

  const cacheInfo = readCacheEntry(gate, context);
  if (cacheInfo.hit) {
    if (options.debugCache) printer.write(`  cache hit ${gate.id}: ${cacheInfo.key}`);
    return {
      gate,
      status: "passed",
      cached: true,
      attested: false,
      summary: cacheInfo.entry.summary || "cache hit",
    };
  }
  if (options.debugCache && gate.cacheable) {
    printer.write(`  cache miss ${gate.id}${cacheInfo.disabled ? " (disabled)" : ""}: ${cacheInfo.key ?? "no-key"}`);
  }

  const attestation = acceptedAttestation(gate, context);
  if (attestation) {
    printer.write(`  attested ${gate.id}: ${attestation.reason}`);
    return {
      gate,
      status: "passed",
      cached: false,
      attested: true,
      summary: attestation.reason,
      logFile: attestation.file,
    };
  }

  let result;
  try {
    result = await gate.run(context);
  } catch (error) {
    result = { status: "failed", summary: error.stack || error.message };
  }

  const key = gate.cacheable && !cacheDisabled() ? buildCacheKey(gate, context) : "";
  if (result.status === "passed") {
    writeCacheEntry(gate, context, result, key);
  }

  let logFile = "";
  if (gateOutput || result.status !== "passed") {
    initCache(context.root);
    logFile = outputLogPath(gate.id, timestamp, context.root);
    fs.writeFileSync(logFile, `${gate.id}\n${gateOutput}\n${result.summary ?? ""}\n`);
  }

  return {
    gate,
    status: result.status ?? "failed",
    cached: false,
    attested: false,
    summary: result.summary ?? "",
    logFile,
  };
}

function quoteCommand(command, args, cwd) {
  const rendered = [command, ...args].map((arg) => {
    const text = String(arg);
    if (/^[A-Za-z0-9_./:=@+-]+$/.test(text)) return text;
    return `'${text.replaceAll("'", "'\"'\"'")}'`;
  }).join(" ");
  return cwd ? `(cd ${cwd} && ${rendered})` : rendered;
}

async function runConcurrent(items, limit, worker) {
  const results = [];
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await worker(items[index]);
    }
  });
  await Promise.all(runners);
  return results;
}

export async function runQuality(argv = process.argv.slice(2), stdin = readStdinIfAvailable()) {
  const options = parseArgs(argv);
  const context = await buildContext(options, stdin);
  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const printer = createPrinter({ root: context.root, mode: context.mode, json: options.json, debugCache: options.debugCache });
  pruneOldLogs(context.root);

  const selected = [];
  const skipped = [];
  for (const gate of gates) {
    if (!gateAllowedByFilters(gate, context, options)) continue;
    let applies = true;
    try {
      applies = gate.applies ? Boolean(gate.applies(context)) : true;
    } catch (error) {
      return {
        ok: false,
        mode: context.mode,
        failures: [{ gate, status: "failed", summary: `applies() failed: ${error.message}` }],
        skipped,
      };
    }
    if (applies) selected.push(gate);
    else skipped.push({ gate, reason: "not applicable to changed files" });
  }

  if (!options.json) {
    printer.write(`quality ${context.mode}`);
    if (context.fullReasons.length) {
      printer.write(`full-suite trigger: ${context.fullReasons.join("; ")}`);
    }
    printer.write(`changed files: ${context.changedFiles.length}`);
    printer.write(`gates selected: ${selected.length}`);
    if (skipped.length && options.debugCache) {
      for (const entry of skipped) printer.write(`  skipped ${entry.gate.id}: ${entry.reason}`);
    }
  }

  const results = [];
  let failed = false;
  for (const wave of WAVE_ORDER) {
    const waveGates = selected.filter((gate) => gate.wave === wave).sort((a, b) => a.id.localeCompare(b.id));
    if (!waveGates.length) continue;
    if (!options.json) printer.write(`\n[${wave}] ${waveGates.map((gate) => gate.id).join(", ")}`);
    const waveResults = await runConcurrent(
      waveGates,
      options.concurrency,
      async (gate) => executeGate(gate, context, printer, options, timestamp),
    );
    results.push(...waveResults);
    const waveFailed = waveResults.some((result) => result.status !== "passed");
    if (waveFailed) {
      failed = true;
      if (!options.json) printer.write(`wave ${wave} failed; later waves were not started`);
      break;
    }
  }

  const summary = {
    ok: !failed,
    mode: context.mode,
    requestedMode: context.requestedMode,
    fullReasons: context.fullReasons,
    changedFileCount: context.changedFiles.length,
    changedFiles: options.debugCache ? context.changedFiles : context.changedFiles.slice(0, 50),
    selected: selected.map((gate) => gate.id),
    skipped: skipped.map((entry) => ({ id: entry.gate.id, reason: entry.reason })),
    results: results.map((result) => ({
      id: result.gate.id,
      status: result.status,
      scope: result.gate.scope,
      wave: result.gate.wave,
      cached: result.cached,
      attested: result.attested,
      summary: result.summary,
      rerun: result.gate.rerun,
      logFile: result.logFile || "",
    })),
    logFile: printer.logFile,
  };

  if (options.json) {
    process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
  } else {
    printHumanSummary(summary, printer.write);
  }
  return summary;
}

function printHumanSummary(summary, write) {
  const failed = summary.results.filter((result) => result.status !== "passed");
  const passed = summary.results.filter((result) => result.status === "passed");
  write("");
  if (!failed.length) {
    write(`quality ${summary.mode} passed (${passed.length} gate${passed.length === 1 ? "" : "s"})`);
    if (summary.logFile) write(`log: ${summary.logFile}`);
    return;
  }

  write(`quality ${summary.mode} failed (${failed.length} gate${failed.length === 1 ? "" : "s"})`);
  for (const result of failed.sort((a, b) => a.id.localeCompare(b.id))) {
    write(`\n- ${result.id}`);
    write(`  Scope: ${result.scope}`);
    write(`  Wave: ${result.wave}`);
    write(`  Rerun: ${result.rerun}`);
    if (result.logFile) write(`  Log: ${result.logFile}`);
    write(`  Cache: ${result.cached ? "hit" : "not used"}`);
    write(`  Attestation: ${result.attested ? "used" : "not used"}`);
    write(`  Reason: ${String(result.summary).split(/\r?\n/).slice(0, 8).join("\n          ")}`);
  }
  if (summary.logFile) write(`\nrun log: ${summary.logFile}`);
}

export async function main(argv = process.argv.slice(2)) {
  const summary = await runQuality(argv);
  process.exitCode = summary.ok ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exitCode = 1;
  });
}
