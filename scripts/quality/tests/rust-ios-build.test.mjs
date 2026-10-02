import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const buildScript = fileURLToPath(new URL("../../../apps/chau7-ios/Scripts/build-rust-terminal-ios.sh", import.meta.url));

test("Xcode Rust target checks and builds resolve the workspace toolchain from any launch directory", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-rust-ios-"));
  const ios = path.join(root, "apps/chau7-ios");
  const rust = path.join(root, "apps/chau7-macos/rust");
  const scripts = path.join(ios, "Scripts");
  const home = path.join(root, "fake-home");
  const bin = path.join(home, ".cargo/bin");
  const log = path.join(root, "commands.log");
  for (const dir of [scripts, rust, bin]) fs.mkdirSync(dir, { recursive: true });
  const script = path.join(scripts, "build-rust-terminal-ios.sh");
  fs.copyFileSync(buildScript, script);
  fs.writeFileSync(path.join(rust, "rust-toolchain.toml"), '[toolchain]\nchannel = "1.96.0"\n');
  const writeTool = (name, source) => fs.writeFileSync(path.join(bin, name), source, { mode: 0o755 });
  writeTool("rustup", `#!/bin/bash\nprintf 'rustup:%s\\n' "$PWD" >> "$TEST_COMMAND_LOG"\nprintf '%s\\n' aarch64-apple-ios\nsleep 0.02\nprintf '%s\\n' aarch64-apple-ios-sim x86_64-apple-ios\n`);
  writeTool("cargo", `#!/bin/bash\nprintf 'cargo:%s\\n' "$PWD" >> "$TEST_COMMAND_LOG"\nwhile [[ "$1" != --target ]]; do shift; done\nmkdir -p "$CARGO_TARGET_DIR/$2/debug"\ntouch "$CARGO_TARGET_DIR/$2/debug/libchau7_terminal.a"\n`);
  writeTool("lipo", `#!/bin/bash\nwhile [[ "$1" != -output ]]; do shift; done\ntouch "$2"\n`);
  try {
    for (const platform of ["iphoneos", "iphonesimulator"]) {
      const result = spawnSync("/bin/bash", [script], {
        cwd: root,
        encoding: "utf8",
        env: { ...process.env, HOME: home, PLATFORM_NAME: platform, CONFIGURATION: "Debug", TEST_COMMAND_LOG: log },
      });
      assert.equal(result.status, 0, result.stderr);
      assert.ok(fs.existsSync(path.join(ios, "BuildArtifacts/rust/lib", platform, "libchau7_terminal.a")));
    }
    const commands = fs.readFileSync(log, "utf8").trim().split("\n");
    assert.equal(commands.length, 6);
    for (const command of commands) assert.equal(command.split(":").slice(1).join(":"), rust);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
