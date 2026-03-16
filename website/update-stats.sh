#!/usr/bin/env bash
# update-stats.sh — Counts repo stats and patches the website footer.
# Run from the website/ directory before deploying.
# Usage: ./update-stats.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEBSITE_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPONENTS="$WEBSITE_DIR/components.js"

# ── Count Swift source files (exclude .build, tests, Package.swift) ──
swift_files=$(find "$REPO_ROOT" -name "*.swift" \
    -not -path "*/.build/*" \
    -not -path "*/Tests/*" \
    -not -name "Package.swift" | wc -l | tr -d ' ')

# ── Count test functions ──
test_count=$(grep -r "func test" "$REPO_ROOT/apps/chau7-macos/Tests" \
    --include="*.swift" 2>/dev/null | wc -l | tr -d ' ')

# ── Count Rust source files ──
rust_files=$(find "$REPO_ROOT" -name "*.rs" \
    -not -path "*/target/*" | wc -l | tr -d ' ')

# ── Count features (from feature-data.json) ──
if command -v python3 &>/dev/null && [ -f "$WEBSITE_DIR/feature-data.json" ]; then
    feature_count=$(python3 -c "
import json
with open('$WEBSITE_DIR/feature-data.json') as f:
    data = json.load(f)
    # Count unique features across all categories
    slugs = set()
    for cat in data.get('categories', data) if isinstance(data, dict) else data:
        if isinstance(cat, dict):
            for feat in cat.get('features', []):
                slugs.add(feat.get('slug', ''))
    print(len(slugs) if slugs else '178')
" 2>/dev/null || echo "178")
else
    feature_count="178"
fi

echo "Stats:"
echo "  Swift files:  $swift_files"
echo "  Rust files:   $rust_files"
echo "  Test funcs:   $test_count"
echo "  Features:     $feature_count"

# ── Patch components.js footer line ──
# Match the footer-bottom span and replace its content
OLD_PATTERN='<span>[0-9]* Swift files &middot; Rust backend &middot; Metal GPU &middot; [0-9]* tests</span>'
NEW_CONTENT="<span>${swift_files} Swift files \&middot; Rust backend \&middot; Metal GPU \&middot; ${test_count} tests</span>"

if grep -qE "$OLD_PATTERN" "$COMPONENTS"; then
    sed -i '' -E "s|$OLD_PATTERN|$NEW_CONTENT|" "$COMPONENTS"
    echo ""
    echo "Updated components.js footer:"
    grep "Swift files" "$COMPONENTS"
else
    echo ""
    echo "WARNING: Could not find footer stats pattern in components.js"
    echo "Expected pattern: $OLD_PATTERN"
    echo "Manual update needed."
fi
