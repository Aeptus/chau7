#!/usr/bin/env node
// Narrow, deterministic code -> doc coverage gate.
//
// Invariant: every MCP tool registered in MCPSession.swift's
// toolDefinitions() must have a canonical inventory row in features.json
// (category starting "MCP Tools", feature == the tool name). This is the
// one code->doc mapping strong enough to hard-fail on: a genuinely new
// tool with no inventory row fails the commit, while refactors, renames,
// and non-tool changes never trip it — so it is effectively free of false
// positives.
//
// Escape hatch (deliberate and narrow, unlike a blanket --no-verify):
//   CHAU7_SKIP_FEATURE_COVERAGE=1
//
// Usage: node scripts/check-feature-coverage.mjs

import fs from "node:fs";

const MCP_PATH = "apps/chau7-macos/Sources/Chau7/MCP/MCPSession.swift";
const MANIFEST_PATH = "apps/chau7-macos/docs/features.json";

if (process.env.CHAU7_SKIP_FEATURE_COVERAGE) {
  console.log("feature-coverage: skipped via CHAU7_SKIP_FEATURE_COVERAGE");
  process.exit(0);
}

function registeredTools() {
  const src = fs.readFileSync(MCP_PATH, "utf8");
  const start = src.indexOf("func toolDefinitions()");
  if (start === -1) throw new Error(`toolDefinitions() not found in ${MCP_PATH}`);
  // Scope to the toolDefinitions() body so the server name ("chau7") and
  // any other `"name":` literals elsewhere in the file are excluded.
  const rest = src.slice(start);
  const endRel = rest.indexOf("\n    private func ", 1);
  const scope = endRel === -1 ? rest : rest.slice(0, endRel);
  return new Set([...scope.matchAll(/"name":\s*"([a-z][a-z0-9_]*)"/g)].map((m) => m[1]));
}

function documentedTools() {
  const rows = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
  return new Set(
    rows
      .filter((row) => row.category.startsWith("MCP Tools") && /^[a-z][a-z0-9_]*$/.test(row.feature))
      .map((row) => row.feature),
  );
}

const code = registeredTools();
const docs = documentedTools();
const missing = [...code].filter((tool) => !docs.has(tool)).sort();
const stale = [...docs].filter((tool) => !code.has(tool)).sort();

// Stale rows (documented but no longer registered) are a warning, not a
// failure — removing a tool is legitimate and shouldn't block a commit.
for (const tool of stale) {
  console.warn(
    `feature-coverage WARNING: "${tool}" is documented but not registered in MCPSession.swift (removed tool?)`,
  );
}

if (missing.length > 0) {
  console.error(
    `feature-coverage FAILED: ${missing.length} MCP tool(s) registered in code but missing a ` +
      `canonical inventory row (category "MCP Tools — …", feature == tool name) in ${MANIFEST_PATH}:`,
  );
  for (const tool of missing) console.error(`  ${tool}`);
  console.error(
    "Add each to docs/features.json then run `pnpm features:generate`, " +
      "or set CHAU7_SKIP_FEATURE_COVERAGE=1 to bypass deliberately.",
  );
  process.exit(1);
}

console.log(`feature-coverage OK — all ${code.size} registered MCP tools are documented`);
