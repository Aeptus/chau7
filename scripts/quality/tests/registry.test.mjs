import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { gates } from "../registry.mjs";
import { validateRegistry } from "../helpers.mjs";

function gate(id) {
  return gates.find((candidate) => candidate.id === id);
}

test("registry contract validates all gates", () => {
  assert.deepEqual(validateRegistry(gates), []);
});

test("staged Python autofix gate deliberately re-stages fixed files", async () => {
  const calls = [];
  const context = {
    mode: "staged",
    stagedFiles: ["scripts/example.py"],
    exec: async (command, args) => {
      calls.push([command, args]);
      return { status: "passed", summary: "ok", output: "" };
    },
  };

  const result = await gate("staged-python-ruff-fix").run(context);

  assert.equal(result.status, "passed");
  assert.ok(calls.some(([command, args]) => command === "git" && args[0] === "add"));
});

test("all cacheable gates declare explicit inputs", () => {
  const cacheableWithoutInputs = gates.filter((candidate) => candidate.cacheable && candidate.inputs.length === 0);
  assert.deepEqual(cacheableWithoutInputs.map((candidate) => candidate.id), []);
});

test("pre-push full includes the full local CI gate", () => {
  assert.ok(gate("full-local-ci").modes.includes("prepush-full"));
  assert.equal(gate("full-local-ci").scope, "repo");
});

test("quality runner tests are represented as a registry gate", () => {
  assert.ok(gate("quality-runner-tests").modes.includes("staged"));
  assert.ok(gate("quality-runner-tests").modes.includes("prepush-full"));
  assert.equal(gate("quality-runner-tests").wave, "tests");
});

test("quality runner tests clear inherited Git repository overrides", async () => {
  let command;
  let args;
  const result = await gate("quality-runner-tests").run({
    exec: async (nextCommand, nextArgs) => {
      command = nextCommand;
      args = nextArgs;
      return { status: "passed", summary: "ok" };
    },
  });

  assert.equal(result.status, "passed");
  assert.equal(command, "env");
  assert.deepEqual(args, [
    "-u",
    "GIT_DIR",
    "-u",
    "GIT_WORK_TREE",
    "-u",
    "GIT_COMMON_DIR",
    "-u",
    "GIT_INDEX_FILE",
    "-u",
    "GIT_PREFIX",
    "-u",
    "GIT_OBJECT_DIRECTORY",
    "-u",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "-u",
    "GIT_CONFIG_PARAMETERS",
    "-u",
    "GIT_CONFIG_COUNT",
    "pnpm",
    "test",
  ]);
});

for (const [id, wrapped, cwd] of [
  ["swift-macos-static-build", "/usr/bin/swift", "apps/chau7-macos"],
  ["swift-macos-tests", "/usr/bin/swift", "apps/chau7-macos"],
  ["ios-app-build", "xcodebuild", undefined],
  ["ios-app-tests", "xcodebuild", undefined],
  ["full-local-ci", "./scripts/ci-local", "."],
]) {
  // Hooks export GIT_DIR & co.; SwiftPM/xcodebuild dependency checkouts inherit
  // them and fail in a fresh worktree ("swift-atomics: unable to read tree").
  test(`${id} clears inherited Git repository overrides`, async () => {
    const calls = [];
    const result = await gate(id).run({
      exec: async (command, args, options) => {
        calls.push({ command, args, options });
        return { status: "passed", summary: "ok" };
      },
    });

    assert.equal(result.status, "passed");
    assert.ok(calls.length > 0);
    for (const call of calls) {
      assert.equal(call.command, "env");
      for (const name of ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"]) {
        const index = call.args.indexOf(name);
        assert.ok(index > 0 && call.args[index - 1] === "-u", `${id} must unset ${name}`);
      }
      assert.equal(call.options?.cwd, cwd);
    }
    assert.ok(calls.some((call) => call.args.includes(wrapped)), `${id} must still run ${wrapped}`);
  });
}

test("full-suite dependency audit gates are registered as live security gates", () => {
  assert.equal(gate("full-js-dependency-audit").cacheable, false);
  assert.equal(gate("full-js-dependency-audit").wave, "audit");
  assert.equal(gate("full-python-dependency-audit").cacheable, false);
  assert.equal(gate("full-python-dependency-audit").wave, "audit");
});

test("cloud parity requires release and pull request quality workflows", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-workflows-"));
  const workflowsDir = path.join(root, ".github/workflows");
  fs.mkdirSync(workflowsDir, { recursive: true });
  fs.writeFileSync(path.join(workflowsDir, "release.yml"), "name: Release\n");
  fs.writeFileSync(
    path.join(workflowsDir, "ci.yml"),
    [
      "name: CI",
      "on:",
      "  pull_request:",
      "jobs:",
      "  quality:",
      "    steps:",
      "      - name: Check workflow policy",
      "        run: pnpm quality:cloud-parity --include=quality-cloud-parity-required-workflows",
      "      - name: Run pre-push quality gates",
      "        run: pnpm quality:prepush",
      "      - name: Run staged quality gates",
      "        run: pnpm quality:staged",
      "",
    ].join("\n"),
  );

  try {
    const result = await gate("quality-cloud-parity-required-workflows").run({ root });
    assert.equal(result.status, "passed");

    fs.writeFileSync(path.join(workflowsDir, "preview.yml"), "name: Preview\n");
    assert.equal((await gate("quality-cloud-parity-required-workflows").run({ root })).status, "passed");

    fs.writeFileSync(path.join(workflowsDir, "ci.yml"), "name: CI\non:\n  push:\n");
    const incomplete = await gate("quality-cloud-parity-required-workflows").run({ root });
    assert.equal(incomplete.status, "failed");
    assert.match(incomplete.summary, /pull_request trigger/);
    assert.match(incomplete.summary, /pnpm quality:staged/);
    assert.match(incomplete.summary, /pnpm quality:prepush/);

    fs.rmSync(path.join(workflowsDir, "ci.yml"));
    const missing = await gate("quality-cloud-parity-required-workflows").run({ root });
    assert.equal(missing.status, "failed");
    assert.match(missing.summary, /ci\.yml/);

    fs.writeFileSync(
      path.join(workflowsDir, "ci.yml"),
      [
        "name: CI",
        "on:",
        "  pull_request:",
        "jobs:",
        "  quality:",
        "    steps:",
        "      - name: Run pre-push quality gates",
        "        run: pnpm quality:prepush",
        "      - name: Run staged quality gates",
        "        run: pnpm quality:staged",
        "",
      ].join("\n"),
    );
    fs.rmSync(path.join(workflowsDir, "release.yml"));
    const missingRelease = await gate("quality-cloud-parity-required-workflows").run({ root });
    assert.equal(missingRelease.status, "failed");
    assert.match(missingRelease.summary, /release\.yml/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("security gates are blocking registered gates, not hook-only shell snippets", () => {
  assert.equal(gate("staged-secret-scan").wave, "preflight");
  assert.ok(gate("staged-dependency-policy").tags.includes("security"));
  assert.ok(gate("staged-legacy-guardrails").inputs.includes("scripts/check-forbidden-files"));
});

test("staged secret gate runs Gitleaks against the staged diff", async () => {
  let invocation;
  const result = await gate("staged-secret-scan").run({
    mode: "staged",
    stagedFiles: ["probe.txt"],
    git: () => ({ stdout: "" }),
    exec: async (command, args) => {
      invocation = [command, args];
      return { status: "passed", summary: "clean" };
    },
  });

  assert.equal(result.status, "passed");
  assert.deepEqual(invocation, ["gitleaks", ["git", "--pre-commit", "--staged", "--redact", "--no-banner"]]);
  assert.match(result.summary, /Gitleaks passed/);
});

test("staged secret gate fails closed when Gitleaks is missing or fails", async () => {
  const result = await gate("staged-secret-scan").run({
    mode: "staged",
    stagedFiles: ["probe.txt"],
    git: () => ({ stdout: "" }),
    exec: async () => ({ status: "failed", summary: "gitleaks is not installed" }),
  });

  assert.equal(result.status, "failed");
  assert.match(result.summary, /Gitleaks staged scan failed/);
});

test("staged forbidden-file guard runs through the registered legacy gate", async () => {
  const calls = [];
  const result = await gate("staged-legacy-guardrails").run({
    mode: "staged",
    stagedFiles: ["scripts/example.sh"],
    exec: async (command) => {
      calls.push(command);
      return { status: "passed", summary: "ok" };
    },
  });

  assert.equal(result.status, "passed");
  assert.equal(calls[0], "./scripts/check-forbidden-files");
});

test("pre-commit review is a live registered staged gate", async () => {
  const candidate = gate("staged-precommit-review");
  let invocation;
  const result = await candidate.run({
    root: "/repo",
    mode: "staged",
    stagedFiles: ["Sources/App.swift"],
    exec: async (command, args, options) => {
      invocation = [command, args, options.cwd];
      return { status: "passed", summary: "review skipped because Chau7 is unavailable" };
    },
  });

  assert.ok(candidate.modes.includes("staged"));
  assert.equal(candidate.cacheable, false);
  assert.equal(candidate.applies({ stagedFiles: ["Sources/App.swift"] }), true);
  assert.equal(result.status, "passed");
  assert.deepEqual(invocation, ["./scripts/pre-commit-review", [], "."]);
});

async function scanStagedLine(line) {
  const result = await gate("staged-secret-scan").run({
    mode: "staged",
    stagedFiles: ["probe.txt"],
    git: () => ({ stdout: `--- a/probe.txt\n+++ b/probe.txt\n@@ -0,0 +1 @@\n${line}\n` }),
    exec: async () => ({ status: "passed", summary: "clean" }),
  });
  return /home-path-leak/.test(result.summary ?? "");
}

test("staged secret scan blocks absolute home directory paths", async () => {
  // Regression guard for docs/recovered-tab-session-backup-2026-04-15.json,
  // which was published with the maintainer's real home directory, repository
  // paths, and tab/session identifiers in a repo that markets local-only privacy.
  //
  // Account names are interpolated instead of written out in full because the
  // staged secret scan blocks real-looking home paths in *any* staged text,
  // including this file. Keep them as separate segments — writing the literal
  // path here would make the rule fail on its own regression test.
  for (const account of ["christophehenner", "johndoe", "someuser"]) {
    assert.equal(
      await scanStagedLine(`+  "log": "/Users/${account}/Library/Logs/Chau7.log",`),
      true,
      `expected a home-path-leak failure for account: ${account}`,
    );
    assert.equal(
      await scanStagedLine(`+  path = "/home/${account}/srv/app"`),
      true,
      `expected a home-path-leak failure for /home/${account}`,
    );
  }
});

test("staged secret scan allows documented placeholders, CI paths, and test fixtures", async () => {
  // Guards the false-positive surface discovered when the rule was introduced:
  // an over-broad home-path rule trains contributors to reach for --no-verify.
  const allowed = [
    '+  path = "/Users/Shared/Public"',
    '+  path = "/Users/yourname/project"',
    '+  path = "/Users/username/project"',
    '+  path = "/Users/<name>/project"',
    '+  path = "/Users/$USER/project"',
    '+  path = "/Users/me/Downloads"',
    '+  path = "/Users/dev/project"',
    '+  path = "/Users/alice/project"',
    '+  path = "/home/bob/project"',
    '+  path = "/Users/foo/project"',
    '+  path = "/Users/x/project"',
    '+  let wrapperDir = "/home/.chau7/cto_bin"',
    '+  path = "/home/linuxbrew/.linuxbrew/bin/wrangler"',
    '+  path = "/opt/homebrew/bin/brew"',
    '+  path = "/home/runner/work/repo/repo"',
  ];
  for (const line of allowed) {
    assert.equal(await scanStagedLine(line), false, `expected no home-path-leak failure for: ${line}`);
  }
});

test("root runner JavaScript is not silently formatted without a package formatter", () => {
  assert.equal(
    gate("staged-js-format").applies({
      stagedFiles: ["scripts/quality/runner.mjs"],
    }),
    false,
  );
});

test("unregistered generated contract drift fails closed", async () => {
  const openapi = await gate("always-openapi-drift").run({});
  const generated = await gate("always-generated-artifact-drift").run({});

  assert.equal(openapi.status, "failed");
  assert.match(openapi.summary, /no registered generator/);
  assert.equal(generated.status, "failed");
  assert.match(generated.summary, /Generated artifact changed/);
});

test("staged dependency policy allows scripts-only package edits with the existing lockfile", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-policy-"));
  const packageDir = path.join(root, "pkg");
  fs.mkdirSync(packageDir);
  const manifest = {
    name: "pkg",
    scripts: { test: "node --test" },
    devDependencies: { prettier: "3.8.2" },
  };
  const lockfile = {
    name: "pkg",
    lockfileVersion: 3,
    packages: {
      "": { name: "pkg", devDependencies: { prettier: "3.8.2" } },
    },
  };
  const indexedFiles = new Map([
    ["pkg/package.json", JSON.stringify(manifest)],
    ["pkg/package-lock.json", JSON.stringify(lockfile)],
  ]);
  fs.writeFileSync(path.join(packageDir, "package.json"), JSON.stringify(manifest));
  fs.writeFileSync(path.join(packageDir, "package-lock.json"), JSON.stringify(lockfile));

  try {
    const result = await gate("staged-dependency-policy").run({
      root,
      mode: "staged",
      stagedFiles: ["pkg/package.json"],
      git: (args) => {
        if (args[0] === "ls-files") return { stdout: indexedFiles.has(args[2]) ? args[2] : "" };
        const spec = args[1];
        const file = typeof spec === "string" && spec.startsWith(":0:") ? spec.slice(3) : "";
        return { stdout: indexedFiles.get(file) ?? "" };
      },
    });

    assert.equal(result.status, "passed");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("staged dependency policy rejects dependency drift until the lockfile matches", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-policy-"));
  const packageDir = path.join(root, "pkg");
  fs.mkdirSync(packageDir);
  const manifest = { name: "pkg", devDependencies: { prettier: "3.8.3" } };
  const staleLockfile = {
    lockfileVersion: 3,
    packages: { "": { name: "pkg", devDependencies: { prettier: "3.8.2" } } },
  };
  const indexedFiles = new Map([
    ["pkg/package.json", JSON.stringify(manifest)],
    ["pkg/package-lock.json", JSON.stringify(staleLockfile)],
  ]);
  fs.writeFileSync(path.join(packageDir, "package.json"), JSON.stringify(manifest));

  try {
    const run = (stagedFiles) =>
      gate("staged-dependency-policy").run({
        root,
        mode: "staged",
        stagedFiles,
        git: (args) => {
          if (args[0] === "ls-files") {
            const file = args[2];
            return { stdout: indexedFiles.has(file) ? file : "" };
          }
          const spec = args[1];
          const file = typeof spec === "string" && spec.startsWith(":0:") ? spec.slice(3) : "";
          return { stdout: indexedFiles.get(file) ?? "" };
        },
      });

    const stale = await run(["pkg/package.json"]);
    assert.equal(stale.status, "failed");
    assert.match(stale.summary, /does not match/);

    const updatedLockfile = {
      lockfileVersion: 3,
      packages: { "": { name: "pkg", devDependencies: { prettier: "3.8.3" } } },
    };
    indexedFiles.set("pkg/package-lock.json", JSON.stringify(updatedLockfile));
    const synchronized = await run(["pkg/package.json", "pkg/package-lock.json"]);
    assert.equal(synchronized.status, "passed");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("dependency policy accepts a manifest when its lockfile is in scope", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-policy-"));
  fs.mkdirSync(path.join(root, "pkg"));
  fs.writeFileSync(
    path.join(root, "pkg/package.json"),
    JSON.stringify({ name: "pkg", devDependencies: { prettier: "3.8.2" } }),
  );
  fs.writeFileSync(
    path.join(root, "pkg/package-lock.json"),
    JSON.stringify({
      lockfileVersion: 3,
      packages: { "": { name: "pkg", devDependencies: { prettier: "3.8.2" } } },
    }),
  );

  const result = await gate("always-dependency-policy").run({
    root,
    mode: "prepush",
    changedFiles: ["pkg/package.json", "pkg/package-lock.json"],
  });

  assert.equal(result.status, "passed");
});

test("staged dependency policy ignores a lockfile present only in the worktree", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-index-"));
  fs.mkdirSync(path.join(root, "pkg"));
  fs.writeFileSync(path.join(root, "pkg/package-lock.json"), "{}\n");
  try {
    const result = await gate("staged-dependency-policy").run({
      root,
      mode: "staged",
      stagedFiles: ["pkg/package.json"],
      git: (args) => ({
        stdout: args[0] === "show" && args[1] === ":0:pkg/package.json"
          ? JSON.stringify({ name: "pkg", scripts: { test: "node --test" } })
          : "",
      }),
    });
    assert.equal(result.status, "passed", result.summary);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("lockfile-only staged dependency drift fails until its indexed manifest matches", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-lock-only-"));
  const indexed = new Map([
    ["pkg/package.json", JSON.stringify({ devDependencies: { prettier: "3.8.2" } })],
    ["pkg/package-lock.json", JSON.stringify({ packages: { "": { devDependencies: { prettier: "3.8.3" } } } })],
  ]);
  const context = {
    root,
    mode: "staged",
    stagedFiles: ["pkg/package-lock.json"],
    git: (args) => ({
      stdout: args[0] === "ls-files" ? (indexed.has(args[2]) ? args[2] : "") : (indexed.get(args[1].slice(3)) ?? ""),
    }),
  };
  try {
    const policy = gate("staged-dependency-policy");
    assert.equal(policy.applies(context), true);
    const drift = await policy.run(context);
    assert.equal(drift.status, "failed");
    assert.match(drift.summary, /does not match/);
    indexed.set("pkg/package.json", JSON.stringify({ devDependencies: { prettier: "3.8.3" } }));
    assert.equal((await policy.run(context)).status, "passed");
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});


test("iOS tests use the prepared simulator destination and include it in the cache contract", async () => {
  const previous = process.env.CHAU7_IOS_TEST_DESTINATION;
  const destination = "platform=iOS Simulator,id=12345678-1234-1234-1234-123456789abc";
  process.env.CHAU7_IOS_TEST_DESTINATION = destination;
  let args;
  try {
    const result = await gate("ios-app-tests").run({ exec: async (command, nextArgs) => {
      args = nextArgs;
      return { status: "passed", summary: "ok" };
    } });
    assert.equal(result.status, "passed");
    assert.equal(args[args.indexOf("-destination") + 1], destination);
    assert.deepEqual(gate("ios-app-tests").cacheEnv, ["CHAU7_IOS_TEST_DESTINATION"]);
  } finally {
    if (previous === undefined) delete process.env.CHAU7_IOS_TEST_DESTINATION;
    else process.env.CHAU7_IOS_TEST_DESTINATION = previous;
  }
});


test("iOS tests cover simulator preparation and shared CI configuration changes", () => {
  const ios = gate("ios-app-tests");
  for (const file of ["scripts/quality/ios-simulator.mjs", "scripts/quality/registry.mjs", ".github/workflows/ci.yml"]) {
    assert.equal(ios.applies({ changedFiles: [file] }), true);
  }
  assert.equal(ios.applies({ changedFiles: ["services/chau7-remote/go.mod"] }), false);
  assert.ok(ios.inputs.includes("scripts/quality/ios-simulator.mjs"));
});

for (const id of ["go-proxy-static-tests", "go-remote-static-tests"]) {
  test(`${id} executes the race detector`, async () => {
    const calls = [];
    const result = await gate(id).run({ changedFiles: [], exec: async (command, args, options) => {
      calls.push({ command, args, options });
      return { status: "passed", output: "" };
    }});
    assert.equal(result.status, "passed");
    assert.ok(calls.some(({command, args}) => command === "go" && args.join(" ") === "test -race ./..."));
  });
}

test("Go audit visits both modules live and fails closed on scanner errors", async () => {
  const audit = gate("go-dependency-audit");
  assert.equal(audit.cacheable, false);
  assert.ok(audit.modes.includes("prepush"));
  assert.ok(audit.modes.includes("prepush-full"));
  const calls = [];
  const context = {exec: async (command,args,options) => { calls.push({command,args,options});return {status:"passed"}; }};
  assert.equal((await audit.run(context)).status,"passed");
  assert.deepEqual(calls.map(x=>x.options.cwd),["apps/chau7-macos/chau7-proxy","services/chau7-remote"]);
  assert.ok(calls.every(x=>x.command === "go" && x.args.includes("golang.org/x/vuln/cmd/govulncheck@v1.8.0")));
  for (const cwd of calls.map(x=>x.options.cwd)) {
    const result = await audit.run({exec: async (_,__,options) => options.cwd === cwd ? {status:"failed",summary:"database unavailable"} : {status:"passed"}});
    assert.equal(result.status,"failed");
    assert.match(result.summary,/cannot be skipped/);
  }
});

for (const [id, cwd, checks] of [
  ["relay-typecheck-test-build", "services/chau7-relay", [["run", "typecheck"], ["test"], ["run", "build"]]],
  ["issues-worker-build", "services/chau7-issues", [["run", "build"]]],
]) {
  test(`${id} validates a fresh checkout using locked local dependencies`, async () => {
    let installed = false;
    const validated = [];
    const result = await gate(id).run({
      exec: async (command, args, options) => {
        assert.equal(command, "npm");
        assert.equal(options.cwd, cwd);
        if (args[0] === "ci") {
          assert.deepEqual(args, ["ci", "--no-audit", "--no-fund"]);
          installed = true;
          return { status: "passed" };
        }
        if (!installed) return { status: "failed", summary: "local tools absent on fresh checkout" };
        validated.push(args);
        return { status: "passed" };
      },
    });
    assert.equal(result.status, "passed", result.summary);
    assert.deepEqual(validated, checks);
    assert.ok(gate(id).inputs.includes(`${cwd}/package-lock.json`));
  });

  test(`${id} fails closed when locked dependency installation fails`, async () => {
    const calls = [];
    const result = await gate(id).run({
      exec: async (_, args) => {
        calls.push(args);
        return args[0] === "ci"
          ? { status: "failed", summary: "lockfile installation failed" }
          : { status: "passed" };
      },
    });
    assert.equal(result.status, "failed");
    assert.equal(result.summary, "lockfile installation failed");
    assert.equal(calls.length, 1, "validation must not use pre-existing tools after failed installation");
  });

  test(`${id} propagates package validation failure after installation`, async () => {
    const failed = { status: "failed", summary: "package validation failed" };
    const calls = [];
    const result = await gate(id).run({
      exec: async (_, args) => {
        calls.push(args);
        return args[0] === "ci" ? { status: "passed" } : failed;
      },
    });
    assert.equal(result, failed);
    assert.equal(calls.length, 2);
  });
}


for (const pkg of ["services/chau7-relay", "services/chau7-issues"]) {
  for (const scenario of ["fresh", "existing", "installation fails", "installation leaves tool missing"]) {
    test(`staged formatter: ${pkg} ${scenario}`, async () => {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-formatter-bootstrap-"));
      const bin = path.join(root, pkg, "node_modules", ".bin", "prettier");
      const install = () => {
        fs.mkdirSync(path.dirname(bin), { recursive: true });
        fs.writeFileSync(bin, "fixture tool");
      };
      const calls = [];
      if (scenario === "existing") install();
      try {
        const result = await gate("staged-js-format").run({
          root,
          stagedFiles: [`${pkg}/src/worker.js`],
          exec: async (command, args, options) => {
            calls.push({ command, args, options });
            if (command === "npm") {
              assert.deepEqual(args, ["ci", "--no-audit", "--no-fund"]);
              assert.equal(options.cwd, pkg);
              if (scenario === "installation fails") return { status: "failed", summary: "locked install failed" };
              if (scenario === "fresh") install();
            } else if (command !== "git") {
              assert.equal(command, bin);
              assert.ok(fs.existsSync(bin), "formatting must use an installed package tool");
            }
            return { status: "passed" };
          },
        });
        if (scenario === "installation fails") {
          assert.equal(result.status, "failed");
          assert.equal(result.summary, "locked install failed");
          assert.deepEqual(calls.map(x => x.command), ["npm"]);
        } else if (scenario === "installation leaves tool missing") {
          assert.equal(result.status, "failed");
          assert.match(result.summary, /prettier is not installed/);
          assert.deepEqual(calls.map(x => x.command), ["npm"]);
        } else {
          assert.equal(result.status, "passed", result.summary);
          const formatting = calls.filter(x => x.command === bin);
          assert.deepEqual(formatting.map(x => x.args), [["--write", "src/worker.js"], ["--check", "src/worker.js"]]);
          assert.ok(calls.some(x => x.command === "git" && x.args[0] === "add"));
          assert.equal(calls.filter(x => x.command === "npm").length, scenario === "fresh" ? 1 : 0);
        }
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });
  }
}
