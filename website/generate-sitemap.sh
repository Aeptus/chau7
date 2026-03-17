#!/usr/bin/env bash
# generate-sitemap.sh — Builds split sitemaps grouped by content type.
# Generates: sitemap-core.xml, sitemap-features.xml, sitemap-compare.xml, sitemap.xml (index)

set -euo pipefail

SITE="https://chau7.sh"
DIR="$(cd "$(dirname "$0")" && pwd)"
MIN_FEATURE_SIZE=3000

today=$(date "+%Y-%m-%d" 2>/dev/null || echo "2026-03-17")

CORE="$DIR/sitemap-core.xml"
FEATURES="$DIR/sitemap-features.xml"
COMPARE="$DIR/sitemap-compare.xml"
INDEX="$DIR/sitemap.xml"

# Header
header='<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'

echo "$header" > "$CORE"
echo "$header" > "$FEATURES"
echo "$header" > "$COMPARE"

core_count=0
feature_count=0
compare_count=0
skipped=0

# Collect all canonical .html files
for file in $(find "$DIR" -name "*.html" -not -path "*/.git/*" | sort); do
    rel="${file#$DIR/}"

    # Skip non-content files
    case "$rel" in
        index-geo.html|404.html) continue ;;
    esac

    # Skip subdirectory index.html when a sibling .html exists (dedup)
    if [[ "$rel" != "index.html" ]] && [[ "$rel" == */index.html ]]; then
        parent_dir="$(dirname "$rel")"
        base="$(basename "$parent_dir")"
        grandparent="$(dirname "$parent_dir")"
        [[ -f "$DIR/${parent_dir}.html" ]] && continue
        [[ -f "$DIR/${grandparent}/${base}.html" ]] && continue
        [[ -f "$DIR/${base}.html" ]] && continue
    fi

    # Build URL
    url="$rel"
    [[ "$url" == "index.html" ]] && url=""
    url="${url%.html}"
    url="${url%/index}"

    # Get lastmod
    mod=$(date -r "$file" "+%Y-%m-%d" 2>/dev/null || echo "2026-03-17")

    # Route to correct sitemap with proper priority
    entry=""
    case "$url" in
        "")
            entry="  <url><loc>${SITE}/</loc><lastmod>${mod}</lastmod><changefreq>weekly</changefreq><priority>1.0</priority></url>"
            echo "$entry" >> "$CORE"; ((core_count++)) ;;
        mcp|remote|the-tech)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>"
            echo "$entry" >> "$CORE"; ((core_count++)) ;;
        pronunciation)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>monthly</changefreq><priority>0.4</priority></url>"
            echo "$entry" >> "$CORE"; ((core_count++)) ;;
        legal|privacy|mentions-legales|politique-de-confidentialite)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>yearly</changefreq><priority>0.2</priority></url>"
            echo "$entry" >> "$CORE"; ((core_count++)) ;;
        golden-ratio|typography)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>monthly</changefreq><priority>0.3</priority></url>"
            echo "$entry" >> "$CORE"; ((core_count++)) ;;
        compare)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>monthly</changefreq><priority>0.8</priority></url>"
            echo "$entry" >> "$COMPARE"; ((compare_count++)) ;;
        compare/*)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>monthly</changefreq><priority>0.8</priority></url>"
            echo "$entry" >> "$COMPARE"; ((compare_count++)) ;;
        features)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>"
            echo "$entry" >> "$FEATURES"; ((feature_count++)) ;;
        features/*)
            filesize=$(wc -c < "$file" | tr -d ' ')
            if [[ "$filesize" -lt "$MIN_FEATURE_SIZE" ]]; then
                ((skipped++)); continue
            fi
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>monthly</changefreq><priority>0.5</priority></url>"
            echo "$entry" >> "$FEATURES"; ((feature_count++)) ;;
        *)
            entry="  <url><loc>${SITE}/${url}</loc><lastmod>${mod}</lastmod><changefreq>monthly</changefreq><priority>0.5</priority></url>"
            echo "$entry" >> "$CORE"; ((core_count++)) ;;
    esac
done

echo "</urlset>" >> "$CORE"
echo "</urlset>" >> "$FEATURES"
echo "</urlset>" >> "$COMPARE"

# ── Concepts sitemap: high-level retrieval nodes ──
# These map to existing pages/sections but surface them as concept entry points
CONCEPTS="$DIR/sitemap-concepts.xml"
echo "$header" > "$CONCEPTS"
concept_count=0

# Each concept: a retrievable knowledge node that answers a class of queries
concepts=(
    "/|1.0|weekly|what is chau7"
    "/features|0.9|weekly|chau7 features list"
    "/mcp|0.9|weekly|chau7 mcp tools terminal automation"
    "/the-tech|0.8|weekly|chau7 technology stack rust metal"
    "/remote|0.8|weekly|chau7 ios remote control"
    "/compare|0.8|monthly|chau7 vs other terminals"
    "/features#ai-detection|0.7|monthly|chau7 ai agent detection"
    "/features#ai-integration|0.7|monthly|chau7 context token optimization"
    "/features#ai-analytics|0.7|monthly|chau7 api cost tracking"
    "/features#catalog|0.6|monthly|chau7 full feature catalog"
)

for concept in "${concepts[@]}"; do
    IFS='|' read -r path priority freq description <<< "$concept"
    echo "  <url><loc>${SITE}${path}</loc><lastmod>${today}</lastmod><changefreq>${freq}</changefreq><priority>${priority}</priority></url>" >> "$CONCEPTS"
    ((concept_count++))
done

echo "</urlset>" >> "$CONCEPTS"

# Sitemap index
today=$(date "+%Y-%m-%d" 2>/dev/null || echo "2026-03-17")
cat > "$INDEX" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <sitemap>
    <loc>${SITE}/sitemap-core.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE}/sitemap-features.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE}/sitemap-compare.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
  <sitemap>
    <loc>${SITE}/sitemap-concepts.xml</loc>
    <lastmod>${today}</lastmod>
  </sitemap>
</sitemapindex>
EOF

total=$((core_count + feature_count + compare_count + concept_count))
echo "Generated sitemap index with 4 sitemaps:"
echo "  sitemap-core.xml:     ${core_count} URLs"
echo "  sitemap-features.xml: ${feature_count} URLs"
echo "  sitemap-compare.xml:  ${compare_count} URLs"
echo "  sitemap-concepts.xml: ${concept_count} concept nodes"
echo "  Skipped thin pages:   ${skipped}"
echo "  Total:                ${total} entries"
