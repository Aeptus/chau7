# Token Optimizer (CTO)

The Chau7 Token Optimizer reduces the number of tokens AI CLI tools consume by compacting command output before it reaches the model. It works transparently - your commands run normally, but their output is reformatted into a denser representation that preserves all useful information.

## How It Works

When the optimizer is active, Chau7 inserts lightweight wrapper scripts into your PATH. These wrappers intercept supported commands, route them through the `chau7-optim` binary, and produce compact output. If the optimizer can't handle a particular invocation, it falls through to the real binary - your commands always work.

```
you type: grep "TODO" src/
     ↓
wrapper intercepts
     ↓
chau7-optim grep "TODO" src/
     ↓
compact output → AI reads fewer tokens
```

The optimizer is only active in tabs where an AI CLI is detected (Claude, Codex, Gemini, etc.). Regular terminal usage is never affected.

## Enabling the Optimizer

Go to **Settings → Token Optimization** to enable CTO. You can also toggle it per-tab from the tab context menu.

## Supported Commands

The optimizer handles 30+ commands across multiple ecosystems. Below are examples showing native output vs. optimized output.

### grep - Compact Search Results

Groups matches by file, truncates long lines, and shows a match summary.

```
── native grep ──────────────────────
src/auth/middleware.ts:12:  if (!session.token) {
src/auth/middleware.ts:45:  const token = req.headers.authorization;
src/auth/middleware.ts:89:  validateToken(token);
src/api/handler.ts:7:     const token = getToken();
src/api/handler.ts:23:    refreshToken(token);

── optimized ────────────────────────
🔍 5 in 2F:

📄 src/auth/middleware.ts (3):
  12: if (!session.token) {
  45: const token = req.headers.authorization;
  89: validateToken(token);

📄 src/api/handler.ts (2):
   7: const token = getToken();
  23: refreshToken(token);
```

### cat / read - Filtered File Reading

Strips blank lines, comments, and boilerplate. Shows line numbers for context.

```
── native cat ───────────────────────
// Copyright 2024 Acme Corp
// Licensed under MIT
//
// Main application entry point
//

import express from "express";

// Create app
const app = express();

// Start server
app.listen(3000);

── optimized ────────────────────────
   1│ import express from "express";
   2│ const app = express();
   3│ app.listen(3000);
```

### git status - Compact Status

Merges staged/unstaged into a single view with change-type icons.

```
── native git status ────────────────
On branch main
Your branch is up to date with 'origin/main'.

Changes to be committed:
  (use "git restore --staged..." to unstage)
        modified:   src/index.ts
        new file:   src/utils.ts

Changes not staged for commit:
  (use "git add..." to update)
        modified:   README.md

── optimized ────────────────────────
main ≡ origin/main
M  src/index.ts
A  src/utils.ts
?M README.md
```

### git diff - Condensed Diff

Shows only changed lines with minimal context, strips diff headers.

```
── native git diff ──────────────────
diff --git a/src/app.ts b/src/app.ts
index 1a2b3c4..5d6e7f8 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -10,7 +10,7 @@ export class App {
   private db: Database;
   private cache: Cache;

-  constructor() {
+  constructor(config: AppConfig) {
     this.db = new Database();

── optimized ────────────────────────
src/app.ts:
-  constructor() {
+  constructor(config: AppConfig) {
```

### git log - One-Line History

Compresses log to one line per commit with short hashes.

```
── native git log ───────────────────
commit a1b2c3d (HEAD -> main, origin/main)
Author: Jane Dev <jane@example.com>
Date:   Mon Mar 3 14:30:00 2026 +0100

    Fix auth token refresh loop

commit e4f5g6h
Author: Jane Dev <jane@example.com>
Date:   Mon Mar 3 12:00:00 2026 +0100

    Add rate limiting middleware

── optimized ────────────────────────
a1b2c3d Fix auth token refresh loop
e4f5g6h Add rate limiting middleware
```

### cargo test - Failures Only

Strips all passing tests and compilation progress, shows only failures.

```
── native cargo test ────────────────
   Compiling serde v1.0.228
   Compiling tokio v1.43.0
   Compiling myapp v0.1.0
    Finished test target(s) in 12.34s
     Running unittests src/lib.rs
running 47 tests
test auth::tests::login_success ... ok
test auth::tests::login_failure ... ok
test api::tests::handler_404 ... FAILED
test api::tests::handler_200 ... ok
... (43 more ok lines)

── optimized ────────────────────────
✗ 1/47 failed (12.3s)

FAIL api::tests::handler_404
  assert_eq!(status, 404)
  left: 200, right: 404
```

### curl - Auto-JSON Schema

Detects JSON responses and shows structure without values.

```
── native curl ──────────────────────
{"users":[{"id":1,"name":"Alice",
"email":"alice@example.com","role":"admin",
"created_at":"2026-01-15T10:30:00Z"},
{"id":2,"name":"Bob",...}],"total":142,
"page":1,"per_page":20}

── optimized ────────────────────────
{
  users: [{id, name, email, role, created_at}],
  total, page, per_page
}
```

### docker ps - Compact Containers

Strips padding and aligns output to minimal width.

```
── native docker ps ─────────────────
CONTAINER ID   IMAGE          COMMAND       CREATED        STATUS        PORTS                    NAMES
a1b2c3d4e5f6   postgres:16    "docker..."   2 hours ago    Up 2 hours    0.0.0.0:5432->5432/tcp   db
f6e5d4c3b2a1   redis:7        "docker..."   2 hours ago    Up 2 hours    0.0.0.0:6379->6379/tcp   cache

── optimized ────────────────────────
a1b2c3d4 postgres:16 Up 2h :5432 db
f6e5d4c3 redis:7    Up 2h :6379 cache
```

### tsc - Grouped TypeScript Errors

Groups errors by file instead of listing them flat.

```
── native tsc ───────────────────────
src/api.ts(12,5): error TS2345: Argument of
  type 'string' is not assignable to 'number'.
src/api.ts(45,10): error TS2339: Property
  'foo' does not exist on type 'Bar'.
src/utils.ts(8,3): error TS7006: Parameter
  'x' implicitly has an 'any' type.

── optimized ────────────────────────
3 errors in 2 files

src/api.ts (2):
  12: TS2345 string ≠ number
  45: TS2339 'foo' missing on Bar

src/utils.ts (1):
   8: TS7006 implicit any
```

## Full Command Reference

### Core Utilities
- **grep**: Groups by file, truncates lines, shows match count
- **cat** (read): Strips comments/blanks, shows line numbers
- **ls**: Compact directory listing
- **tree**: Token-efficient tree output
- **find**: Compact file search with tree output
- **wc**: Strips padding and paths
- **diff**: Only changed lines, no headers
- **curl**: Auto-detects JSON, shows schema
- **wget**: Strips progress bars

### Git
- **git status**: Single-line per file, branch info
- **git diff**: Condensed diff, minimal context
- **git log**: One line per commit
- **git show**: Commit summary + compact diff
- **git branch**: Current/local/remote grouped
- **git stash**: Compact stash listing

### JavaScript / TypeScript
- **npm**: Strips boilerplate from npm run
- **npx**: Routes to specialized filters (tsc, eslint, prisma)
- **pnpm**: Ultra-compact list, outdated, install
- **vitest**: Failures only, 90% token reduction
- **tsc**: Errors grouped by file
- **lint** (ESLint): Violations grouped by rule
- **prettier**: Compact format check
- **next**: Compact Next.js build output
- **prisma**: Strips ASCII art, compact migrations
- **playwright**: Compact E2E test results

### Rust
- **cargo build**: Strips Compiling lines, keeps errors
- **cargo test**: Failures only
- **cargo clippy**: Warnings grouped by lint rule
- **cargo check**: Strips Checking lines

### Python
- **pytest**: Compact test results
- **ruff**: Compact linter/formatter output
- **pip**: Compact package listing (auto-detects uv)

### Go
- **go test**: Failures only via JSON streaming
- **go build**: Errors only
- **go vet**: Compact output
- **golangci-lint**: Compact linter output

### DevOps
- **docker**: Compact ps, images, logs
- **docker compose**: Compact services, logs, build
- **kubectl**: Compact pods, services, logs
- **gh**: Compact PRs, issues, runs, repos

## Fallthrough Behavior

When the optimizer encounters a command invocation it can't handle (unsupported flags, piped input, etc.), it transparently falls through to the real binary. Your command always runs - the optimizer never blocks execution.

Flags like `-q` (quiet), `-c` (count), and `-l` (files-only) in grep produce no searchable output, so the optimizer intentionally falls through for those.

## Monitoring

Open the **Debug Console** (⌥⌘L → Token Optimizer tab) to see:
- **Optimization rate**: Percentage of commands successfully optimized
- **Tokens saved**: Total token savings from the optimizer
- **Per-tab breakdown**: Stats for each terminal tab
- **Recent commands**: Color-coded command history (green = optimized, orange = fallthrough)
