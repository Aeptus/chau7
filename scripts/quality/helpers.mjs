import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { execFileSync, spawn } from "node:child_process";

export const WAVE_ORDER = ["preflight", "static", "build", "postbuild", "tests", "audit"];
export const VALID_MODES = ["staged", "prepush", "prepush-full", "local", "cloud-parity"];
export const VALID_SCOPES = ["staged", "changed", "repo"];
export const CACHE_SCHEMA_VERSION = "quality-cache-v1";
export const QUALITY_CACHE_DIR = ".aeptus-cache/quality";

const ZERO_SHA_RE = /^0+$/;
const IGNORED_PATH_PATTERNS = [
  /^\.aeptus-cache\//,
  /^\.cache\//,
  /^\.jscpd-report\//,
  /^\.ruff_cache\//,
  /(^|\/)\.ruff_cache\//,
  /(^|\/)__pycache__\//,
  /(^|\/)node_modules\//,
  /(^|\/)\.build\//,
  /(^|\/)target\//,
  /(^|\/)dist\//,
  /(^|\/)coverage\//,
  /(^|\/)\.venv\//,
  /(^|\/)venv\//,
  /(^|\/)\.DS_Store$/,
];

export const HIGH_IMPACT_PATTERNS = [
  /^\.husky\//,
  /^tools\/git-hooks\//,
  /^scripts\/git\//,
  /^scripts\/quality\//,
  /^package\.json$/,
  /^pnpm-lock\.yaml$/,
  /^pnpm-workspace\.yaml$/,
  /(^|\/)package\.json$/,
  /(^|\/)package-lock\.json$/,
  /(^|\/)tsconfig[^/]*\.json$/,
  /(^|\/)vitest\.config\.[cm]?[jt]s$/,
  /(^|\/)playwright\.config\.[cm]?[jt]s$/,
  /(^|\/)tailwind\.config\.[cm]?[jt]s$/,
  /(^|\/)eslint\.config\.[cm]?[jt]s$/,
  /(^|\/)pyproject\.toml$/,
  /(^|\/)requirements[^/]*\.txt$/,
  /^apps\/chau7-macos\/Package\.swift$/,
  /^apps\/chau7-macos\/Package\.resolved$/,
  /^apps\/chau7-macos\/\.swiftformat$/,
  /^apps\/chau7-macos\/\.swiftlint\.yml$/,
  /^apps\/chau7-macos\/\.periphery\.yml$/,
  /^apps\/chau7-macos\/rust\/Cargo\.(toml|lock)$/,
  /^apps\/chau7-macos\/rust\/deny\.toml$/,
  /(^|\/)go\.(mod|sum)$/,
  /^scripts\/ci-/,
  /^scripts\/check-/,
  /^scripts\/ruff\.toml$/,
  /^\.github\/workflows\//,
  /(^|\/)(openapi|swagger)\.(json|ya?ml)$/,
  /(^|\/)(openapi|swagger)\//,
  /(^|\/)(test-setup|setupTests|vitest\.setup)\.[cm]?[jt]s$/,
  /(^|\/)(env|environment|settings|config|build|tooling|generator)[^/]*\.(swift|go|rs|ts|js|py|json|toml|ya?ml)$/,
];

export const FRONTEND_GRAPH = {
  "relay": {
    roots: ["services/chau7-relay/"],
    dependsOn: [],
  },
  "issues": {
    roots: ["services/chau7-issues/"],
    dependsOn: [],
  },
};

export const GENERATED_PATH_PATTERNS = [
  /(^|\/)generated\//,
  /(^|\/)__generated__\//,
  /(^|\/)openapi\.generated\./,
  /(^|\/)client\.generated\./,
  /(^|\/)zod\.generated\./,
];

export function repoRoot() {
  return execFileSync("git", ["rev-parse", "--show-toplevel"], {
    encoding: "utf8",
  }).trim();
}

export function runGit(args, options = {}) {
  return execFileSync("git", args, {
    cwd: options.cwd ?? repoRoot(),
    encoding: "utf8",
    stdio: options.stdio ?? ["ignore", "pipe", "pipe"],
  }).trim();
}

export function stableJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(stableJson).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function isIgnoredQualityPath(file) {
  const normalized = file.replaceAll(path.sep, "/");
  return IGNORED_PATH_PATTERNS.some((pattern) => pattern.test(normalized));
}

export function isGeneratedArtifact(file) {
  const normalized = file.replaceAll(path.sep, "/");
  return GENERATED_PATH_PATTERNS.some((pattern) => pattern.test(normalized));
}

export function filterQualityPaths(files) {
  return [...new Set(files.map((file) => file.trim()).filter(Boolean))]
    .map((file) => file.replaceAll(path.sep, "/"))
    .filter((file) => !isIgnoredQualityPath(file))
    .sort();
}

export function discoverStagedFiles(root = repoRoot()) {
  const output = execFileSync("git", ["diff", "--cached", "--name-only", "--diff-filter=ACMR"], {
    cwd: root,
    encoding: "utf8",
  });
  return filterQualityPaths(output.split(/\r?\n/));
}

export function parsePrepushUpdates(input) {
  return input
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [localRef, localSha, remoteRef, remoteSha] = line.split(/\s+/);
      return { localRef, localSha, remoteRef, remoteSha };
    })
    .filter((update) => update.localRef && update.localSha && update.remoteRef && update.remoteSha);
}

export function isZeroSha(sha) {
  return ZERO_SHA_RE.test(sha ?? "");
}

export function highImpactReasons(files) {
  const reasons = new Map();
  for (const file of files) {
    for (const pattern of HIGH_IMPACT_PATTERNS) {
      if (pattern.test(file)) {
        reasons.set(file, pattern.toString());
        break;
      }
    }
  }
  return reasons;
}

export function shouldForceFullPrepush({ explicitFull = false, changedFiles = [] } = {}) {
  if (explicitFull) {
    return { full: true, reasons: ["--full was passed"] };
  }
  if (!changedFiles.length) {
    return { full: true, reasons: ["no changed files could be resolved"] };
  }
  const reasons = [...highImpactReasons(changedFiles).keys()].map(
    (file) => `high-impact change: ${file}`,
  );
  return { full: reasons.length > 0, reasons };
}

export function classifyFrontendImpact(files) {
  const groups = new Set();
  for (const file of files) {
    if (file.startsWith("services/chau7-relay/")) groups.add("relay");
    if (file.startsWith("services/chau7-issues/")) groups.add("issues");
    if (/^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$/.test(file)) groups.add("tooling");
    if (/(^|\/)(tsconfig|eslint\.config|prettier|vitest|playwright)\b/.test(file)) {
      groups.add("global-frontend-config");
    }
    if (/(\.test|\.spec)\.[cm]?[jt]sx?$/.test(file)) groups.add("test-only");
    if (/(\.stories|\.story|example)\.[cm]?[jt]sx?$/.test(file)) groups.add("story-example-only");
  }

  const impactedApps = new Set();
  for (const group of groups) {
    if (FRONTEND_GRAPH[group]) impactedApps.add(group);
  }
  if (groups.has("global-frontend-config") || groups.has("tooling")) {
    Object.keys(FRONTEND_GRAPH).forEach((app) => impactedApps.add(app));
  }
  return {
    groups: [...groups].sort(),
    apps: [...impactedApps].sort(),
  };
}

export function classifyBackendImpact(files) {
  const groups = new Set();
  for (const file of files) {
    if (file.startsWith("apps/chau7-macos/chau7-proxy/")) groups.add("go-proxy");
    if (file.startsWith("services/chau7-remote/")) groups.add("go-remote");
    if (file.endsWith("_test.go")) groups.add("backend-tests");
    if (file.endsWith(".py")) groups.add("python");
    if (file.includes("/migrations/")) groups.add("migrations");
    if (/(^|\/)(settings|config|env|environment)/.test(file)) groups.add("settings-config");
    if (/(^|\/)(permission|auth|guard)/i.test(file)) groups.add("permissions");
    if (/go\.(mod|sum)$/.test(file)) groups.add("backend-dependencies");
    if (/(pyproject\.toml|requirements[^/]*\.txt)$/.test(file)) groups.add("python-dependencies");
  }
  return { groups: [...groups].sort() };
}

export function directTargetsForFiles(files) {
  const swift = files.filter((file) => file.endsWith(".swift"));
  const rust = files.filter((file) => file.endsWith(".rs"));
  const go = files.filter((file) => file.endsWith(".go"));
  const jsTs = files.filter((file) => /\.[cm]?[jt]sx?$/.test(file));
  const python = files.filter((file) => file.endsWith(".py"));
  const shell = files.filter((file) => /\.(sh|bash)$/.test(file) || /^scripts\//.test(file));
  return { swift, rust, go, jsTs, python, shell };
}

export function resolveFallbackBase(root = repoRoot()) {
  const candidates = [
    ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
    ["rev-parse", "--verify", "origin/main"],
    ["rev-parse", "--verify", "origin/production"],
    ["rev-parse", "--verify", "main"],
    ["rev-parse", "--verify", "production"],
    ["rev-parse", "--verify", "HEAD^"],
  ];

  for (const args of candidates) {
    try {
      const value = execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
      if (!value) continue;
      if (args[1] === "--abbrev-ref") {
        return execFileSync("git", ["rev-parse", "--verify", value], {
          cwd: root,
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
        }).trim();
      }
      return value;
    } catch {
      // Try the next fallback.
    }
  }
  return "";
}

export function changedFilesBetween(base, head = "HEAD", root = repoRoot()) {
  if (!base || !head) return [];
  const output = execFileSync("git", ["diff", "--name-only", "--diff-filter=ACMR", `${base}..${head}`], {
    cwd: root,
    encoding: "utf8",
  });
  return filterQualityPaths(output.split(/\r?\n/));
}

export function mergeBase(left, right, root = repoRoot()) {
  return execFileSync("git", ["merge-base", left, right], {
    cwd: root,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
}

export function resolveChangedFilesFromPrepush(input, root = repoRoot()) {
  const updates = parsePrepushUpdates(input);
  const files = new Set();
  const ranges = [];

  for (const update of updates) {
    if (isZeroSha(update.localSha)) continue;
    let base = update.remoteSha;
    if (isZeroSha(update.remoteSha)) {
      try {
        base = mergeBase(update.localSha, "origin/main", root);
      } catch {
        base = resolveFallbackBase(root);
      }
    }
    if (!base) continue;
    ranges.push({ base, head: update.localSha, update });
    for (const file of changedFilesBetween(base, update.localSha, root)) {
      files.add(file);
    }
  }

  return { files: [...files].sort(), updates, ranges };
}

export function isWorktreeDirty(root = repoRoot()) {
  const output = execFileSync("git", ["status", "--porcelain"], {
    cwd: root,
    encoding: "utf8",
  });
  return output.trim().length > 0;
}

export function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

export function pathExists(file) {
  return fs.existsSync(file);
}

export function rel(root, file) {
  return path.relative(root, file).replaceAll(path.sep, "/");
}

export function quoteShell(args) {
  return args
    .map((arg) => {
      if (/^[A-Za-z0-9_./:=@+-]+$/.test(arg)) return arg;
      return `'${arg.replaceAll("'", "'\"'\"'")}'`;
    })
    .join(" ");
}

export function defaultConcurrency() {
  return Math.max(1, Math.min(os.cpus().length || 1, 6));
}

export function readTextIfExists(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

export function toolVersion(command, args = ["--version"], cwd = repoRoot()) {
  try {
    return execFileSync(command, args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
      .trim()
      .split(/\r?\n/)[0];
  } catch {
    return "missing";
  }
}

export async function spawnCapture(command, args, options = {}) {
  const cwd = options.cwd ?? repoRoot();
  const env = { ...process.env, ...(options.env ?? {}) };
  return await new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env, shell: false });
    let stdout = "";
    let stderr = "";

    child.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      stdout += text;
      options.onOutput?.(text, "stdout");
    });
    child.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      stderr += text;
      options.onOutput?.(text, "stderr");
    });
    child.on("error", (error) => {
      stderr += `${error.message}\n`;
      resolve({ ok: false, exitCode: 127, stdout, stderr });
    });
    child.on("close", (code) => {
      resolve({ ok: code === 0, exitCode: code ?? 1, stdout, stderr });
    });
  });
}

export function validateRegistry(gates) {
  const errors = [];
  const ids = new Set();
  for (const [index, gate] of gates.entries()) {
    const label = gate?.id ?? `gate[${index}]`;
    if (!gate?.id || !/^[a-z0-9][a-z0-9-]*$/.test(gate.id)) {
      errors.push(`${label}: missing stable kebab-case id`);
    }
    if (ids.has(gate.id)) errors.push(`${label}: duplicate id`);
    ids.add(gate.id);
    if (!Array.isArray(gate.modes) || gate.modes.some((mode) => !VALID_MODES.includes(mode))) {
      errors.push(`${label}: invalid modes`);
    }
    if (!VALID_SCOPES.includes(gate.scope)) errors.push(`${label}: invalid scope`);
    if (!WAVE_ORDER.includes(gate.wave)) errors.push(`${label}: invalid wave`);
    if (!Array.isArray(gate.tags)) errors.push(`${label}: missing tags`);
    if (typeof gate.cacheable !== "boolean") errors.push(`${label}: cacheable must be boolean`);
    if (!Array.isArray(gate.inputs)) errors.push(`${label}: missing inputs array`);
    if (gate.cacheable && gate.inputs.length === 0) errors.push(`${label}: cacheable gate needs explicit inputs`);
    if (gate.scope !== "repo" && typeof gate.applies !== "function") {
      errors.push(`${label}: non-repo gate needs applies predicate`);
    }
    if (typeof gate.run !== "function") errors.push(`${label}: missing run function`);
    if (!gate.rerun || typeof gate.rerun !== "string") errors.push(`${label}: missing rerun command`);
  }
  return errors;
}
