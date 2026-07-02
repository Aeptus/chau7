#!/usr/bin/env node
// Structural validator for the machine-readable feature inventory
// (apps/chau7-macos/docs/features.csv).
//
// This is a DETERMINISTIC, zero-false-positive gate: it only asserts
// machine-verifiable invariants on data that already exists. It does not
// judge whether a feature *should* be documented (that is the coverage
// gate's job) — it guarantees the CSV that exists is well-formed, which is
// exactly the rot class that let 72 malformed rows land unnoticed.
//
// Usage: node scripts/check-features-csv.mjs [path-to-features.csv]
// Exit 0 when valid, 1 when any row violates the schema.

import fs from "node:fs";
import path from "node:path";

const HEADER = "Category,Feature,Description,Status,Differentiator";
const ALLOWED_STATUS = new Set(["Shipped", "Experimental", "Planned", "Deprecated"]);
const ALLOWED_DIFFERENTIATOR = new Set(["Yes", "No"]);

const target = process.argv[2] ?? "apps/chau7-macos/docs/features.csv";
const absolute = path.resolve(process.cwd(), target);

/**
 * Parse one CSV record into fields, honoring RFC 4180 double-quote quoting
 * (a quote inside a quoted field is escaped by doubling it). Records in this
 * file never span multiple physical lines, so line-based parsing is safe.
 */
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
  return { fields, unterminatedQuote: inQuotes };
}

function main() {
  if (!fs.existsSync(absolute)) {
    console.error(`ERROR: features CSV not found at ${target}`);
    process.exit(1);
  }

  const raw = fs.readFileSync(absolute, "utf8");
  // Drop exactly one trailing newline (the EOF terminator); any remaining
  // empty element is a genuine blank line in the body.
  const body = raw.endsWith("\n") ? raw.slice(0, -1) : raw;
  const lines = body.split("\n");
  const errors = [];

  if (lines[0] !== HEADER) {
    errors.push(`line 1: header must be exactly "${HEADER}" (found "${lines[0]}")`);
  }

  for (let i = 1; i < lines.length; i += 1) {
    const lineNo = i + 1;
    const line = lines[i];

    if (line.trim() === "") {
      errors.push(`line ${lineNo}: blank line (no empty rows allowed)`);
      continue;
    }

    const { fields, unterminatedQuote } = parseRecord(line);
    if (unterminatedQuote) {
      errors.push(`line ${lineNo}: unterminated quoted field`);
      continue;
    }
    if (fields.length !== 5) {
      errors.push(
        `line ${lineNo}: expected 5 columns, found ${fields.length} ` +
          `(unquoted comma? — quote fields containing commas). Category="${fields[0]}"`,
      );
      continue;
    }

    const [, feature, , status, differentiator] = fields;
    if (!feature.trim()) {
      errors.push(`line ${lineNo}: Feature (column 2) must not be empty`);
    }
    if (!ALLOWED_STATUS.has(status)) {
      errors.push(
        `line ${lineNo}: Status="${status}" not in {${[...ALLOWED_STATUS].join(", ")}}`,
      );
    }
    if (!ALLOWED_DIFFERENTIATOR.has(differentiator)) {
      errors.push(`line ${lineNo}: Differentiator="${differentiator}" not in {Yes, No}`);
    }
  }

  if (errors.length > 0) {
    console.error(`features.csv structural check FAILED (${errors.length} issue(s)):`);
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
  }

  console.log(`features.csv OK — ${lines.length - 1} well-formed rows`);
}

main();
