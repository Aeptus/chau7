#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const localPython = path.join(root, ".venv/bin/python3");
const python = process.env.CHAU7_TEST_PYTHON ?? (fs.existsSync(localPython) ? localPython : "python3");
for (const [directory, extraPath] of [["scripts/tests", ""], ["tools/pentagi-mcp/tests", "tools/pentagi-mcp"]]) {
  const result = spawnSync(python, ["-m", "unittest", "discover", "-s", directory, "-v"], {
    cwd: root, stdio: "inherit", env: { ...process.env, PYTHONPATH: [path.join(root, extraPath), process.env.PYTHONPATH].filter(Boolean).join(path.delimiter) },
  });
  if (result.status !== 0) { process.stderr.write(`Install prerequisites: python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements-tests.txt. Python tests failed: ${result.error?.message ?? directory}\n`); process.exit(result.status ?? 1); }
}
