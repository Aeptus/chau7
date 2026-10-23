import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { gates } from "../registry.mjs";

const root = fileURLToPath(new URL("../../../", import.meta.url));
const packageRoot = path.join(root, "apps/chau7-ios/Chau7Core");

function packageGraph() {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-core-graph-"));
  try {
    // A fresh Xcode toolchain can compile its first manifest alongside native/iOS CI.
    // Keep a finite deadline, but allow cold startup without changing any graph assertion.
    const result = spawnSync("swift", ["package", "--package-path", packageRoot, "--scratch-path", scratch, "--manifest-cache", "none", "dump-package"], {
      encoding: "utf8", timeout: 120000,
    });
    const diagnostics = [result.error?.message, result.signal && `signal: ${result.signal}`, result.stderr].filter(Boolean).join("\n");
    assert.equal(result.error, undefined, diagnostics);
    assert.equal(result.status, 0, diagnostics);
    return JSON.parse(result.stdout);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

test("Chau7Core is a standalone package with only its own test target", () => {
  const graph = packageGraph();
  assert.deepEqual(graph.targets.map((target) => target.name), ["Chau7Core", "Chau7CoreTests"]);
  assert.deepEqual(graph.dependencies, []);
  const tests = graph.targets.find((target) => target.name === "Chau7CoreTests");
  assert.deepEqual(tests.dependencies.map((dependency) => dependency.byName?.[0]), ["Chau7Core"]);
  assert.deepEqual(graph.products.map((product) => product.name), ["Chau7Core"]);
});

test("Chau7Core changes select the package gate", () => {
  const gate = gates.find((candidate) => candidate.id === "swift-core-package");
  assert.equal(gate.applies({ changedFiles: ["apps/chau7-ios/Chau7Core/Package.swift"] }), true);
  assert.equal(gate.applies({ changedFiles: ["apps/chau7-ios/Chau7Core/Sources/Chau7Core/AIEvent.swift"] }), true);
  assert.equal(gate.applies({ changedFiles: ["services/chau7-remote/go.mod"] }), false);
});
