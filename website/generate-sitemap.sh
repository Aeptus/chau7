#!/usr/bin/env bash
# generate-sitemap.sh — Builds sitemap.xml from all HTML files.
# Run from the website/ directory. Called automatically by push2prod.

set -euo pipefail

SITE="https://chau7.sh"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/sitemap.xml"

# Start XML
cat > "$OUT" <<'HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
HEADER

# Find all HTML files, convert to clean URLs
find "$DIR" -name "*.html" -not -name "index-geo.html" -not -name "404.html" -not -path "*/.git/*" | sort | while read -r file; do
    # Get path relative to website dir
    rel="${file#$DIR/}"

    # Skip duplicate index.html inside subdirectories (the .html version is canonical)
    # Exception: features/*/index.html (individual feature pages only exist as dirs)
    if [[ "$rel" == */index.html ]] && [[ "$rel" != features/*/index.html ]]; then
        # Check if a sibling .html exists at the parent level
        parent_dir="$(dirname "$rel")"
        if [[ -f "$DIR/${parent_dir}.html" ]]; then
            continue  # skip, the .html version is canonical
        fi
    fi

    # Convert to URL path
    url="$rel"
    # index.html → /
    if [[ "$url" == "index.html" ]]; then
        url=""
    fi
    # foo.html → foo
    url="${url%.html}"
    # foo/index → foo
    url="${url%/index}"

    # Get last modified date
    mod=$(date -r "$file" "+%Y-%m-%d" 2>/dev/null || echo "2026-03-17")

    # Determine priority
    priority="0.5"
    case "$url" in
        "") priority="1.0" ;;           # homepage
        features|mcp|remote|compare|the-tech) priority="0.8" ;;
        features/*) priority="0.6" ;;    # individual feature pages
        compare/*) priority="0.6" ;;     # comparison pages
        pronunciation|legal|privacy) priority="0.3" ;;
    esac

    # Determine changefreq
    changefreq="monthly"
    case "$url" in
        "") changefreq="weekly" ;;
        features|mcp|remote) changefreq="weekly" ;;
    esac

    cat >> "$OUT" <<EOF
  <url>
    <loc>${SITE}/${url}</loc>
    <lastmod>${mod}</lastmod>
    <changefreq>${changefreq}</changefreq>
    <priority>${priority}</priority>
  </url>
EOF
done

# Close XML
echo "</urlset>" >> "$OUT"

# Count
count=$(grep -c "<url>" "$OUT")
echo "Generated sitemap.xml with ${count} URLs"
