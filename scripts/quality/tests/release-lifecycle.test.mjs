import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const script = path.join(source, "scripts/release/signing-keychain.sh");
function fixture(t, fail = "") {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-release-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const bin = path.join(root, "bin"); fs.mkdirSync(bin);
  const log = path.join(root, "commands");
  fs.writeFileSync(path.join(bin, "security"), `#!/bin/bash
printf '%s\\n' "$*" >> "$RELEASE_TEST_LOG"
case "$1" in
  list-keychains) if [[ "$*" != *' -s '* ]]; then echo '    "fixture-login.keychain-db"'; fi ;;
  create-keychain) touch "${'$'}{@: -1}" ;;
  delete-keychain) rm -f "$2" ;;
esac
if [[ "$1" == "$RELEASE_TEST_FAIL" ]]; then exit 42; fi
`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, "xcrun"), '#!/bin/sh\nprintf "%s\\n" "$*" >> "$RELEASE_TEST_LOG"\n', { mode: 0o755 });
  const env = { ...process.env, RUNNER_TEMP: root, PATH: `${bin}${path.delimiter}${process.env.PATH}`, RELEASE_TEST_LOG: log, RELEASE_TEST_FAIL: fail,
    APPLE_CERTIFICATE_P12: Buffer.from("fake certificate").toString("base64"), APPLE_CERTIFICATE_PASSWORD: "fixture", APPLE_ID: "fixture@example.invalid", APPLE_ID_PASSWORD: "fixture", APPLE_TEAM_ID: "fixture" };
  const run = (command) => spawnSync("/bin/bash", [script, command], { env, encoding: "utf8" });
  return { root, env, log, run };
}
test("signing setup restricts key access and cleanup removes all temporary material", (t) => {
  const f = fixture(t); const setup = f.run("setup"); assert.equal(setup.status, 0, setup.stderr);
  const directory = path.join(f.root, "chau7-signing");
  assert.equal(fs.existsSync(path.join(directory, "certificate.p12")), false);
  const password = fs.readFileSync(path.join(directory, "password"), "utf8").trim(); assert.equal(password.length, 64);
  assert.equal(fs.statSync(path.join(directory, "password")).mode & 0o777, 0o600);
  const commands = fs.readFileSync(f.log, "utf8"); assert.match(commands, /-T \/usr\/bin\/codesign/); assert.doesNotMatch(commands, /(?:^| )-A(?: |$)/m); assert.match(commands, /store-credentials/);
  assert.equal(f.run("cleanup").status, 0); assert.equal(fs.existsSync(directory), false); assert.match(fs.readFileSync(f.log, "utf8"), /list-keychains -d user -s fixture-login.keychain-db/);
  assert.equal(f.run("cleanup").status, 0); // Always-cleanup is idempotent after setup failure/cancellation.
});
test("failed certificate import restores search list and removes keychain and password", (t) => {
  const f = fixture(t, "import"); assert.equal(f.run("setup").status, 42); assert.equal(fs.existsSync(path.join(f.root, "chau7-signing")), false); assert.match(fs.readFileSync(f.log, "utf8"), /delete-keychain/); assert.equal(f.run("cleanup").status, 0);
});
test("cancellation invokes the same cleanup path without real signing assets", (t) => {
  const f = fixture(t); assert.equal(f.run("setup").status, 0);
  const result = spawnSync("/bin/bash", ["-c", `trap 'bash "$SIGNING_SCRIPT" cleanup; exit 143' TERM; kill -TERM $$`], { env: { ...f.env, SIGNING_SCRIPT: script }, encoding: "utf8" });
  assert.equal(result.status, 143); assert.equal(fs.existsSync(path.join(f.root, "chau7-signing")), false);
});
function workflowJobs() {
  const workflow = fs.readFileSync(path.join(source, ".github/workflows/release.yml"), "utf8");
  const jobs = {};
  for (const match of workflow.slice(workflow.indexOf("\njobs:\n")).matchAll(/^  ([a-z][a-z0-9-]+):\n([\s\S]*?)(?=^  [a-z][a-z0-9-]+:\n|(?![\s\S]))/gm)) jobs[match[1]] = match[2];
  return { workflow, jobs };
}

test("release builds the Rust production bundle once without secrets and reuses it", () => {
  const { workflow, jobs } = workflowJobs();
  assert.deepEqual(Object.keys(jobs), ["preflight", "build", "publish", "update-homebrew-tap", "rust-production-rc-sign"]);
  assert.match(workflow, /tags: \['v\*'\]/);
  assert.match(workflow, /permissions:\n  contents: read/);
  assert.match(workflow, /cancel-in-progress: false/);
  assert.doesNotMatch(workflow, /build-dist\.sh|swift (build|test)|apps\/chau7-macos/);
  assert.equal((workflow.match(/run: \.\/scripts\/bundle-macos\.sh/g) ?? []).length, 1);
  for (const id of ["preflight", "build"]) assert.doesNotMatch(jobs[id], /secrets\./, id);
  assert.match(jobs.build, /CHANNEL: production/);
  assert.match(jobs.build, /RELEASE_VERSION: \$\{\{ needs\.preflight\.outputs\.version \}\}/);
  assert.match(jobs.build, /rust-production-candidate-unsigned/);
  for (const id of ["publish", "rust-production-rc-sign"]) {
    assert.doesNotMatch(jobs[id], /cargo build|bundle-macos\.sh/, id);
    assert.match(jobs[id], /tar -xf.*rust-production-candidate\.tar/, id);
    assert.match(jobs[id], /require-signing-secrets\.sh/, id);
    assert.match(jobs[id], /sign-rust-production\.sh/, id);
    assert.match(jobs[id], /if: always\(\)\n        run: \.\/scripts\/release\/signing-keychain\.sh cleanup/, id);
    assert.match(jobs[id], /actions\/attest-build-provenance/, id);
  }
  for (const match of workflow.matchAll(/uses: (.+)/g)) assert.match(match[1], /@[a-f0-9]{40}(?: |$)/);
  assert.equal((workflow.match(/timeout-minutes:/g) ?? []).length, 5);
});

test("only a v tag publishes, signs as stable, and feeds the Homebrew cask", () => {
  const { jobs } = workflowJobs();
  assert.match(jobs.publish, /if: needs\.preflight\.outputs\.stage == 'stable' && github\.event_name == 'push' && startsWith\(github\.ref, 'refs\/tags\/v'\)/);
  assert.match(jobs.publish, /contents: write/);
  assert.match(jobs.publish, /RELEASE_STAGE: stable/);
  assert.match(jobs.publish, /softprops\/action-gh-release/);
  assert.match(jobs.publish, /Chau7-AppleSilicon\.dmg/);
  assert.match(jobs.publish, /extract-changelog/);
  assert.match(jobs["update-homebrew-tap"], /needs: \[preflight, publish\]/);
  assert.match(jobs["update-homebrew-tap"], /releases\/download\/v#\{version\}\/Chau7-AppleSilicon\.dmg/);
  assert.match(jobs["update-homebrew-tap"], /app "Chau7\.app"/);
});

test("Rust production RC stays manual, versioned, signed, and artifact-only", () => {
  const { workflow, jobs } = workflowJobs();
  assert.match(workflow, /release_channel:[\s\S]*?default: production-dry-run[\s\S]*?rust-production-rc/);
  assert.match(workflow, /default: 0\.6\.0-rc\.1/);
  assert.match(jobs.preflight, /RUST_PRODUCTION_MIGRATION_VALIDATED/);
  assert.match(jobs.preflight, /refs\/heads\/main/);
  assert.match(jobs.preflight, /RELEASE_VERSION: \$\{\{ inputs\.release_version \}\}/);
  const rc = jobs["rust-production-rc-sign"];
  assert.match(rc, /if: needs\.preflight\.outputs\.stage == 'rc' && github\.event_name == 'workflow_dispatch'/);
  assert.match(rc, /RELEASE_STAGE: rc/);
  assert.match(rc, /rust-production-rc-\$\{\{ github\.run_number \}\}/);
  assert.doesNotMatch(rc, /softprops\/action-gh-release|contents:\s*write|HOMEBREW_TAP_TOKEN/);
});

function runResolve(env) {
  const { jobs } = workflowJobs();
  const script = jobs.preflight.match(/- name: Resolve stage and version[\s\S]*?run: \|\n([\s\S]*)$/)[1]
    .split("\n").map((line) => line.replace(/^ {10}/, "")).join("\n");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-release-resolve-"));
  try {
    const output = path.join(root, "output");
    const result = spawnSync("/bin/bash", ["-e", "-c", script], { env: { ...process.env, GITHUB_OUTPUT: output, ...env }, encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, output: fs.existsSync(output) ? fs.readFileSync(output, "utf8") : "" };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("preflight resolves stable tags, dry runs and gated RCs", () => {
  const stable = runResolve({ EVENT_NAME: "push", REF: "refs/tags/v0.7.0", REF_NAME: "v0.7.0" });
  assert.equal(stable.status, 0); assert.match(stable.output, /stage=stable\nversion=0\.7\.0/);
  assert.notEqual(runResolve({ EVENT_NAME: "push", REF: "refs/tags/vnext", REF_NAME: "vnext" }).status, 0);
  const dry = runResolve({ EVENT_NAME: "workflow_dispatch", REF: "refs/heads/feature", CHANNEL: "production-dry-run" });
  assert.equal(dry.status, 0); assert.match(dry.output, /stage=dry-run\nversion=0\.0\.0-dry-run/);
  const rcEnv = { EVENT_NAME: "workflow_dispatch", REF: "refs/heads/main", CHANNEL: "rust-production-rc", RELEASE_VERSION: "0.6.0-rc.1", ACKNOWLEDGEMENT: "RUST_PRODUCTION_MIGRATION_VALIDATED" };
  const rc = runResolve(rcEnv);
  assert.equal(rc.status, 0); assert.match(rc.output, /stage=rc\nversion=0\.6\.0-rc\.1/);
  assert.notEqual(runResolve({ ...rcEnv, REF: "refs/heads/feature" }).status, 0);
  assert.notEqual(runResolve({ ...rcEnv, ACKNOWLEDGEMENT: "not-validated" }).status, 0);
  assert.notEqual(runResolve({ ...rcEnv, RELEASE_VERSION: "next" }).status, 0);
});

test("Rust production manifest refresh hashes the seven final executables", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-rust-manifest-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const app = path.join(root, "Chau7.app");
  const macos = path.join(app, "Contents", "MacOS");
  fs.mkdirSync(macos, { recursive: true });
  const executablePaths = {
    Chau7: "Contents/MacOS/Chau7",
    "chau7-next-mcp-bridge": "Contents/MacOS/chau7-next-mcp-bridge",
    "chau7-next-cli": "Contents/MacOS/chau7-next-cli",
    "chau7-optim": "Contents/MacOS/chau7-optim",
    "chau7-md": "Contents/MacOS/chau7-md",
    "chau7-remote": "Contents/MacOS/chau7-remote",
    "chau7-proxy": "Contents/MacOS/chau7-proxy",
  };
  for (const [name, relative] of Object.entries(executablePaths)) {
    const binary = path.join(app, relative);
    fs.writeFileSync(binary, `signed fixture: ${name}\n`);
    fs.chmodSync(binary, 0o755);
  }
  const manifestPath = path.join(root, "Chau7-Production-aarch64-apple-darwin-fast.json");
  const manifest = {
    channel: "production",
    bundleIdentifier: "com.chau7.app",
    bundlePath: "Chau7.app",
    appExecutable: "Chau7",
    cargoFeatures: ["chau7_next_core/production"],
    sourceDirty: false,
    releaseVersion: "0.6.0-rc.1",
    version: "0.6.0",
    cargoPackageVersion: "0.1.0",
    buildNumber: "123",
    cargoCommands: { app: ["cargo", "build", "--locked", "--features", "chau7_next_core/production"] },
    artifacts: Object.fromEntries(Object.entries(executablePaths).map(([name, relative]) => [name, { path: relative, sha256: "adhoc-hash" }])),
  };
  fs.writeFileSync(manifestPath, JSON.stringify(manifest));
  const plistScript = [
    "import plistlib,sys",
    "with open(sys.argv[1], 'wb') as stream:",
    "  plistlib.dump({'CFBundleIdentifier':'com.chau7.app','CFBundleName':'Chau7','CFBundleDisplayName':'Chau7','CFBundleExecutable':'Chau7','Chau7BuildChannel':'production','CFBundleShortVersionString':'0.6.0','CFBundleVersion':'123'}, stream)",
  ].join("\n");
  const writePlist = spawnSync("python3", ["-c", plistScript, path.join(app, "Contents", "Info.plist")], { encoding: "utf8" });
  assert.equal(writePlist.status, 0, writePlist.stderr);
  const script = path.join(source, "scripts/release/refresh-rust-manifest.py");
  const original = fs.readFileSync(manifestPath, "utf8");
  for (const [stage, distribution] of [["rc", "github-actions-artifact-only"], ["stable", "github-release"]]) {
    fs.writeFileSync(manifestPath, original);
    const refresh = spawnSync("python3", [script, "--app", app, "--manifest", manifestPath,
      "--identity", "Developer ID Application: Fixture (ABCDEFGHIJ)", "--team-id", "ABCDEFGHIJ", "--stage", stage], { encoding: "utf8" });
    assert.equal(refresh.status, 0, refresh.stderr);
    const updated = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    assert.equal(updated.releaseStage, stage);
    assert.equal(updated.distribution, distribution);
    assert.equal(updated.signing.notaryTicketStapled, true);
    for (const [name, relative] of Object.entries(executablePaths)) {
      const bytes = fs.readFileSync(path.join(app, relative));
      const digest = createHash("sha256").update(bytes).digest("hex");
      assert.equal(updated.artifacts[name].sha256, digest);
    }
  }
});

const completeSigningEnv = {
  IDENTITY: "Developer ID Application: Fixture (ABCDEFGHIJ)", CERTIFICATE: "fixture", CERTIFICATE_PASSWORD: "fixture",
  APPLE_ID: "fixture@example.invalid", APPLE_ID_PASSWORD: "fixture", APPLE_TEAM_ID: "ABCDEFGHIJ",
};
for (const [label, overrides, expected] of [
  ["accepts complete configuration", {}, 0],
  ["refuses a missing identity", { IDENTITY: "" }, 1],
  ["refuses a missing notarization password", { APPLE_ID_PASSWORD: "" }, 1],
  ["refuses a non Developer ID identity", { IDENTITY: "Apple Development: Fixture (ABCDEFGHIJ)" }, 1],
  ["refuses a team mismatch", { APPLE_TEAM_ID: "ZYXWVUTSRQ" }, 1],
]) {
  test(`release signing preflight ${label}`, () => {
    const result = spawnSync("/bin/bash", [path.join(source, "scripts/release/require-signing-secrets.sh")], {
      env: { ...process.env, ...completeSigningEnv, ...overrides }, encoding: "utf8",
    });
    assert.equal(result.status, expected, result.stdout + result.stderr);
    if (expected) assert.match(result.stdout, /::error::/);
  });
}
