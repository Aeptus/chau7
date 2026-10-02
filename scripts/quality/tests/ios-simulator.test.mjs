import test from "node:test";
import assert from "node:assert/strict";
import { selectIOSRuntime, prepareIOSSimulator } from "../ios-simulator.mjs";

const runtime = (version, available = true) => ({ version, isAvailable: available,
  identifier: `com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll(".", "-")}` });
const id = "12345678-1234-1234-1234-123456789abc";

test("runtime selection matches the selected SDK and rejects unavailable or newer incompatible runtimes", () => {
  const match = runtime("26.6");
  assert.equal(selectIOSRuntime([runtime("27.2"), runtime("26.6", false), match], "26.6"), match);
  assert.equal(selectIOSRuntime([runtime("27.2"), runtime("26.6", false)], "26.6"), null);
  assert.throws(() => selectIOSRuntime([], "invalid"), /Invalid iOS SDK/);
});

test("runtime selection accepts patch versions and prefers the latest compatible patch", () => {
  const match = runtime("26.6.1");
  assert.equal(selectIOSRuntime([runtime("26.6"), match], "26.6.0"), match);
});

test("simulator preparation uses an available runtime without downloading and returns a concrete destination", () => {
  const calls = [];
  const destination = prepareIOSSimulator((command, args) => {
    calls.push([command, args]);
    if (args.includes("--show-sdk-version")) return "26.6\n";
    if (args.includes("runtimes")) return JSON.stringify({ runtimes: [runtime("26.6")] });
    if (args.includes("create")) return id + "\n";
    assert.fail(`Unexpected command: ${command}`);
  });
  assert.equal(destination, `platform=iOS Simulator,id=${id}`);
  assert.equal(calls.length, 3);
  assert.equal(calls[2][1].at(-1), runtime("26.6").identifier);
});

test("missing runtimes are prepared for the selected SDK and rechecked before creating a device", () => {
  const calls = []; let reads = 0;
  const destination = prepareIOSSimulator((command, args) => {
    calls.push([command, args]);
    if (args.includes("--show-sdk-version")) return "26.6\n";
    if (args.includes("runtimes")) return JSON.stringify({ runtimes: ++reads === 1 ? [runtime("27.2")] : [runtime("26.6")] });
    if (command === "xcodebuild") return "";
    if (args.includes("create")) return id;
    assert.fail(`Unexpected command: ${command}`);
  });
  assert.equal(destination, `platform=iOS Simulator,id=${id}`);
  assert.deepEqual(calls[2], ["xcodebuild", ["-downloadPlatform", "iOS", "-buildVersion", "26.6"]]);
  assert.equal(reads, 2);
});

test("preparation fails before creating a device when the compatible runtime is still unavailable", () => {
  const calls = [];
  assert.throws(() => prepareIOSSimulator((command, args) => {
    calls.push([command, args]);
    if (args.includes("--show-sdk-version")) return "26.6";
    if (args.includes("runtimes")) return '{"runtimes":[]}';
    if (command === "xcodebuild") return "";
    assert.fail("must not create a device");
  }), /No available iOS 26.6/);
  assert.equal(calls.length, 4);
});

test("preparation rejects malformed simulator IDs", () => {
  assert.throws(() => prepareIOSSimulator((command, args) => {
    if (args.includes("--show-sdk-version")) return "26.6";
    if (args.includes("runtimes")) return JSON.stringify({ runtimes: [runtime("26.6")] });
    return "invalid";
  }), /invalid simulator ID/);
});
