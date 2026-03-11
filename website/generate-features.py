#!/usr/bin/env python3
"""Generate 77 individual feature pages for the Chau7 website."""

import json, os, html as h

OUTDIR = os.path.join(os.path.dirname(__file__), "features")
os.makedirs(OUTDIR, exist_ok=True)

# ── Template ─────────────────────────────────────────────
TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <link rel="icon" type="image/png" href="/logo.png">
    <link rel="apple-touch-icon" href="/logo.png">
    <title>{title} | Chau7 Terminal</title>
    <meta name="description" content="{meta_desc}">
    <meta property="og:title" content="{title} | Chau7">
    <meta property="og:description" content="{meta_desc}">
    <meta property="og:image" content="/screenshots/07-six-tabs-overview.png">
    <meta property="og:type" content="website">
    <meta name="twitter:card" content="summary_large_image">
    <link rel="canonical" href="https://chau7.sh/features/{slug}">
    <link rel="stylesheet" href="/style.css">
    <link rel="stylesheet" href="/feature-page.css">
    <script type="application/ld+json">
    [{{
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "Chau7",
        "operatingSystem": "macOS",
        "applicationCategory": "DeveloperApplication",
        "offers": {{ "@type": "Offer", "price": "0", "priceCurrency": "USD" }}
    }},
    {{
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [
            {{ "@type": "ListItem", "position": 1, "name": "Home", "item": "https://chau7.sh/" }},
            {{ "@type": "ListItem", "position": 2, "name": "Features", "item": "https://chau7.sh/features" }},
            {{ "@type": "ListItem", "position": 3, "name": "{category_name}", "item": "https://chau7.sh/features#{category_id}" }},
            {{ "@type": "ListItem", "position": 4, "name": "{title}" }}
        ]
    }},
    {{
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "mainEntity": [{faq_schema}]
    }}]
    </script>
</head>
<body>
    <!-- Nav -->
    <nav class="nav">
        <div class="nav-inner">
            <a href="/" class="nav-logo">
                <img src="/logo.png" alt="Chau7" class="logo-icon">
                <span class="logo-text">Chau7</span><span class="logo-beta">Beta</span>
            </a>
            <button class="nav-hamburger" aria-label="Toggle menu">
                <span></span><span></span><span></span>
            </button>
            <div class="nav-links">
                <a href="/features">Features</a>
                <a href="/mcp">MCP</a>
                <a href="/the-tech">The Tech</a>
                <a href="/compare">Compare</a>
                <a href="/pronunciation">How to say it</a>
                <a href="https://github.com/nicmusic/chau7" class="nav-cta-download" target="_blank">Download</a>
            </div>
        </div>
    </nav>

    <main>
        <!-- Breadcrumb -->
        <div class="breadcrumb">
            <a href="/">Home</a>
            <span class="breadcrumb-sep">/</span>
            <a href="/features">Features</a>
            <span class="breadcrumb-sep">/</span>
            <a href="/features#{category_id}">{category_name}</a>
            <span class="breadcrumb-sep">/</span>
            <span class="breadcrumb-current">{title}</span>
        </div>

        <!-- Hero -->
        <section class="hero hero-feature" data-category="{category_id}" data-ui="feat-hero">
            <div class="hero-glow"></div>
            <div class="hero-content">
                <div class="section-badge{badge_class}">{category_upper}</div>
                <h1 class="hero-title">{title}</h1>
                <p class="hero-subtitle">{tagline}</p>
            </div>
        </section>

        <!-- Questions This Answers -->
        <section class="questions-section" data-ui="feat-questions">
            <div class="section-inner prose">
                <h2>Questions this answers</h2>
                <ul class="question-list">
{questions_html}
                </ul>
            </div>
        </section>

        <!-- How It Works -->
        <section class="feature-content" data-ui="feat-how">
            <div class="section-inner prose">
                <h2>How it works</h2>
{how_it_works_html}

                <div class="why-matters">
                    <h3>Why it matters</h3>
                    <p>{why_matters}</p>
                </div>
            </div>
        </section>

        <!-- Related Features -->
        <section class="related-features" data-ui="feat-related">
            <div class="section-inner">
                <h2>Related features</h2>
                <div class="related-features-grid">
{related_html}
                </div>
                <div class="feature-random-row">
                    <button type="button" class="btn-outline feature-random-btn">Discover a new feature at random</button>
                </div>
            </div>
        </section>

        <!-- FAQ -->
        <section class="feature-faq" data-ui="feat-faq">
            <div class="section-inner">
                <h2>Frequently asked questions</h2>
                <div class="faq-list">
{faq_html}
                </div>
            </div>
        </section>

        <!-- Download CTA -->
        <section class="footer-cta-section" aria-label="Download call to action" data-ui="feat-cta">
            <div class="section-inner">
                <div class="footer-cta-content">
                    <h2>{cta}</h2>
                    <a href="https://github.com/nicmusic/chau7/releases" class="btn-primary btn-lg">Download for macOS</a>
                    <p class="cta-nudge">Free. Open source. Named after a sock.</p>
                </div>
            </div>
        </section>
    </main>

    <!-- Footer -->
    <footer class="footer">
        <div class="section-inner">
            <div class="footer-grid">
                <div class="footer-brand-col">
                    <div class="footer-brand">
                        <img src="/logo.png" alt="Chau7" class="logo-icon">
                        <span class="logo-text">Chau7</span>
                    </div>
                    <p class="footer-tagline">The AI-native terminal for macOS.</p>
                </div>
                <div class="footer-nav-col">
                    <h4>Product</h4>
                    <a href="/features">Features</a>
                    <a href="/mcp">MCP Tools</a>
                    <a href="/the-tech">The Tech</a>
                    <a href="/compare">Compare</a>
                </div>
                <div class="footer-nav-col">
                    <h4>Resources</h4>
                    <a href="https://github.com/nicmusic/chau7" target="_blank">GitHub</a>
                    <a href="https://github.com/nicmusic/chau7/releases" target="_blank">Releases</a>
                    <a href="/llms.txt">llms.txt</a>
                </div>
                <div class="footer-nav-col">
                    <h4>Colophon</h4>
                    <a href="/golden-ratio.html">The Golden Ratio</a>
                    <a href="/typography.html">Typography</a>
                    <a href="/pronunciation">How to Say It</a>
                </div>
                <div class="footer-nav-col">
                    <h4>Legal</h4>
                    <a href="/legal">Legal Notice</a>
                    <a href="/mentions-legales">Mentions L&eacute;gales</a>
                </div>
            </div>
            <div class="footer-bottom">
                <span>158 Swift files &middot; Rust backend &middot; Metal GPU &middot; 701 tests</span>
            </div>
        </div>
    </footer>

    <script>
        window.CHAU7_FEATURE_PAGES = {feature_urls_json};
    </script>
    <script src="/script.js"></script>
</body>
</html>"""


def badge_class(cat_id):
    m = {"ai-detection":"badge-alt","ai-integration":"badge-alt","mcp":"badge-alt",
         "api-analytics":"badge-blue","rendering":"badge-purple"}
    c = m.get(cat_id, "")
    return f" {c}" if c else ""


def gen_questions(qs):
    return "\n".join(f'                    <li class="question-item">{h.escape(q)}</li>' for q in qs)


def gen_how(paragraphs):
    return "\n".join(f"                <p>{p}</p>" for p in paragraphs)


def gen_related(features, current_slug):
    """Generate up to 3 related feature cards from same category."""
    out = []
    for f in features:
        if f["slug"] == current_slug:
            continue
        if len(out) >= 3:
            break
        star = ' <span class="differentiator-star" title="Differentiator">&#9733;</span>' if f.get("star") else ""
        out.append(f"""                    <a class="catalog-card" href="/features/{f['slug']}">
                        <h4>{h.escape(f['title'])}{star}</h4>
                        <p>{h.escape(f['short_desc'])}</p>
                    </a>""")
    return "\n".join(out)


def gen_faq_html(faqs):
    out = []
    for q, a in faqs:
        out.append(f"""                    <details>
                        <summary>{h.escape(q)}</summary>
                        <div class="faq-answer"><p>{a}</p></div>
                    </details>""")
    return "\n".join(out)


def gen_faq_schema(faqs):
    items = []
    for q, a in faqs:
        items.append(f'{{"@type":"Question","name":"{h.escape(q)}","acceptedAnswer":{{"@type":"Answer","text":"{h.escape(a)}"}}}}')
    return ",".join(items)


def generate_page(feat, category_features):
    page = TEMPLATE.format(
        title=feat["title"],
        slug=feat["slug"],
        meta_desc=feat["meta_desc"],
        category_name=feat["category_name"],
        category_id=feat["category_id"],
        category_upper=feat["category_name"].upper(),
        badge_class=badge_class(feat["category_id"]),
        tagline=feat["tagline"],
        questions_html=gen_questions(feat["questions"]),
        how_it_works_html=gen_how(feat["how_it_works"]),
        why_matters=feat["why_matters"],
        related_html=gen_related(category_features, feat["slug"]),
        faq_html=gen_faq_html(feat["faqs"]),
        faq_schema=gen_faq_schema(feat["faqs"]),
        cta=feat.get("cta", f"Try {feat['title']} in Chau7"),
        feature_urls_json=json.dumps([f'/features/{f["slug"]}' for f in ALL_FEATURES]),
    )
    flat_path = os.path.join(OUTDIR, f"{feat['slug']}.html")
    with open(flat_path, "w") as f:
        f.write(page)

    clean_dir = os.path.join(OUTDIR, feat["slug"])
    os.makedirs(clean_dir, exist_ok=True)
    clean_path = os.path.join(clean_dir, "index.html")
    with open(clean_path, "w") as f:
        f.write(page)


# ── Load data and generate ───────────────────────────────
DATA_FILE = os.path.join(os.path.dirname(__file__), "feature-data.json")
with open(DATA_FILE) as f:
    data = json.load(f)

count = 0
ALL_FEATURES = []
for cat in data["categories"]:
    for feat in cat["features"]:
        ALL_FEATURES.append(feat)

for cat in data["categories"]:
    for feat in cat["features"]:
        feat["category_name"] = cat["name"]
        feat["category_id"] = cat["id"]
        generate_page(feat, cat["features"])
        count += 1

print(f"Generated {count} feature pages in {OUTDIR}")
