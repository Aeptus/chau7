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

test("full-suite dependency audit gates are registered as live security gates", () => {
  assert.equal(gate("full-js-dependency-audit").cacheable, false);
  assert.equal(gate("full-js-dependency-audit").wave, "audit");
  assert.equal(gate("full-python-dependency-audit").cacheable, false);
  assert.equal(gate("full-python-dependency-audit").wave, "audit");
});

test("security gates are blocking registered gates, not hook-only shell snippets", () => {
  assert.equal(gate("staged-secret-scan").wave, "preflight");
  assert.ok(gate("staged-dependency-policy").tags.includes("security"));
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

test("dependency policy accepts a manifest when its lockfile is in scope", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-quality-policy-"));
  fs.mkdirSync(path.join(root, "pkg"));
  fs.writeFileSync(
    path.join(root, "pkg/package.json"),
    JSON.stringify({ devDependencies: { prettier: "3.8.2" } }),
  );
  fs.writeFileSync(path.join(root, "pkg/package-lock.json"), "{}\n");

  const result = await gate("always-dependency-policy").run({
    root,
    mode: "prepush",
    changedFiles: ["pkg/package.json", "pkg/package-lock.json"],
  });

  assert.equal(result.status, "passed");
});
