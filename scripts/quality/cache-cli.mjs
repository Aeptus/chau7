#!/usr/bin/env node
import process from "node:process";
import { cacheStatus, clearCache, pruneOldLogs } from "./cache.mjs";
import { repoRoot } from "./helpers.mjs";

const command = process.argv[2] ?? "status";
const root = repoRoot();

if (command === "status") {
  const status = cacheStatus(root);
  process.stdout.write(`${JSON.stringify(status, null, 2)}\n`);
} else if (command === "clear") {
  clearCache(root);
  process.stdout.write("quality cache cleared\n");
} else if (command === "prune") {
  pruneOldLogs(root);
} else {
  console.error(`unknown cache command: ${command}`);
  process.exitCode = 1;
}
