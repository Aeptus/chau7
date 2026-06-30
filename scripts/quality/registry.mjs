import fs from "node:fs";
import path from "node:path";
import {
  classifyBackendImpact,
  classifyFrontendImpact,
  directTargetsForFiles,
  isGeneratedArtifact,
  pathExists,
  validateRegistry,
} from "./helpers.mjs";

const STAGED_ONLY = ["staged"];
const PREPUSH = ["prepush"];
const FULL = ["prepush-full", "local", "cloud-parity"];
const ALL_LOCAL = ["staged", "prepush", "prepush-full", "local", "cloud-parity"];

function hasAny(files, predicate) {
  return files.some(predicate);
}

function hasPathPrefix(files, prefix) {
  return files.some((file) => file.startsWith(prefix));
}

function stagedFileList(context, predicate) {
  return context.stagedFiles.filter(predicate);
}

function changedFileList(context, predicate) {
  return context.changedFiles.filter(predicate);
}

function packageForJsFile(file) {
  if (file.startsWith("services/chau7-relay/")) return "services/chau7-relay";
  if (file.startsWith("services/chau7-issues/")) return "services/chau7-issues";
  return "";
}

function packageBin(context, packageDir, bin) {
  const local = path.join(context.root, packageDir, "node_modules", ".bin", bin);
  return fs.existsSync(local) ? local : "";
}

async function runPackageBin(context, packageDir, bin, args) {
  const resolved = packageBin(context, packageDir, bin);
  if (!resolved) {
    return {
      status: "failed",
      summary: `${bin} is not installed in ${packageDir}. Run npm ci there before this gate.`,
    };
  }
  return context.exec(resolved, args, { cwd: packageDir });
}

async function runShellScript(context, script, args = [], options = {}) {
  return context.exec(script, args, {
    cwd: ".",
    env: options.env,
  });
}

function scanTextLines(files, getContent, rules) {
  const hits = [];
  for (const file of files) {
    const content = getContent(file);
    const lines = content.split(/\r?\n/);
    lines.forEach((line, index) => {
      for (const rule of rules) {
        if (rule.skip?.(file, line)) continue;
        if (rule.pattern.test(line)) {
          hits.push(`${file}:${index + 1} [${rule.id}] ${line.trim().slice(0, 160)}`);
        }
      }
    });
  }
  return hits;
}

function getIndexContent(context, file) {
  return context.git(["show", `:0:${file}`], { allowFailure: true }).stdout ?? "";
}

function getContextContent(context, file) {
  if (context.mode === "staged") return getIndexContent(context, file);
  const absolute = path.join(context.root, file);
  return fs.existsSync(absolute) ? fs.readFileSync(absolute, "utf8") : "";
}

function dependencyManifestFailures(context, files) {
  const failures = [];
  const changed = new Set(context.mode === "staged" ? context.stagedFiles : context.changedFiles);
  for (const file of files) {
    if (file.endsWith("package.json")) {
      let data;
      try {
        data = JSON.parse(getContextContent(context, file));
      } catch {
        failures.push(`${file}: invalid package.json`);
        continue;
      }
      const sections = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"];
      for (const section of sections) {
        for (const [name, version] of Object.entries(data[section] ?? {})) {
          if (typeof version !== "string") continue;
          if (/^(latest|\*|x)$/i.test(version) || /^[~^]/.test(version)) {
            failures.push(`${file}: ${section}.${name} uses unbounded/floating version '${version}'`);
          }
          if (/^(git\+|git:|github:|https?:|file:)/.test(version)) {
            failures.push(`${file}: ${section}.${name} uses remote/path dependency '${version}'`);
          }
        }
      }

      const lockfile = path.join(path.dirname(file), "package-lock.json").replaceAll(path.sep, "/");
      if (pathExists(path.join(context.root, lockfile)) && !changed.has(lockfile)) {
        failures.push(`${file}: matching ${lockfile} was not included in this validation scope`);
      }
    }

    if (/requirements.*\.txt$/.test(file)) {
      const content = getContextContent(context, file);
      content.split(/\r?\n/).forEach((line, index) => {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith("#")) return;
        if (!/[<>=!~]=/.test(trimmed)) {
          failures.push(`${file}:${index + 1}: Python dependency is unpinned/unbounded: ${trimmed}`);
        }
        if (/git\+|https?:\/\//.test(trimmed)) {
          failures.push(`${file}:${index + 1}: direct remote Python dependency requires allowlist: ${trimmed}`);
        }
      });
    }
  }
  return failures;
}

function trackedFiles(context) {
  return context.git(["ls-files"], { allowFailure: true }).stdout.split(/\r?\n/).filter(Boolean);
}

function trackedJsPackageDirs(context) {
  return trackedFiles(context)
    .filter((file) => file.endsWith("package-lock.json"))
    .map((file) => path.dirname(file))
    .filter((dir) => dir !== ".")
    .sort();
}

function trackedPythonDependencyFiles(context) {
  return trackedFiles(context).filter((file) => /(^|\/)(pyproject\.toml|requirements[^/]*\.txt)$/.test(file)).sort();
}

function secretFailures(context) {
  const diff = context.git(["diff", "--cached", "--unified=0", "--diff-filter=ACMR"], {
    allowFailure: true,
  }).stdout;
  const files = context.stagedFiles;
  const failures = [];

  for (const file of files) {
    const base = path.basename(file);
    if (/^\.env($|\.)/.test(base)) failures.push(`${file}: .env files must not be committed`);
    if (/\.(pem|key|p12|pfx|jks|keystore|mobileprovision|provisionprofile)$/i.test(base)) {
      failures.push(`${file}: credential-like file extension`);
    }
  }

  const rules = [
    { id: "private-key", pattern: /-----BEGIN (RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----/ },
    { id: "aws-access-key", pattern: /\bAKIA[0-9A-Z]{16}\b/ },
    { id: "github-token", pattern: /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{30,}\b/ },
    { id: "openai-key", pattern: /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b/ },
    { id: "slack-token", pattern: /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/ },
    { id: "bearer-token", pattern: /Bearer\s+[A-Za-z0-9._~+/=-]{32,}/ },
    { id: "generic-secret-assignment", pattern: /\b(?:secret|password|passwd|api[_-]?key|token)\b\s*[:=]\s*['"][^'"]{16,}['"]/i },
    { id: "pem-block", pattern: /-----BEGIN [A-Z ]+-----/ },
  ];

  for (const line of diff.split(/\r?\n/)) {
    if (!line.startsWith("+") || line.startsWith("+++")) continue;
    const added = line.slice(1);
    for (const rule of rules) {
      if (rule.pattern.test(added)) failures.push(`staged diff: ${rule.id} matched '${added.slice(0, 120)}'`);
    }
  }

  return failures;
}

function releaseTagFailures(context) {
  const failures = [];
  const releaseWorkflow = path.join(context.root, ".github/workflows/release.yml");
  const releaseText = fs.existsSync(releaseWorkflow) ? fs.readFileSync(releaseWorkflow, "utf8") : "";
  const requiresVPrefix = /^\s*-\s*['"]v\*['"]\s*$/m.test(releaseText);
  if (!requiresVPrefix) return failures;

  for (const update of context.prepushUpdates) {
    if (!update.localRef?.startsWith("refs/tags/")) continue;
    if (/^0+$/.test(update.localSha ?? "")) continue;
    const tag = update.localRef.replace("refs/tags/", "");
    if (/^[0-9]+(\.[0-9]+)*([.-][A-Za-z0-9][A-Za-z0-9.-]*)?$/.test(tag)) {
      failures.push(`Tag '${tag}' will not trigger release.yml; push 'v${tag}' instead.`);
    }
  }
  return failures;
}

export const gates = [
  {
    id: "quality-registry-schema",
    modes: ALL_LOCAL,
    scope: "repo",
    wave: "preflight",
    tags: ["quality", "registry"],
    cacheable: false,
    inputs: ["scripts/quality/registry.mjs", "scripts/quality/runner.mjs"],
    applies: () => true,
    rerun: "pnpm quality:local --include=quality-registry-schema",
    run: async (context) => {
      const errors = validateRegistry(context.allGates);
      return errors.length
        ? { status: "failed", summary: errors.join("\n") }
        : { status: "passed", summary: "registry contract valid" };
    },
  },
  {
    id: "prepush-dirty-worktree",
    modes: PREPUSH.concat(["prepush-full"]),
    scope: "repo",
    wave: "preflight",
    tags: ["git", "integrity"],
    cacheable: false,
    inputs: [],
    applies: (context) => context.mode === "prepush" || context.mode === "prepush-full",
    rerun: "pnpm quality:prepush --include=prepush-dirty-worktree",
    run: async (context) => context.checkDirtyWorktree(),
  },
  {
    id: "release-tag-trigger",
    modes: PREPUSH.concat(["prepush-full"]),
    scope: "changed",
    wave: "preflight",
    tags: ["release", "github-actions"],
    cacheable: false,
    inputs: [".github/workflows/release.yml"],
    applies: (context) => context.prepushUpdates.length > 0,
    rerun: "pnpm quality:prepush --include=release-tag-trigger",
    run: async (context) => {
      const failures = releaseTagFailures(context);
      return failures.length
        ? { status: "failed", summary: failures.join("\n") }
        : { status: "passed", summary: "release tag trigger contract valid" };
    },
  },
  {
    id: "staged-secret-scan",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "preflight",
    tags: ["security", "secrets"],
    cacheable: false,
    inputs: [],
    applies: (context) => context.stagedFiles.length > 0,
    rerun: "pnpm quality:staged --include=staged-secret-scan",
    run: async (context) => {
      const failures = secretFailures(context);
      return failures.length
        ? { status: "failed", summary: failures.join("\n") }
        : { status: "passed", summary: "no staged high-signal secrets found" };
    },
  },
  {
    id: "staged-dependency-policy",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "preflight",
    tags: ["dependencies", "security"],
    cacheable: false,
    inputs: [],
    applies: (context) =>
      hasAny(context.stagedFiles, (file) => file.endsWith("package.json") || /requirements.*\.txt$/.test(file)),
    rerun: "pnpm quality:staged --include=staged-dependency-policy",
    run: async (context) => {
      const files = stagedFileList(
        context,
        (file) => file.endsWith("package.json") || file.endsWith("package-lock.json") || /requirements.*\.txt$/.test(file),
      );
      const failures = dependencyManifestFailures(context, files);
      return failures.length
        ? { status: "failed", summary: failures.join("\n") }
        : { status: "passed", summary: "dependency manifests are bounded and lockfiles are staged" };
    },
  },
  {
    id: "staged-python-guardrails",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "static",
    tags: ["python", "security"],
    cacheable: false,
    inputs: ["scripts/ruff.toml"],
    applies: (context) => directTargetsForFiles(context.stagedFiles).python.length > 0,
    rerun: "pnpm quality:staged --include=staged-python-guardrails",
    run: async (context) => {
      const files = directTargetsForFiles(context.stagedFiles).python;
      const hits = scanTextLines(files, (file) => getIndexContent(context, file), [
        { id: "py/bare-except", pattern: /^\s*except\s*:/ },
        { id: "py/silent-except-pass", pattern: /^\s*except\b.*:\s*pass\s*(#.*)?$/ },
        { id: "py/placeholder", pattern: /\b(TODO|FIXME|pass|NotImplementedError)\b.*\b(placeholder|stub|implement later)\b/i },
        { id: "py/debugger", pattern: /\b(pdb\.set_trace|breakpoint\(\))\b/ },
      ]);
      return hits.length
        ? { status: "failed", summary: hits.join("\n") }
        : { status: "passed", summary: "python guardrails passed" };
    },
  },
  {
    id: "staged-python-ruff-fix",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "static",
    tags: ["python", "format", "autofix"],
    cacheable: false,
    inputs: ["scripts/ruff.toml"],
    applies: (context) => directTargetsForFiles(context.stagedFiles).python.length > 0,
    rerun: "pnpm quality:staged --include=staged-python-ruff-fix",
    run: async (context) => {
      const files = directTargetsForFiles(context.stagedFiles).python;
      const config = "scripts/ruff.toml";
      let result = await context.exec("ruff", ["check", "--fix", "--config", config, ...files]);
      if (result.status !== "passed") return result;
      result = await context.exec("ruff", ["format", "--config", config, ...files]);
      if (result.status !== "passed") return result;
      await context.exec("git", ["add", "--", ...files], { quiet: true });
      result = await context.exec("ruff", ["check", "--config", config, ...files]);
      if (result.status !== "passed") return result;
      return context.exec("ruff", ["format", "--check", "--config", config, ...files]);
    },
  },
  {
    id: "staged-js-format",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "static",
    tags: ["frontend", "format", "autofix"],
    cacheable: false,
    inputs: ["services/chau7-relay/.prettierrc.json"],
    applies: (context) =>
      directTargetsForFiles(context.stagedFiles).jsTs.some((file) => packageForJsFile(file) && !isGeneratedArtifact(file)),
    rerun: "pnpm quality:staged --include=staged-js-format",
    run: async (context) => {
      const filesByPackage = new Map();
      for (const file of directTargetsForFiles(context.stagedFiles).jsTs.filter((file) => !isGeneratedArtifact(file))) {
        const pkg = packageForJsFile(file);
        if (!pkg) continue;
        if (!filesByPackage.has(pkg)) filesByPackage.set(pkg, []);
        filesByPackage.get(pkg).push(path.relative(pkg, file).replaceAll(path.sep, "/"));
      }
      for (const [pkg, files] of filesByPackage) {
        let result = await runPackageBin(context, pkg, "prettier", ["--write", ...files]);
        if (result.status !== "passed") return result;
        await context.exec("git", ["add", "--", ...files.map((file) => path.join(pkg, file).replaceAll(path.sep, "/"))], {
          quiet: true,
        });
        result = await runPackageBin(context, pkg, "prettier", ["--check", ...files]);
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "prettier formatted and re-staged JS/TS files" };
    },
  },
  {
    id: "staged-js-security-guardrails",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "static",
    tags: ["frontend", "security"],
    cacheable: false,
    inputs: [],
    applies: (context) => directTargetsForFiles(context.stagedFiles).jsTs.length > 0,
    rerun: "pnpm quality:staged --include=staged-js-security-guardrails",
    run: async (context) => {
      const files = directTargetsForFiles(context.stagedFiles).jsTs;
      const hits = scanTextLines(files, (file) => getIndexContent(context, file), [
        { id: "js/console-debug", pattern: /^\s*console\.(log|debug|info|trace)\(/ },
        { id: "js/debugger", pattern: /^\s*debugger;?$/ },
        { id: "ts/as-any", pattern: /\bas\s+any\b/ },
        { id: "ts/suppression", pattern: /@ts-(ignore|nocheck)/ },
        { id: "js/eval", pattern: /\beval\s*\(/ },
        { id: "js/inner-html", pattern: /\binnerHTML\s*=/ },
      ]);
      return hits.length
        ? { status: "failed", summary: hits.join("\n") }
        : { status: "passed", summary: "JS/TS security and naming guardrails passed" };
    },
  },
  {
    id: "staged-legacy-guardrails",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "static",
    tags: ["legacy", "source-policy"],
    cacheable: false,
    inputs: ["scripts/check-anti-slop", "scripts/check-design-system", "scripts/check-docs-staged"],
    applies: (context) => context.stagedFiles.length > 0,
    rerun: "pnpm quality:staged --include=staged-legacy-guardrails",
    run: async (context) => {
      for (const script of ["./scripts/check-anti-slop", "./scripts/check-design-system", "./scripts/check-docs-staged"]) {
        const result = await runShellScript(context, script);
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "legacy staged guardrails passed through registered gate" };
    },
  },
  {
    id: "staged-shellcheck",
    modes: STAGED_ONLY,
    scope: "staged",
    wave: "static",
    tags: ["shell", "static"],
    cacheable: false,
    inputs: [],
    applies: (context) => directTargetsForFiles(context.stagedFiles).shell.some((file) => /\.(sh|bash)$/.test(file)),
    rerun: "pnpm quality:staged --include=staged-shellcheck",
    run: async (context) => {
      const files = directTargetsForFiles(context.stagedFiles).shell.filter((file) => /\.(sh|bash)$/.test(file));
      return context.exec("shellcheck", ["-x", ...files]);
    },
  },
  {
    id: "always-openapi-drift",
    modes: PREPUSH.concat(FULL),
    scope: "changed",
    wave: "preflight",
    tags: ["contracts", "generated"],
    cacheable: true,
    inputs: ["scripts/quality/registry.mjs"],
    applies: (context) => hasAny(context.changedFiles, (file) => /(^|\/)(openapi|swagger)(\/|\.)/.test(file)),
    rerun: "pnpm quality:prepush --include=always-openapi-drift",
    run: async () => ({
      status: "failed",
      summary: "OpenAPI or Swagger inputs changed, but no registered generator drift check exists yet.",
    }),
  },
  {
    id: "always-generated-artifact-drift",
    modes: PREPUSH.concat(FULL),
    scope: "changed",
    wave: "preflight",
    tags: ["generated", "contracts"],
    cacheable: true,
    inputs: ["scripts/quality/registry.mjs"],
    applies: (context) => hasAny(context.changedFiles, isGeneratedArtifact),
    rerun: "pnpm quality:prepush --include=always-generated-artifact-drift",
    run: async () => ({
      status: "failed",
      summary: "Generated artifact changed without a registered generator freshness gate.",
    }),
  },
  {
    id: "always-dependency-policy",
    modes: PREPUSH.concat(FULL),
    scope: "changed",
    wave: "preflight",
    tags: ["dependencies", "security"],
    cacheable: true,
    inputs: [
      "services/chau7-relay/package.json",
      "services/chau7-relay/package-lock.json",
      "services/chau7-issues/package.json",
      "services/chau7-issues/package-lock.json",
      "apps/chau7-macos/chau7-proxy/go.mod",
      "services/chau7-remote/go.mod",
      "apps/chau7-macos/rust/Cargo.toml",
      "apps/chau7-macos/rust/deny.toml",
    ],
    applies: (context) =>
      hasAny(context.changedFiles, (file) => /(package(-lock)?\.json|go\.(mod|sum)|Cargo\.(toml|lock)|deny\.toml)$/.test(file)),
    rerun: "pnpm quality:prepush --include=always-dependency-policy",
    run: async (context) => {
      const files = changedFileList(context, (file) => file.endsWith("package.json") || /requirements.*\.txt$/.test(file));
      const failures = dependencyManifestFailures(context, files);
      return failures.length
        ? { status: "failed", summary: failures.join("\n") }
        : { status: "passed", summary: "changed dependency manifests passed policy" };
    },
  },
  {
    id: "swift-macos-static-build",
    modes: PREPUSH,
    scope: "changed",
    wave: "build",
    tags: ["swift", "macos"],
    cacheable: true,
    inputs: ["apps/chau7-macos/Sources", "apps/chau7-macos/Tests", "apps/chau7-macos/Package.swift", "apps/chau7-macos/.swiftlint.yml", "apps/chau7-macos/.swiftformat"],
    applies: (context) => hasPathPrefix(context.changedFiles, "apps/chau7-macos/") && !hasPathPrefix(context.changedFiles, "apps/chau7-macos/rust/") && !hasPathPrefix(context.changedFiles, "apps/chau7-macos/chau7-proxy/"),
    rerun: "pnpm quality:prepush --include=swift-macos-static-build",
    run: async (context) => {
      for (const command of [
        ["swiftformat", ["Sources", "Tests", "--lint"]],
        ["swiftlint", ["lint", "--strict"]],
        ["/usr/bin/swift", ["build", "-Xswiftc", "-warnings-as-errors"]],
      ]) {
        const result = await context.exec(command[0], command[1], { cwd: "apps/chau7-macos" });
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "Swift macOS format, lint, and build passed" };
    },
  },
  {
    id: "swift-macos-tests",
    modes: PREPUSH,
    scope: "changed",
    wave: "tests",
    tags: ["swift", "tests"],
    cacheable: true,
    inputs: ["apps/chau7-macos/Sources", "apps/chau7-macos/Tests", "apps/chau7-macos/Package.swift"],
    applies: (context) => hasPathPrefix(context.changedFiles, "apps/chau7-macos/Sources/") || hasPathPrefix(context.changedFiles, "apps/chau7-macos/Tests/"),
    rerun: "pnpm quality:prepush --include=swift-macos-tests",
    run: async (context) => context.exec("/usr/bin/swift", ["test", "-Xswiftc", "-warnings-as-errors"], { cwd: "apps/chau7-macos" }),
  },
  {
    id: "rust-terminal-static",
    modes: PREPUSH,
    scope: "changed",
    wave: "static",
    tags: ["rust"],
    cacheable: true,
    inputs: ["apps/chau7-macos/rust"],
    applies: (context) => hasPathPrefix(context.changedFiles, "apps/chau7-macos/rust/"),
    rerun: "pnpm quality:prepush --include=rust-terminal-static",
    run: async (context) => {
      for (const command of [
        ["cargo", ["fmt", "--all", "--check"]],
        ["cargo", ["clippy", "--workspace", "--all-targets", "--all-features", "--", "-D", "warnings"]],
      ]) {
        const result = await context.exec(command[0], command[1], { cwd: "apps/chau7-macos/rust" });
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "Rust fmt and Clippy passed" };
    },
  },
  {
    id: "rust-terminal-tests",
    modes: PREPUSH,
    scope: "changed",
    wave: "tests",
    tags: ["rust", "tests"],
    cacheable: true,
    inputs: ["apps/chau7-macos/rust"],
    applies: (context) => hasPathPrefix(context.changedFiles, "apps/chau7-macos/rust/"),
    rerun: "pnpm quality:prepush --include=rust-terminal-tests",
    run: async (context) => context.exec("cargo", ["test", "--workspace", "--all-features"], { cwd: "apps/chau7-macos/rust" }),
  },
  {
    id: "go-proxy-static-tests",
    modes: PREPUSH,
    scope: "changed",
    wave: "tests",
    tags: ["go", "backend"],
    cacheable: true,
    inputs: ["apps/chau7-macos/chau7-proxy"],
    applies: (context) => hasPathPrefix(context.changedFiles, "apps/chau7-macos/chau7-proxy/"),
    rerun: "pnpm quality:prepush --include=go-proxy-static-tests",
    run: async (context) => {
      for (const command of [
        ["gofmt", ["-l"], "format"],
        ["go", ["vet", "./..."]],
        ["golangci-lint", ["run", "./..."]],
        ["go", ["test", "./..."]],
      ]) {
        if (command[2] === "format") {
          const files = changedFileList(context, (file) => file.startsWith("apps/chau7-macos/chau7-proxy/") && file.endsWith(".go"));
          if (files.length) {
            const result = await context.exec("gofmt", ["-l", ...files]);
            if (result.status !== "passed") return result;
            if (result.output.trim()) {
              return { status: "failed", summary: `gofmt reported unformatted files:\n${result.output.trim()}` };
            }
          }
          continue;
        }
        const result = await context.exec(command[0], command[1], { cwd: "apps/chau7-macos/chau7-proxy" });
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "Go proxy checks passed" };
    },
  },
  {
    id: "go-remote-static-tests",
    modes: PREPUSH,
    scope: "changed",
    wave: "tests",
    tags: ["go", "remote"],
    cacheable: true,
    inputs: ["services/chau7-remote"],
    applies: (context) => hasPathPrefix(context.changedFiles, "services/chau7-remote/"),
    rerun: "pnpm quality:prepush --include=go-remote-static-tests",
    run: async (context) => {
      const files = changedFileList(context, (file) => file.startsWith("services/chau7-remote/") && file.endsWith(".go"));
      if (files.length) {
        const format = await context.exec("gofmt", ["-l", ...files]);
        if (format.status !== "passed") return format;
        if (format.output.trim()) {
          return { status: "failed", summary: `gofmt reported unformatted files:\n${format.output.trim()}` };
        }
      }
      for (const command of [
        ["go", ["vet", "./..."]],
        ["golangci-lint", ["run", "./..."]],
        ["go", ["test", "./..."]],
      ]) {
        const result = await context.exec(command[0], command[1], { cwd: "services/chau7-remote" });
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "Go remote checks passed" };
    },
  },
  {
    id: "relay-typecheck-test-build",
    modes: PREPUSH,
    scope: "changed",
    wave: "tests",
    tags: ["frontend", "relay"],
    cacheable: true,
    inputs: ["services/chau7-relay/src", "services/chau7-relay/test", "services/chau7-relay/package.json", "services/chau7-relay/package-lock.json", "services/chau7-relay/tsconfig.json"],
    applies: (context) => classifyFrontendImpact(context.changedFiles).apps.includes("relay"),
    rerun: "pnpm quality:prepush --include=relay-typecheck-test-build",
    run: async (context) => {
      for (const args of [["run", "typecheck"], ["test"], ["run", "build"]]) {
        const result = await context.exec("npm", args, { cwd: "services/chau7-relay" });
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "relay typecheck, tests, and dry-run build passed" };
    },
  },
  {
    id: "issues-worker-build",
    modes: PREPUSH,
    scope: "changed",
    wave: "build",
    tags: ["frontend", "issues"],
    cacheable: true,
    inputs: ["services/chau7-issues/src", "services/chau7-issues/package.json", "services/chau7-issues/wrangler.toml"],
    applies: (context) => classifyFrontendImpact(context.changedFiles).apps.includes("issues"),
    rerun: "pnpm quality:prepush --include=issues-worker-build",
    run: async (context) => context.exec("npm", ["run", "build"], { cwd: "services/chau7-issues" }),
  },
  {
    id: "scripts-python-ruff",
    modes: PREPUSH,
    scope: "changed",
    wave: "static",
    tags: ["python"],
    cacheable: true,
    inputs: ["scripts", "scripts/ruff.toml"],
    applies: (context) => hasPathPrefix(context.changedFiles, "scripts/") && directTargetsForFiles(context.changedFiles).python.length > 0,
    rerun: "pnpm quality:prepush --include=scripts-python-ruff",
    run: async (context) => {
      const result = await context.exec("ruff", ["check", "--config", "scripts/ruff.toml", "scripts"]);
      if (result.status !== "passed") return result;
      return context.exec("ruff", ["format", "--check", "--config", "scripts/ruff.toml", "scripts"]);
    },
  },
  {
    id: "full-local-ci",
    modes: FULL,
    scope: "repo",
    wave: "tests",
    tags: ["full", "ci", "slow"],
    cacheable: false,
    inputs: ["scripts/ci-local", "scripts/ci-lib.sh", "scripts/.jscpd.json"],
    applies: () => true,
    rerun: "pnpm quality:prepush:full --include=full-local-ci",
    run: async (context) => runShellScript(context, "./scripts/ci-local"),
  },
  {
    id: "quality-runner-tests",
    modes: ["staged", "prepush-full", "local", "cloud-parity"],
    scope: "changed",
    wave: "tests",
    tags: ["quality", "tests"],
    cacheable: false,
    inputs: ["package.json", "scripts/quality", "scripts/git"],
    applies: (context) =>
      context.mode !== "staged" ||
      hasPathPrefix(context.stagedFiles, "scripts/quality/") ||
      hasPathPrefix(context.stagedFiles, "scripts/git/") ||
      context.stagedFiles.includes("package.json"),
    rerun: "pnpm quality:local --include=quality-runner-tests",
    run: async (context) => context.exec("pnpm", ["test"]),
  },
  {
    id: "full-js-dependency-audit",
    modes: FULL,
    scope: "repo",
    wave: "audit",
    tags: ["dependencies", "security", "audit", "frontend"],
    cacheable: false,
    inputs: [
      "services/chau7-relay/package.json",
      "services/chau7-relay/package-lock.json",
      "services/chau7-issues/package.json",
      "services/chau7-issues/package-lock.json",
    ],
    applies: (context) => trackedJsPackageDirs(context).length > 0,
    rerun: "pnpm quality:prepush:full --include=full-js-dependency-audit",
    run: async (context) => {
      for (const dir of trackedJsPackageDirs(context)) {
        const result = await context.exec("npm", ["audit", "--audit-level=high"], { cwd: dir });
        if (result.status !== "passed") return result;
      }
      return { status: "passed", summary: "npm audit passed at high severity threshold" };
    },
  },
  {
    id: "full-python-dependency-audit",
    modes: FULL,
    scope: "repo",
    wave: "audit",
    tags: ["dependencies", "security", "audit", "python"],
    cacheable: false,
    inputs: [],
    applies: (context) => trackedPythonDependencyFiles(context).length > 0,
    rerun: "pnpm quality:prepush:full --include=full-python-dependency-audit",
    run: async (context) => {
      // pip-audit's positional target is a project *directory* (it reads the
      // pyproject within), not the pyproject.toml file itself; requirements
      // files go through -r. Passing the pyproject.toml path directly fails
      // with "couldn't find a supported project file", so audit each tracked
      // file with the right form.
      for (const file of trackedPythonDependencyFiles(context)) {
        const args = /(^|\/)pyproject\.toml$/.test(file)
          ? ["--strict", path.dirname(file)]
          : ["--strict", "-r", file];
        const result = await context.exec("pip-audit", args);
        if (result.status !== "passed") {
          return {
            ...result,
            summary: `${result.summary}\nInstall pip-audit or fix the reported Python dependency vulnerabilities.`,
          };
        }
      }
      return { status: "passed", summary: "pip-audit passed at strict threshold" };
    },
  },
  {
    id: "quality-cloud-parity-release-only",
    modes: ["cloud-parity"],
    scope: "repo",
    wave: "preflight",
    tags: ["github-actions", "release"],
    cacheable: true,
    inputs: [".github/workflows/release.yml"],
    applies: () => true,
    rerun: "pnpm quality:cloud-parity --include=quality-cloud-parity-release-only",
    run: async (context) => {
      const workflows = fs.existsSync(path.join(context.root, ".github/workflows"))
        ? fs.readdirSync(path.join(context.root, ".github/workflows")).filter((file) => file.endsWith(".yml") || file.endsWith(".yaml"))
        : [];
      const nonRelease = workflows.filter((file) => file !== "release.yml");
      return nonRelease.length
        ? { status: "failed", summary: `GitHub Actions must remain release-only; found ${nonRelease.join(", ")}` }
        : { status: "passed", summary: "GitHub Actions are release-only" };
    },
  },
];

export function describeGate(gate) {
  return {
    id: gate.id,
    modes: gate.modes,
    scope: gate.scope,
    wave: gate.wave,
    tags: gate.tags,
    cacheable: gate.cacheable,
    inputs: gate.inputs,
    rerun: gate.rerun,
  };
}

export function registryDigest() {
  return gates.map(describeGate);
}
