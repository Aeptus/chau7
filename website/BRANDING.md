# Chau7 — Design & Branding Guide

## Name & Origin

**Chau7** = *chau* + *sept* (7 in French) = **chaussette** = French for "sock" 🧦

- **Pronunciation:** show-set (/ʃo.sɛt/)
- **Origin:** Insider joke from *Le Donjon de Naheulbeuk*, a cult French MP3 audio saga from the 2000s. *Chaussette* is a running gag in the saga: absurd, out of place, and unforgettable.
- **Tone of the reference:** Affectionate and nerdy. The name is a puzzle (seven-letter word hiding the number 7) and a cultural nod. Accessible to outsiders ("it's a sock, that's funny"), rewarding for insiders.
- **The bar joke:** "And this time it's not a bar… but that would be a great bar name." Naheulbeuk callback for those who know.

## Brand Voice

### Who is Chau7?

**The witty best friend.** Lorelai Gilmore energy. Fast, reference-heavy, always one quip ahead. Talks *with* you, not *at* you. Chau7 is the friend who explains SIMD parsing while making a Firefly reference and somehow both land.

### Voice principles

1. **Relentlessly self-deprecating.** We named our terminal after a sock. Our judgment is clearly impeccable. Lean into the absurdity of what we are. The product is serious. The brand never takes itself seriously.

2. **Lorelai density, Lorelai discretion.** References are everywhere. Humor is constant. But it never alienates. Every joke also works as a straight sentence if you strip the reference. Nobody should need a decoder ring to use the website.

3. **Wink and nod references.** Recognizable if you know the source, invisible if you don't. "I aim to misbehave" as a CTA. "Shiny" as an adjective. "These aren't the terminals you're looking for" as a section header. Never attributed, never explained. If you have to say "as Captain Mal would say," the reference failed.

4. **Confident, not arrogant.** "Your AI deserves a terminal that notices it. Like, at all. Is that too much to ask?" Assert what we built, but with a shrug, not a chest-thump.

5. **Technically honest.** Don't simplify to the point of being wrong. The audience is developers (AI-curious, 25-40). They can handle "SIMD-accelerated Rust parser" and they'll respect you more for saying it.

### Reference universe

These are the cultural touchstones Chau7 draws from. Not all at once. Not in every paragraph. But when a reference fits, reach for these:

| Source | What it gives us |
|--------|-----------------|
| **Firefly / Serenity** | Scrappy underdog energy, "shiny", "I aim to misbehave", Wash's humor |
| **Dr. Horrible's Sing-Along Blog** | The villain who's actually the nerd, "the status is not quo" |
| **Star Trek** | Technical precision, "fascinating", "make it so", exploration metaphors |
| **Star Wars** | "These aren't the droids", the Force as metaphor for invisible intelligence |
| **Gilmore Girls** | Speed, density, warmth, pop culture as native language |
| **Le Donjon de Naheulbeuk** | The sock, the bar, the absurd quest, French nerd solidarity |
| **Monty Python** | Deadpan absurdity, "and now for something completely different" |

### Humor density

**High frequency, low volume.** Every page has humor. Most paragraphs have a wink. But each individual joke is quiet. It's the accumulation that creates the personality, not any single punchline. Think Gilmore Girls: you could miss half the references and still enjoy the conversation.

The pronunciation page is the ceiling for standalone humor pages. Regular feature/product pages should have the same *spirit* but the humor serves the content, not the other way around.

### Headlines and section headers

Two registers, used together:

- **Confident statements** for solution sections: "20 MCP tools. Zero config." / "GPU-accelerated everything."
- **Pop culture riffs** for flavor: "These aren't the terminals you're looking for." / "The status is not quo."

Mix both on a single page. Statements carry the structure. Riffs carry the personality.

### CTAs (Calls to Action)

**Primary CTAs are clear.** "Download for macOS", "View features", "Get started". No one should wonder what the button does.

**Secondary CTAs get personality.** "Browse the arsenal", "See what your terminal's been hiding", "Put on the sock". Fun, still directional.

### Competitor mentions

Two modes, used together:

- **Cheeky but fair** on comparison pages: "iTerm2 is great. It just can't see your AI. That's like a car with no windshield."
- **Confident silence** elsewhere: Don't name competitors. Just say what Chau7 does. If it's better, people figure it out.

Never hostile. Never dismissive. Respect what others built. Then show why this is different.

### Error states and empty states

**Full personality.** Errors are where brand voice matters most.

- 404: "This page pulled a Wash. It's not coming back. But these pages are."
- No results: "The sock drawer is empty. Try a different search?"
- Loading: "Compiling personality…"

A joke first, then immediately helpful. Never leave someone stranded in a bit.

### Self-deprecation

**Frequent and genuine.** The sock name is an open invitation.

- "We named our terminal after a sock. Our judgment is clearly impeccable."
- "Yes, really. Your terminal is named after a sock."
- "A GPU-accelerated sock, if that helps."

Self-deprecation about the brand. Never about the product's capabilities. The engineering is serious. The packaging is absurd. That's the joke.

## Forbidden words and patterns

### Never use

- **Em dashes** (—). Use ellipsis (…), commas, colons, periods, or split into two sentences.
- **Corporate speak:** leverage, synergy, ecosystem, empower, streamline, best-in-class, holistic, robust
- **Startup hype:** disrupt, 10x, scale, growth hack, delightful, supercharge, unlock, elevate
- **Buzzwords:** revolutionary, next-gen, cutting-edge, game-changing, state-of-the-art
- **Filler:** basically, actually, literally (unless literal), just (as minimizer), simply

### Tone rule

If it sounds like a pitch deck or a LinkedIn post, kill it. Read it aloud. If you cringe, rewrite it. If Lorelai wouldn't say it, Chau7 shouldn't either.

## Target audience

**AI-curious developers, 25-40.** Developers adopting AI tools (Claude Code, Copilot, Cursor). Tech-forward, open to new workflows. They've used 5+ terminals. They get Firefly references. They appreciate technical depth and don't need things dumbed down.

## Visual Identity

### North star

**A Da Vinci notebook.** Not a website. A working document: sketches, annotations, corrections, discoveries. The website as artifact. Every page should feel like you found it on a scholar's desk, not generated by a SaaS template.

### Anti-patterns (things Chau7 must never look like)

These are the hallmarks of "The Linear Look" and AI-era sameness. Avoid all of them:

- Thin-bordered cards as universal containers
- Glassmorphism / frosted glass effects
- Purple-blue gradients on dark backgrounds
- Bento grids
- Gradient glow effects / ambient lighting
- Generic dark mode with soft shadows
- The "barely-there UI" aesthetic
- Any layout that could be a Linear or Vercel clone

### Palette (Parchment / Da Vinci)

| Token | Value | Usage |
|-------|-------|-------|
| `--bg` | `#f5ead0` | Parchment base |
| `--bg-card` | `#efe3c8` | Aged card surface |
| `--bg-raised` | `#e8d9b8` | Raised surface |
| `--border` | `#c4a87a` | Warm brown border |
| `--text` | `#2c1810` | Dark sepia ink |
| `--text-muted` | `#6b5744` | Faded ink |
| `--accent` | `#cc7832` | Logo amber, primary accent (pending CSS update from `#a0522d`) |
| `--accent-alt` | `#5b7a3a` | Muted Renaissance green |
| `--gradient` | `135deg, #a0522d → #cc7832` | Sienna to amber |
| `--gradient-alt` | `135deg, #5b7a3a → #7a9f50` | Forest to sage |
| `--electric` | TBD (teal, coral, or chartreuse) | Electric accent for CTAs and key moments only |

**Electric accent:** One unexpected color used sparingly for CTAs, hover states, and attention moments. Breaks the warm palette just enough to surprise. Candidates: `#2dd4bf` (teal), `#f472b6` (coral), `#a3e635` (chartreuse). Pick one. Use it rarely. Make it count.

### Persona accents (earth tones)

| Persona | Color | Hex |
|---------|-------|-----|
| Orchestrator | Deep forest | `#3d5a1e` |
| Speedrunner | Plum | `#644682` |
| Multitasker | Sienna | `#a0522d` |
| Guardian | Brick | `#8c3c3c` |

### No dark mode

Parchment only. The warm, textured aesthetic is the identity. No toggle, no alternate theme.

## Containers and Layout

### Mixed container approach

No single container style. Different content types get different treatments:

- **Floating content:** Text and features that live directly on the parchment. No box. Spacing and typography scale create structure.
- **Ink & paper cards:** Physical-feeling cards with subtle shadows (paper on paper), slightly uneven edges, ink-stamp accents. For feature highlights and interactive elements.
- **Editorial columns:** Multi-column layouts with pull quotes for text-heavy sections.

The variety itself is the design system. A page should feel like a desk with different documents on it, not a grid of identical cards.

### Dividers: ink rules

No thin CSS borders. Visual separation uses:

- **Hand-drawn-feeling horizontal rules**: varying thickness, slightly imperfect, like a broadsheet newspaper or printer's rule.
- **CSS implementation**: use `border-image` or SVG-based lines with subtle irregularity.
- **Supplemented by** whitespace and background tone shifts between major sections.

### Depth: selective elevation

Most elements sit flat on the parchment. Key moments lift off the page:

- **Hero sections**: subtle shadow and scale to create presence
- **CTAs**: elevated with shadow, the electric accent color, and hover lift
- **Feature highlights**: slight paper-stacking shadow (like a note placed on top of a manuscript)
- **Everything else**: flat. Drama through restraint.

## Typography

**System fonts only.** Zero external requests.

| Role | Stack |
|------|-------|
| Headings | `Charter`, `Georgia`, `Times New Roman`, serif |
| Body | `-apple-system`, `Segoe UI`, `Helvetica Neue`, sans-serif |
| Code | `Menlo`, `Cascadia Mono`, `Consolas`, monospace |

All `h1`, `h2`, `h3` use `var(--serif)` (Charter). Body text uses `var(--sans)`.

Typography carries the hierarchy. Current level is good. Don't over-engineer the type, but let it do the heavy lifting that borders and containers used to do.

## Texture and Materiality

- Paper grain via inline SVG noise (`feTurbulence`, 3% opacity) on `body`
- Nav glassmorphism: `rgba(245, 234, 208, 0.85)` with `blur(20px)` (the one exception to the anti-glassmorphism rule, because it serves navigation legibility)
- **Subtle grain only.** Keep it classy. Paper texture, slight noise. Don't push into full zine/collage territory. The imperfection is ambient, not aggressive.

## Visual Elements

### Mix of sketches + screenshots

- **Screenshots** for product proof: real terminal shots, sepia-tinted frames
- **Hand-drawn elements** for diagrams, decoration, and explanation: Da Vinci-style technical sketches, notebook annotations, rendering pipeline diagrams as hand-drawn schematics
- No stock photography. No generic icons. No Material Design.
- **Icons** when needed should feel like ink stamps or printer's marks, not UI icons.

### Comparison sections: annotated manuscript

The "vs other terminals" comparison should look like a scholar's working document:

- Margin notes and corrections
- Da Vinci-style annotations showing what Chau7 adds
- Redacted or crossed-out lines for what others lack
- The page itself is the argument

## Motion and Interaction

### Scroll reveals + micro-interactions

Two layers of motion, working together:

**Scroll-driven reveals:**
- Sections animate in as they enter the viewport
- Not just fade-in. Choreographed: slide, scale, draw-in
- Locomotive / scrollytelling energy. The page is a journey.
- Use `animation-timeline` (CSS) or GSAP ScrollTrigger

**Micro-interactions (the "visual surprises" from the brand personality):**
- Ink splatter on button hover
- Quill stroke animation on link hover
- Subtle paper rustle or page-turn effects
- Da Vinci sketch lines that draw themselves
- Easter egg interactions for the curious
- Small, frequent, delightful. Never distracting.

These are the "visual surprises" the brand personality calls for. They should feel discovered, not announced.

## Pending items

- [ ] Update CSS `--accent` from `#a0522d` to `#cc7832` (logo amber)
- [ ] Choose electric accent color (teal, coral, or chartreuse)
- [ ] Implement ink-rule dividers (replace thin CSS borders)
- [ ] Sepia-tinted screenshot frames
- [ ] Hand-drawn sketch elements (rendering pipeline diagram, terminal frame)
- [ ] Scroll-driven section reveals (GSAP or CSS animation-timeline)
- [ ] Micro-interaction hover effects (ink splatter, quill stroke, etc.)
- [ ] Annotated manuscript comparison section
- [ ] Selective elevation shadows for hero/CTAs
- [ ] 404 page with full personality
- [ ] Review and remove all thin-bordered card patterns across site
- [ ] Review existing copy across all pages for voice consistency
