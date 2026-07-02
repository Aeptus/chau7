#!/usr/bin/env node
// Single source of truth for the feature inventory.
//
// apps/chau7-macos/docs/features.json is authoritative and human-editable;
// apps/chau7-macos/docs/features.csv is a GENERATED artifact. This removes
// the whole drift/rot class: you can't hand-append a malformed CSV row
// because the CSV is regenerated from the manifest, and the `--check` mode
// deterministically fails if the committed CSV doesn't match.
//
// Modes:
//   (default)      read features.json -> write features.csv
//   --check        fail (exit 1) if committed features.csv != generated output
//   --bootstrap    one-time: read the existing features.csv -> write features.json

import fs from "node:fs";
import path from "node:path";

const CSV_PATH = "apps/chau7-macos/docs/features.csv";
const JSON_PATH = "apps/chau7-macos/docs/features.json";
const HEADER = ["Category", "Feature", "Description", "Status", "Differentiator"];
const FIELDS = ["category", "feature", "description", "status", "differentiator"];

function parseRecord(line) {
  const fields = [];
  let field = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (inQuotes) {
      if (char === '"') {
        if (line[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ",") {
      fields.push(field);
      field = "";
    } else {
      field += char;
    }
  }
  fields.push(field);
  return fields;
}

function parseCsv(raw) {
  const body = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  const lines = body.split("\n");
  if (lines[0] !== HEADER.join(",")) {
    throw new Error(`Unexpected header: ${lines[0]}`);
  }
  return lines.slice(1).map((line) => {
    const values = parseRecord(line);
    return Object.fromEntries(FIELDS.map((key, index) => [key, values[index] ?? ""]));
  });
}

// RFC 4180 minimal quoting — quote only when the field contains a comma,
// quote, or newline; escape embedded quotes by doubling.
function quoteField(value) {
  return /[",\r\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

function serializeCsv(records) {
  const lines = [HEADER.join(",")];
  for (const record of records) {
    lines.push(FIELDS.map((key) => quoteField(String(record[key] ?? ""))).join(","));
  }
  return `${lines.join("\n")}\n`;
}

function readManifest() {
  const records = JSON.parse(fs.readFileSync(JSON_PATH, "utf8"));
  if (!Array.isArray(records)) throw new Error(`${JSON_PATH} must be a JSON array`);
  return records;
}

const mode = process.argv[2];

if (mode === "--bootstrap") {
  const records = parseCsv(fs.readFileSync(CSV_PATH, "utf8"));
  fs.writeFileSync(JSON_PATH, `${JSON.stringify(records, null, 2)}\n`);
  console.log(`Bootstrapped ${records.length} features -> ${JSON_PATH}`);
} else if (mode === "--check") {
  const generated = serializeCsv(readManifest());
  const current = fs.existsSync(CSV_PATH) ? fs.readFileSync(CSV_PATH, "utf8") : "";
  if (current !== generated) {
    console.error(
      `${CSV_PATH} is out of sync with ${JSON_PATH}.\n` +
        `Edit the manifest, not the CSV, then run: pnpm features:generate`,
    );
    process.exit(1);
  }
  console.log(`${CSV_PATH} is in sync with ${JSON_PATH}`);
} else {
  const records = readManifest();
  fs.writeFileSync(CSV_PATH, serializeCsv(records));
  console.log(`Generated ${CSV_PATH} from ${JSON_PATH} (${records.length} features)`);
}
