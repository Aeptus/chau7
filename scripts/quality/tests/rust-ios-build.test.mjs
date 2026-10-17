import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const buildScript = fileURLToPath(new URL("../../../apps/chau7-ios/Scripts/build-rust-terminal-ios.sh", import.meta.url));

const cases = [
  { name: "device", platform: "iphoneos", targets: ["aarch64-apple-ios"] },
  { name: "default universal simulator", platform: "iphonesimulator", targets: ["aarch64-apple-ios-sim", "x86_64-apple-ios"] },
  { name: "native Apple Silicon simulator", platform: "iphonesimulator", archs: "arm64", targets: ["aarch64-apple-ios-sim"] },
  { name: "Intel simulator", platform: "iphonesimulator", archs: "x86_64", targets: ["x86_64-apple-ios"] },
  { name: "explicit universal simulator", platform: "iphonesimulator", archs: "arm64 x86_64", targets: ["aarch64-apple-ios-sim", "x86_64-apple-ios"] },
  { name: "explicit Cargo home with shadowed PATH", platform: "iphonesimulator", archs: "arm64", cargoHome: true, targets: ["aarch64-apple-ios-sim"] },
  { name: "unsupported simulator architecture", platform: "iphonesimulator", archs: "riscv64", targets: [], error: "Unsupported iOS simulator architecture: riscv64" },
];

for (const fixture of cases) {
  test(`Xcode Rust build resolves workspace toolchain and requested slices: ${fixture.name}`, () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-rust-ios-"));
    const ios = path.join(root, "apps/chau7-ios");
    const rust = path.join(root, "apps/chau7-macos/rust");
    const scripts = path.join(ios, "Scripts");
    const fixtureHome = path.join(root, "fake-home");
    const cargoHome = fixture.cargoHome ? path.join(root, "custom cargo home") : path.join(fixtureHome, ".cargo");
    const bin = path.join(cargoHome, "bin");
    const shadowBin = path.join(root, "shadow-bin");
    const log = path.join(root, "commands.log");
    const targetLog = path.join(root, "targets.log");
    const lipoLog = path.join(root, "lipo.log");
    const stamp = path.join(root, "build.stamp");
    for (const dir of [scripts, rust, bin, shadowBin]) fs.mkdirSync(dir, { recursive: true });
    const script = path.join(scripts, "build-rust-terminal-ios.sh");
    fs.copyFileSync(buildScript, script);
    fs.writeFileSync(path.join(rust, "rust-toolchain.toml"), '[toolchain]\nchannel = "1.96.0"\n');
    const writeTool = (name, source) => fs.writeFileSync(path.join(bin, name), source, { mode: 0o755 });
    // Print a delayed final entry to retain coverage for rustup's pipefail/SIGPIPE
    // regression. Only the requested targets are installed in this fixture.
    writeTool("rustup", `#!/bin/bash\nprintf 'rustup:%s\\n' "$PWD" >> "$TEST_COMMAND_LOG"\nprintf '%s\\n' "$TEST_INSTALLED_TARGETS"\nsleep 0.02\nprintf '%s\\n' fixture-unrelated-target\n`);
    writeTool("cargo", `#!/bin/bash\nprintf 'cargo:%s\\n' "$PWD" >> "$TEST_COMMAND_LOG"\nwhile [[ "$1" != --target ]]; do shift; done\nprintf '%s\\n' "$2" >> "$TEST_TARGET_LOG"\nmkdir -p "$CARGO_TARGET_DIR/$2/debug"\ntouch "$CARGO_TARGET_DIR/$2/debug/libchau7_terminal.a"\n`);
    writeTool("lipo", `#!/bin/bash\nprintf '%s\\n' "$@" > "$TEST_LIPO_LOG"\nwhile [[ "$1" != -output ]]; do shift; done\ntouch "$2"\n`);
    for (const name of ["cargo", "rustup"]) {
      fs.writeFileSync(path.join(shadowBin, name), "#!/bin/bash\necho unexpected PATH wrapper >&2\nexit 97\n", { mode: 0o755 });
    }
    const readLines = (file) => fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n") : [];
    try {
      const env = {
        ...process.env,
        HOME: fixtureHome,
        PATH: `${shadowBin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        PLATFORM_NAME: fixture.platform,
        CONFIGURATION: "Debug",
        IPHONEOS_DEPLOYMENT_TARGET: "20.0",
        SCRIPT_OUTPUT_FILE_0: stamp,
        TEST_COMMAND_LOG: log,
        TEST_TARGET_LOG: targetLog,
        TEST_LIPO_LOG: lipoLog,
        TEST_INSTALLED_TARGETS: fixture.targets.join("\n"),
      };
      // An inherited Xcode ARCHS must not turn the standalone default case into
      // an accidental native-only build.
      delete env.CARGO_HOME;
      if (fixture.cargoHome) env.CARGO_HOME = cargoHome;
      delete env.ARCHS;
      if (fixture.archs !== undefined) env.ARCHS = fixture.archs;
      const result = spawnSync("/bin/bash", [script], { cwd: root, encoding: "utf8", env, timeout: 10_000 });
      const library = path.join(ios, "BuildArtifacts/rust/lib", fixture.platform, "libchau7_terminal.a");
      if (fixture.error) {
        assert.equal(result.status, 1, result.stderr);
        assert.ok(result.stderr.includes(fixture.error), result.stderr);
        assert.deepEqual(readLines(log), [], "unsupported architectures must fail before rustup or cargo");
        assert.equal(fs.existsSync(library), false);
        assert.equal(fs.existsSync(stamp), false);
      } else {
        assert.equal(result.status, 0, result.stderr);
        assert.ok(fs.existsSync(library));
        assert.ok(fs.existsSync(stamp));
        const commands = readLines(log);
        assert.equal(commands.length, fixture.targets.length * 2);
        for (const command of commands) assert.equal(command.split(":").slice(1).join(":"), rust);
      }
      assert.deepEqual(readLines(targetLog), fixture.targets, "build only the requested Rust targets");
      if (fixture.platform === "iphonesimulator" && !fixture.error) {
        assert.deepEqual(readLines(lipoLog), [
          "-create",
          ...fixture.targets.map((target) => path.join(ios, "BuildArtifacts/rust/target/ios-20_0", target, "debug/libchau7_terminal.a")),
          "-output", library,
        ], "lipo must receive exactly the selected slices, including a single native slice");
      } else {
        assert.deepEqual(readLines(lipoLog), [], "device and rejected builds must not run lipo");
      }
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
}
