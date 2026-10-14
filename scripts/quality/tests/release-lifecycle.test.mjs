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
test("nonpublishing workflow has one read-only build and restores its artifact for gated publication", () => {
  const workflow = fs.readFileSync(path.join(source, ".github/workflows/release.yml"), "utf8");
  const [build, publish] = workflow.split("  publish:");
  assert.match(build, /workflow_dispatch:/); assert.doesNotMatch(build, /secrets\./); assert.match(build, /permissions:\n  contents: read/);
  assert.equal((workflow.match(/run: \.\/Scripts\/build-dist\.sh/g) ?? []).length, 1);
  assert.match(publish, /if: github.event_name == 'push' && startsWith\(github.ref, 'refs\/tags\/v'\)/);
  assert.doesNotMatch(publish, /swift build|build-app\.sh|build-dist\.sh/); assert.match(publish, /tar -xf.*release-artifacts.tar/); assert.match(publish, /if: always\(\)/);
  const rustRcStart = workflow.indexOf("  rust-production-rc-preflight:");
  assert.ok(rustRcStart > 0, "Rust RC jobs should be isolated after the existing Swift release jobs");
  assert.equal((workflow.slice(0, rustRcStart).match(/timeout-minutes:/g) ?? []).length, 3);
  assert.equal((workflow.slice(rustRcStart).match(/timeout-minutes:/g) ?? []).length, 3);
  assert.match(workflow, /cancel-in-progress: false/);
  for (const match of workflow.matchAll(/uses: (.+)/g)) assert.match(match[1], /@[a-f0-9]{40}(?: |$)/);
});

test("Rust production RC stays manual, versioned, signed, and artifact-only", () => {
  const workflow = fs.readFileSync(path.join(source, ".github/workflows/release.yml"), "utf8");
  const preflightStart = workflow.indexOf("  rust-production-rc-preflight:");
  assert.ok(preflightStart >= 0);
  const [swiftJobs, rcJobs] = [workflow.slice(0, preflightStart), workflow.slice(preflightStart)];
  const buildJob = rcJobs.match(/  rust-production-rc-build:\n([\s\S]*?)(?=\n  [a-z][a-z0-9-]+:\n|$)/)?.[1];
  const signJob = rcJobs.match(/  rust-production-rc-sign:\n([\s\S]*?)(?=\n  [a-z][a-z0-9-]+:\n|$)/)?.[1];
  assert.match(workflow, /release_channel:[\s\S]*?default: swift-dry-run[\s\S]*?rust-production-rc/);
  assert.match(workflow, /default: 0\.6\.0-rc\.1/);
  assert.match(workflow, /RUST_PRODUCTION_MIGRATION_VALIDATED/);
  assert.match(rcJobs, /refs\/heads\/main/);
  assert.match(rcJobs, /RELEASE_VERSION: \$\{\{ inputs\.release_version \}\}/);
  assert.match(buildJob ?? "", /CHANNEL: production/);
  assert.match(buildJob ?? "", /run: \.\/scripts\/bundle-macos\.sh/);
  assert.match(buildJob ?? "", /rust-production-candidate-unsigned/);
  assert.match(signJob ?? "", /sign-rust-production-rc\.sh/);
  assert.match(signJob ?? "", /actions\/attest-build-provenance/);
  assert.match(signJob ?? "", /rust-production-rc-\$\{\{ github\.run_number \}\}/);
  assert.doesNotMatch(signJob ?? "", /cargo build|bundle-macos\.sh|softprops\/action-gh-release|contents:\s*write|HOMEBREW_TAP_TOKEN/);
  assert.doesNotMatch(rcJobs, /softprops\/action-gh-release/);
  assert.match(swiftJobs, /softprops\/action-gh-release/);
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
  const refresh = spawnSync("python3", [script, "--app", app, "--manifest", manifestPath,
    "--identity", "Developer ID Application: Fixture (ABCDEFGHIJ)", "--team-id", "ABCDEFGHIJ"], { encoding: "utf8" });
  assert.equal(refresh.status, 0, refresh.stderr);
  const updated = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  assert.equal(updated.releaseStage, "rc");
  assert.equal(updated.distribution, "github-actions-artifact-only");
  assert.equal(updated.signing.notaryTicketStapled, true);
  for (const [name, relative] of Object.entries(executablePaths)) {
    const bytes = fs.readFileSync(path.join(app, relative));
    const digest = createHash("sha256").update(bytes).digest("hex");
    assert.equal(updated.artifacts[name].sha256, digest);
  }
});

for (const identity of ["", "Developer ID Application: Fixture (TESTTEAM)"]) {
  test(`release signing preflight ${identity ? "accepts a configured identity" : "refuses unsigned publication"}`, (t) => {
    const workflow = fs.readFileSync(path.join(source, ".github/workflows/release.yml"), "utf8");
    const preflight = workflow.match(/- name: Require release signing configuration[\s\S]*?run: \|\n([\s\S]*?)(?=      - name:)/)?.[1];
    assert.ok(preflight, "release publication must check signing before using artifacts");
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-signing-preflight-"));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const output = path.join(root, "output");
    const result = spawnSync("/bin/bash", ["-e", "-c", preflight], {
      env: { ...process.env, IDENTITY: identity, GITHUB_OUTPUT: output }, encoding: "utf8",
    });
    assert.equal(result.status, identity ? 0 : 1, result.stderr);
    if (identity) assert.match(fs.readFileSync(output, "utf8"), /available=true/);
    else {
      assert.match(result.stdout, /::error::Developer ID signing is required/);
      assert.equal(fs.existsSync(output), false, "unsigned builds cannot reach gated publication");
    }
  });
}
