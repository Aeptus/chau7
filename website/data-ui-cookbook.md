# data-ui Cookbook

Every meaningful UI element gets a unique `data-ui` attribute. This makes collaboration unambiguous: "change `hero-subtitle`" means exactly one thing.

## Naming Convention

```
[section]-[element]-[variant]
```

- **kebab-case** always
- **section** = page region (hero, problem, pillars, showcase, ai-preview, proof, cta, footer)
- **element** = what it is (title, subtitle, badge, card, stat, link, img, rule)
- **variant** = disambiguator when needed (primary, secondary, 01, claude, etc.)

## Rules

1. Every element a human might reference in feedback gets a `data-ui`
2. No two elements on a page share the same `data-ui`
3. Repeating patterns use numbered or named variants: `pillars-card-01`, `ai-agent-claude`
4. Navigation and footer use `nav-` and `footer-` prefixes
5. Structural wrappers (that hold no content) don't need `data-ui`
6. `data-ui` goes on the outermost relevant element, not deep inside

## Sections

| Prefix | Region |
|--------|--------|
| `nav-` | Top navigation bar |
| `hero-` | Hero / above the fold |
| `problem-` | "These aren't the terminals" section |
| `pillars-` | Three-pillar feature cards |
| `showcase-` | App screenshot section |
| `ai-` | AI detection / agent cards section |
| `proof-` | "Not Electron" technical proof section |
| `cta-` | Footer call-to-action |
| `footer-` | Site footer |

## Index Page Registry

| data-ui | Element | Content |
|---------|---------|---------|
| `nav` | `<nav>` | Top navigation |
| `nav-logo` | `<a>` | Logo link |
| `nav-features` | `<a>` | Features link |
| `nav-mcp` | `<a>` | MCP link |
| `nav-perf` | `<a>` | Performance link |
| `nav-compare` | `<a>` | Compare link |
| `nav-pronunciation` | `<a>` | Pronunciation link |
| `nav-download` | `<a>` | Download CTA |
| `hero` | `<section>` | Hero section |
| `hero-badge` | `<div>` | Badge strip (3 items) |
| `hero-badge-oss` | `<span>` | "Free & Open Source" |
| `hero-badge-native` | `<span>` | "macOS Native" |
| `hero-badge-sock` | `<span>` | "Named After a Sock" |
| `hero-title` | `<h1>` | Main title |
| `hero-rotator` | `<span>` | Typewriter rotating text |
| `hero-subtitle` | `<p>` | Subtitle paragraph |
| `hero-subtitle-accent` | `<span>` | "Welcome to the shiny world..." |
| `hero-ctas` | `<div>` | CTA button group |
| `hero-cta-download` | `<a>` | "Download for macOS" |
| `hero-cta-sock` | `<a>` | "The sock thing" |
| `hero-stats` | `<div>` | Stats row |
| `hero-stat-context` | `<div>` | ~40% Context Saved |
| `hero-stat-agents` | `<div>` | 1 UI All Agents |
| `hero-stat-mcp` | `<div>` | 20 MCP Tools |
| `hero-stat-price` | `<div>` | $0 Open Source |
| `rule-hero` | `<hr>` | Ink rule after hero |
| `problem` | `<section>` | Problem comparison section |
| `problem-title` | `<h2>` | Section heading |
| `problem-subtitle` | `<p>` | Section subheading |
| `problem-carousel` | `<div>` | Parchment carousel container |
| `problem-sheet-01` | `<div>` | "I know what all my AI do." — AI detection slide |
| `problem-sheet-02` | `<div>` | "My context is automatically optimized." — CTO slide |
| `problem-sheet-03` | `<div>` | "My AI controls my terminal." — MCP tools slide |
| `problem-sheet-04` | `<div>` | "I see what my AI costs." — Cost tracking slide |
| `problem-dots` | `<div>` | Carousel dot navigation |
| `rule-problem` | `<hr>` | Ink rule after problem |
| `pillars` | `<section>` | Three pillars section |
| `pillars-card-mcp` | `<a>` | MCP-First Terminal card |
| `pillars-card-cost` | `<a>` | AI Cost Visibility card |
| `pillars-card-speed` | `<a>` | Rust + Metal Speed card |
| `showcase` | `<section>` | Screenshot section |
| `showcase-img` | `<img>` | Main app screenshot |
| `rule-showcase` | `<hr>` | Ink rule after showcase |
| `ai` | `<section>` | AI detection section |
| `ai-title` | `<h2>` | Section heading |
| `ai-subtitle` | `<p>` | Section subheading |
| `ai-agent-claude` | `<div>` | Claude Code card |
| `ai-agent-codex` | `<div>` | Codex card |
| `ai-agent-gemini` | `<div>` | Gemini CLI card |
| `ai-agent-chatgpt` | `<div>` | ChatGPT card |
| `ai-agent-copilot` | `<div>` | Copilot card |
| `ai-agent-aider` | `<div>` | Aider card |
| `ai-agent-cursor` | `<div>` | Cursor card |
| `ai-agent-custom` | `<div>` | Custom Rules card |
| `ai-link` | `<a>` | "See all AI detection features" |
| `rule-ai` | `<hr>` | Ink rule after AI section |
| `proof` | `<section>` | Technical proof section |
| `proof-title` | `<h2>` | Section heading |
| `proof-body` | `<p>` | Section body text |
| `proof-link` | `<a>` | "Browse all features" link |
| `cta` | `<section>` | Footer CTA section |
| `cta-title` | `<h2>` | CTA heading |
| `cta-aside` | `<p>` | "(Probably.)" |
| `cta-download` | `<a>` | Download button |
| `footer` | `<footer>` | Site footer |
| `footer-brand` | `<div>` | Logo + tagline |
| `footer-nav-product` | `<div>` | Product links column |
| `footer-nav-resources` | `<div>` | Resources links column |
| `footer-bottom` | `<div>` | Bottom stats line |
