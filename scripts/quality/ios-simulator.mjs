import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export function selectIOSRuntime(runtimes, sdkVersion) {
  if (!/^\d+\.\d+(?:\.\d+)?$/.test(sdkVersion)) throw new Error(`Invalid iOS SDK version: ${sdkVersion}`);
  const [major, minor] = sdkVersion.split(".").map(Number);
  return runtimes.filter((runtime) => {
    const [runtimeMajor, runtimeMinor] = String(runtime.version).split(".").map(Number);
    return runtime.isAvailable === true && runtime.identifier?.startsWith("com.apple.CoreSimulator.SimRuntime.iOS-")
      && runtimeMajor === major && runtimeMinor === minor;
  }).sort((a, b) => b.version.localeCompare(a.version, "en", { numeric: true }))[0] ?? null;
}

export function prepareIOSSimulator(run = (command, args, options = {}) =>
  execFileSync(command, args, { encoding: "utf8", maxBuffer: 2 * 1024 * 1024, ...options })) {
  const sdk = run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-version"]).trim();
  const readRuntimes = () => JSON.parse(run("xcrun", ["simctl", "list", "runtimes", "--json"])).runtimes;
  let runtime = selectIOSRuntime(readRuntimes(), sdk);
  if (!runtime) {
    // Apple documents -downloadPlatform for downloading/installing runtime
    // components of the selected Xcode. Match its SDK explicitly.
    run("xcodebuild", ["-downloadPlatform", "iOS", "-buildVersion", sdk], { stdio: "inherit" });
    runtime = selectIOSRuntime(readRuntimes(), sdk);
  }
  if (!runtime) throw new Error(`No available iOS ${sdk} simulator runtime for the selected Xcode after preparation.`);
  const id = run("xcrun", ["simctl", "create", "Chau7 CI iPhone 17 Pro",
    "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime.identifier]).trim();
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)) throw new Error("simctl returned an invalid simulator ID.");
  return `platform=iOS Simulator,id=${id}`;
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  if (!process.env.GITHUB_ENV) throw new Error("Simulator preparation requires GITHUB_ENV and runs only on the CI host.");
  const destination = prepareIOSSimulator();
  fs.appendFileSync(process.env.GITHUB_ENV, `CHAU7_IOS_TEST_DESTINATION=${destination}\n`);
  process.stdout.write(`Prepared iOS test destination: ${destination}\n`);
}
