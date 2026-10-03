import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { gates } from "../registry.mjs";

const root = fileURLToPath(new URL("../../../", import.meta.url));

function packageGraph(coreOnly) {
  const env = { ...process.env };
  delete env.CHAU7_CORE_TESTS_ONLY;
  if (coreOnly) env.CHAU7_CORE_TESTS_ONLY = "1";
  const result = spawnSync("swift", ["package", "--package-path", path.join(root, "apps/chau7-macos"), "dump-package"], {
    env, encoding: "utf8", timeout: 30000,
  });
  assert.equal(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}

test("Core-only graph excludes the app and keeps only pure Core target dependencies", () => {
  const graph = packageGraph(true);
  assert.deepEqual(graph.targets.map((target) => target.name), ["Chau7Core", "Chau7CoreTests"]);
  const tests = graph.targets.find((target) => target.name === "Chau7CoreTests");
  assert.ok(tests.sources.includes("Terminal/CommandBlockTests.swift"));
  assert.ok(tests.sources.includes("Core/MainThreadHangMonitorTests.swift"));
  assert.ok(tests.sources.length > 200);
  assert.ok(!tests.sources.some((source) => source.endsWith("MainActorBridgeTests.swift")));
  assert.deepEqual(tests.dependencies.map((dependency) => dependency.byName?.[0]), ["Chau7Core"]);
});

test("normal package still includes the full app integration test graph", () => {
  const graph = packageGraph(false);
  assert.ok(graph.targets.some((target) => target.name === "Chau7"));
  const tests = graph.targets.find((target) => target.name === "Chau7Tests");
  assert.ok(tests.dependencies.some((dependency) => dependency.byName?.[0] === "Chau7"));
});

test("package and Core test command changes still select full Swift CI tests", () => {
  const gate = gates.find((candidate) => candidate.id === "swift-macos-tests");
  for (const file of ["apps/chau7-macos/Package.swift", "apps/chau7-macos/Scripts/test-core.sh"]) {
    assert.equal(gate.applies({ changedFiles: [file] }), true);
  }
});
