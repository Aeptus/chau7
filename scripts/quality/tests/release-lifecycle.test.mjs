import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
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
  assert.equal((workflow.match(/timeout-minutes:/g) ?? []).length, 3); assert.match(workflow, /cancel-in-progress: false/);
  for (const match of workflow.matchAll(/uses: (.+)/g)) assert.match(match[1], /@[a-f0-9]{40}(?: |$)/);
});
