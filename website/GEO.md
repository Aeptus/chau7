# GEO — Generative Engine Optimization Guide

How to structure Chau7 content so retrieval systems can find, chunk, and surface it cleanly.

This document is the rulebook. Every page on chau7.sh should follow it.

---

## 1. The goal

Make structure and meaning explicit enough that chunking becomes trivial.

If your content is clean enough, chunking becomes almost unnecessary. Systems can split it at any heading, any `<section>`, any `<article>`, and every piece still makes sense on its own.

---

## 2. What retrieval systems look for

Retrieval systems parse pages using four signals:

- **Structural signals**: headings, `<section>`, `<article>`, `data-ui` attributes
- **Local coherence**: sentences that belong together within a block
- **Boundaries**: topic shifts between blocks
- **Redundancy**: repeated key terms that anchor meaning

Design for all four. Every section of every page should be structurally marked, internally coherent, cleanly bounded, and anchored with explicit terminology.

---

## 3. One idea per block

The single most important rule.

Not one paragraph. Not one section. Not one file. **One retrievable unit of meaning.**

Chunking systems try to preserve coherent text blocks. If you mix concept + example + unrelated note in one block, you destroy retrieval precision. A system that retrieves your block for a query about "AI detection" shouldn't also get an unrelated paragraph about session recording.

**Test**: can you describe what this block is about in one phrase? If not, split it.

---

## 4. The content unit pattern

Every unit of Chau7 content follows this pattern:

```
[Title: atomic concept]

What it is (1-2 sentences)

Why it matters (optional)

How it works (optional)

Example (optional)
```

Each unit covers one concept. Not two. Not "MCP and also session recording." One thing, explained completely, then move on.

### Good

```html
<section data-ui="mcp-tool-tab-create">
  <h3>MCP Tool: <code>tab_create</code></h3>
  <p>Opens a new terminal tab via the local MCP server.</p>
  <p>Used by AI agents to run commands in isolated tabs without affecting the user's workspace.</p>
  <pre><code>tool: tab_create
args: { "directory": "/Users/me/project", "exec": "npm test" }</code></pre>
</section>
```

Self-contained. Coherent. Queryable. The `data-ui` attribute names the content semantically.

### Bad

```html
<div>
  <h3>GitHub stuff</h3>
  <p>We connect to GitHub. Also MCP is cool. Sometimes agents fail. Anyway here's a command…</p>
</div>
```

No `data-ui`. No semantic tag. Mixed topics. Vague heading. This kills retrieval.

---

## 5. The `data-ui` attribute (mandatory)

Every `<section>`, `<article>`, and significant content block **must** have a `data-ui` attribute. This is not optional.

### What `data-ui` does

It gives each content block a unique, semantically meaningful identifier that describes what the block contains. Systems use it as a structural signal, a chunk label, and a retrieval hint.

### How to name it

The value must describe the content, not the layout. Use lowercase, hyphenated, specific names.

### Good names

```html
<section data-ui="ai-detection">
<section data-ui="mcp-tool-tab-exec">
<section data-ui="cost-tracking-per-session">
<section data-ui="privacy-local-first">
<article data-ui="compare-vs-iterm2">
<div data-ui="hero-stats">
```

### Bad names

```html
<section data-ui="section-1">         <!-- positional, not semantic -->
<section data-ui="content">           <!-- too vague -->
<section data-ui="left-column">       <!-- layout, not content -->
<div data-ui="box">                   <!-- meaningless -->
```

### Rules

- Every `<section>` gets a `data-ui`
- Every `<article>` gets a `data-ui`
- Hero sections, stat blocks, CTA sections, proof sections all get `data-ui`
- The value describes the content topic, not the visual treatment
- Use the feature name, tool name, or concept name as the base
- Prefix with page context when needed: `features-pillar-cognitive`, `remote-security-chacha`
- Never reuse the same `data-ui` value on the same page

---

## 6. Semantic HTML tags

HTML structure is the strongest signal you can give a retrieval system. Use the right tags for the right purpose.

### `<article>` — A self-contained knowledge unit

Use for: feature pages, tool descriptions, comparison pages, any content that makes sense on its own.

```html
<article data-ui="feature-context-token-optimization">
  <h2>Context Token Optimization</h2>
  <p>Strips terminal noise before your AI reads it. Saves ~40% on context tokens.</p>
  <section data-ui="feature-cto-how-it-works">
    <h3>How it works</h3>
    <p>CTO removes ANSI escape sequences, progress bars, spinner frames...</p>
  </section>
</article>
```

### `<section>` — A thematic group within a page

Use for: each distinct topic on a page. Every `<section>` gets a heading and a `data-ui`.

```html
<section aria-labelledby="security-heading" data-ui="remote-encryption">
  <h2 id="security-heading">The encryption is not decorative.</h2>
  <p>Curve25519 key agreement. ChaChaPoly1305 AEAD.</p>
</section>
```

Rules:
- Every `<section>` gets a heading (`<h2>`, `<h3>`, etc.)
- Use `aria-labelledby` to tie the section to its heading
- One topic per section. Two ideas = two sections.

### `<nav>` — Navigation blocks

Mark navigation as `<nav>` so systems skip it during content extraction. Navs are structure, not content.

```html
<nav aria-label="Feature categories" data-ui="features-category-nav">
  <a href="#ai-detection">AI Detection</a>
  <a href="#mcp">MCP Server</a>
</nav>
```

### `<code>` — Inline technical terms

Use for: tool names, commands, file paths, config keys, any literal value.

```html
<p>The <code>tab_create</code> tool opens a new tab via MCP.</p>
<p>Config lives at <code>~/.claude.json</code>.</p>
```

Without `<code>`, systems may not distinguish "tab_create" (a tool) from "tab create" (two words).

### `<pre><code>` — Multi-line code and output

Use for: code blocks, JSON responses, terminal output, ASCII diagrams.

```html
<pre><code>{
  "tab_id": "C1C4AB49-...",
  "active_app": "Claude",
  "status": "running",
  "cto_active": true
}</code></pre>
```

Rules:
- Always nest `<code>` inside `<pre>` for code blocks
- Use `<pre>` alone for ASCII diagrams or non-code formatted text
- One response per block. One diagram per block.

### `<dl>`, `<dt>`, `<dd>` — Definition lists

Use for: tool parameters, glossary terms, feature-value pairs.

```html
<dl data-ui="mcp-tool-tab-create-params">
  <dt><code>directory</code></dt>
  <dd>Working directory for the new tab. Optional.</dd>
  <dt><code>exec</code></dt>
  <dd>Command to run after tab creation. Optional.</dd>
</dl>
```

### Other semantic tags

| Tag | Use for |
|-----|---------|
| `<figure>` + `<figcaption>` | Screenshots with captions |
| `<details>` + `<summary>` | FAQs, expandable content (systems extract Q&A pairs) |
| `<blockquote>` + `<cite>` | Testimonials, attributed quotes |
| `<time>` | Dates (machine-parseable) |
| `<abbr title="...">` | Acronyms: `<abbr title="Model Context Protocol">MCP</abbr>` |
| `<strong>` / `<em>` | Semantic emphasis (not `<b>` / `<i>`) |

### Tags to avoid for content

| Tag | Problem |
|-----|---------|
| `<div>` for everything | No semantic meaning. Systems can't distinguish content from layout. |
| `<span>` for emphasis | Use `<strong>` or `<em>`. |
| `<br>` for spacing | Use CSS. `<br>` inside paragraphs fragments content. |
| `<b>` / `<i>` | Use `<strong>` / `<em>`. Semantic versions carry meaning. |

---

## 7. Structure as chunk boundaries

Chunking systems prefer not to break structure. Give them explicit boundaries:

- `<section>` with headings and `data-ui` = hard chunk boundary
- `<article>` = self-contained chunk
- `<h2>` / `<h3>` = chunk break hint
- Consistent block sizes within a page

Headings are chunk hints. `<section>` boundaries are chunk walls. `data-ui` attributes are chunk labels.

---

## 8. Embedding clarity

Embeddings average meaning across a text block. Mixed content dilutes the signal.

### Avoid

- Long mixed paragraphs covering multiple topics
- Vague language ("it," "this feature," "the system")
- `<div>` soup with no semantic tags

### Prefer

- Short, precise sentences
- Consistent vocabulary (always say "Context Token Optimization," never "it")
- Explicit naming of every concept in every block
- Proper `<article>`, `<section>`, `<code>` tags with `data-ui`

---

## 9. Retrieval anchors

Repeat key concepts explicitly within each block. This gives embeddings stronger signal.

```html
<section data-ui="ai-detection-overview">
  <h2>AI Detection</h2>
  <p>Chau7 automatically detects AI agents in the terminal.</p>
  <p>This AI detection system identifies Claude Code, Codex, Gemini CLI, ChatGPT,
     Copilot, Aider, and Cursor by monitoring process names in each tab.</p>
</section>
```

"AI detection" appears three times. "AI agents" appears twice. A query for "how does Chau7 detect AI" matches this block strongly.

---

## 10. Consistent patterns

If every block follows the same structure, systems learn the pattern implicitly:

```html
<article data-ui="feature-{slug}">
  <h3>{Feature Name}</h3>
  <p>{What it does — 1-2 sentences}</p>
  <p>{Why it matters}</p>
  <pre><code>{Example}</code></pre>
</article>
```

Apply this to: feature pages, tool descriptions, command references, concept explanations. The consistency improves chunking, retrieval, and answer quality across the entire site.

---

## 11. Think in retrieval queries

For every block, ask: "What query should retrieve this?"

If the answer is unclear, the block is badly structured.

Query: "how does Chau7 detect AI"
→ Should map to ONE `<section data-ui="ai-detection-overview">` that answers it completely.

Query: "what does tab_create do"
→ Should map to ONE `<article data-ui="mcp-tool-tab-create">`.

Query: "is Chau7 free"
→ Should map to ONE block with pricing info and the word "free."

---

## 12. Multi-scale structure

Use blocks at different levels of specificity:

- **Small** (`<code>`, single `<p>` within a `<section>`): individual tools, commands, settings
- **Medium** (`<article>`, `<section>` with `data-ui`): features, workflows
- **Large** (page-level `<main>`, `<article>`): concepts, architecture decisions

Systems may retrieve at different levels depending on query specificity. Clean blocks at each scale serve both "what does `tab_create` do" and "how does Chau7's MCP system work."

---

## 13. Chau7-specific content rules

This is dev docs, system descriptions, and tool interfaces. Not blog content.

### For tools

One tool = one `<section>` with `data-ui="mcp-tool-{name}"`. Include: name in `<h3>` + `<code>`, what it does in `<p>`, parameters in `<dl>`, example in `<pre><code>`.

### For commands

One command = one block with `data-ui="command-{name}"`. The command in `<code>`, what it does, what it returns.

### For concepts

One concept = one `<section>` with `data-ui="{concept-slug}"`. Self-contained explanation with a heading.

### For features

One feature = one `<article>` with `data-ui="feature-{slug}"`. Title, description, how it works, why it matters.

No mixing. Ever.

---

## 14. JSON-LD structured data

JSON-LD is machine-readable metadata embedded in your page. Systems parse it to understand what the page describes without reading the prose.

### Product (every page)

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Chau7",
  "applicationCategory": "DeveloperApplication",
  "operatingSystem": "macOS",
  "description": "AI-native terminal for macOS with local MCP server, AI agent detection, and GPU-accelerated rendering",
  "featureList": [
    "AI detection",
    "MCP tools",
    "Context Token Optimization",
    "GPU acceleration",
    "Session recording",
    "Dangerous command guard"
  ],
  "offers": { "@type": "Offer", "price": "0", "priceCurrency": "USD" }
}
</script>
```

### FAQ (pages with FAQs)

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [{
    "@type": "Question",
    "name": "How does Chau7 detect AI agents?",
    "acceptedAnswer": {
      "@type": "Answer",
      "text": "Chau7 monitors process names in each tab and matches against known AI CLI patterns."
    }
  }]
}
</script>
```

### Feature lists (catalog pages)

```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "ItemList",
  "name": "Chau7 Feature Categories",
  "itemListElement": [
    { "@type": "ListItem", "position": 1, "name": "AI Detection" },
    { "@type": "ListItem", "position": 2, "name": "MCP Server" },
    { "@type": "ListItem", "position": 3, "name": "GPU Rendering" }
  ]
}
</script>
```

### MCP tools as actions (tool pages)

```html
<script type="application/ld+json">
{
  "@type": "Action",
  "name": "tab_create",
  "description": "Opens a new terminal tab via MCP",
  "target": {
    "@type": "EntryPoint",
    "actionPlatform": "unix-socket",
    "urlTemplate": "mcp://localhost/tab_create"
  }
}
</script>
```

### Rules

- One `<script type="application/ld+json">` block per schema type
- Multiple blocks per page are fine (product + FAQ + breadcrumb)
- Keep `description` and `featureList` aligned with the actual page content
- Update JSON-LD when features change

---

## 15. The future: pages as AI-readable APIs

Websites are evolving into AI-readable APIs disguised as pages. Systems don't just scrape text. They parse structure, extract objects, and consume pages like endpoints.

Chau7 is uniquely positioned here because it already has a machine-readable interface (MCP). The website should mirror that philosophy.

### What we already expose

- `feature-data.json`: structured data for all features at a known URL
- `llms.txt`: machine-readable project summary for LLMs
- JSON-LD on every page: product, FAQ, and feature schemas
- Semantic HTML with `data-ui` attributes on every section

### The trajectory

Today: structured HTML + JSON-LD + `llms.txt` + `feature-data.json`

Tomorrow: pages that are simultaneously human-readable marketing and machine-consumable tool registries. Chau7's website can be both because the product is built around machine-readable interfaces (MCP, JSON-RPC). The website speaks the same language.

The end state: an AI agent reads your website and knows how to use your product. Not "learns about" your product. Knows how to use it.

---

## 16. Page checklist

Before publishing any page, verify:

- [ ] Every `<section>` has a `data-ui` attribute with a semantic name
- [ ] Every `<section>` has a heading
- [ ] Every `<article>` has a `data-ui` attribute
- [ ] One idea per block, no mixing
- [ ] Key terms repeated explicitly (no "it" or "this feature")
- [ ] `<code>` used for all tool names, commands, file paths
- [ ] `<pre><code>` used for all code blocks and examples
- [ ] JSON-LD present (at minimum: SoftwareApplication)
- [ ] FAQ JSON-LD present if page has FAQs
- [ ] No `<div>` used where a semantic tag would work
- [ ] Each block answers one clear retrieval query
- [ ] Consistent structure across similar blocks on the page
