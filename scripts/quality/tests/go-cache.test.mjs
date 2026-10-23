import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const dependencies = [
  "services/chau7-remote/go.sum",
  "services/chau7-proxy/go.sum",
];

for (const name of ["ci.yml", "release.yml", "chau7-next.yml"]) {
  test(`${name} keys the Go cache from both nested module lockfiles`, () => {
    const workflow = fs.readFileSync(path.join(root, ".github/workflows", name), "utf8");
    const lines = workflow.split("\n");
    const start = lines.findIndex((line) => /uses: actions\/setup-go@/.test(line));
    assert.notEqual(start, -1, "workflow must set up Go");
    let end = start + 1;
    while (end < lines.length && !/^ {6}- /.test(lines[end])) end += 1;
    const block = lines.slice(start, end).join("\n");
    assert.match(block, /go-version-file: services\/chau7-remote\/go\.mod/);
    assert.match(block, /cache-dependency-path: \|/);
    for (const dependency of dependencies) {
      assert.ok(block.split("\n").some((line) => line.trim() === dependency), dependency);
      assert.ok(fs.existsSync(path.join(root, dependency)), `${dependency} must exist`);
    }
    assert.ok(!block.split("\n").some((line) => line.trim() === "go.mod"));
  });
}
