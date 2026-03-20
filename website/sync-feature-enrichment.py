#!/usr/bin/env python3
from __future__ import annotations

import html
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
FEATURE_DATA_PATH = ROOT / "feature-data.json"
ENRICHMENT_PATH = ROOT / "feature-enrichment.json"
START_MARKER = "        <!-- Enrichment: feature details -->"
END_MARKER = "        <!-- /Enrichment: feature details -->"
INSERT_BEFORE = "        <!-- Related Features -->"


def load_feature_slugs() -> list[str]:
    data = json.loads(FEATURE_DATA_PATH.read_text())
    return [
        feature["slug"]
        for category in data["categories"]
        for feature in category["features"]
    ]


def load_enrichment() -> dict[str, dict[str, list[str]]]:
    return json.loads(ENRICHMENT_PATH.read_text())


def render_inline_markup(text: str) -> str:
    parts = text.split("`")
    rendered: list[str] = []
    for index, part in enumerate(parts):
        escaped = html.escape(part)
        if index % 2 == 1:
            rendered.append(f"<code>{escaped}</code>")
        else:
            rendered.append(escaped)
    return "".join(rendered)


def render_list(items: list[str]) -> str:
    lines = ['                    <ul class="feature-checklist">']
    for item in items:
        lines.append(f"                        <li>{render_inline_markup(item)}</li>")
    lines.append("                    </ul>")
    return "\n".join(lines)


def render_block(payload: dict[str, list[str]]) -> str:
    pain = render_list(payload["pain"])
    subfeatures = render_list(payload["subfeatures"])
    return "\n".join(
        [
            START_MARKER,
            '        <section class="feature-content feature-pain" data-ui="feat-pain">',
            '            <div class="section-inner prose">',
            "                <h2>The pain this solves</h2>",
            pain,
            "            </div>",
            "        </section>",
            "",
            '        <section class="feature-content feature-subfeatures" data-ui="feat-subfeatures">',
            '            <div class="section-inner prose">',
            "                <h2>What ships with it</h2>",
            subfeatures,
            "            </div>",
            "        </section>",
            END_MARKER,
            "",
        ]
    )


def upsert_block(contents: str, block: str) -> str:
    if START_MARKER in contents and END_MARKER in contents:
        start = contents.index(START_MARKER)
        end = contents.index(END_MARKER) + len(END_MARKER)
        trailing = contents[end:]
        if trailing.startswith("\n"):
            end += 1
        return contents[:start] + block + contents[end:]

    if INSERT_BEFORE not in contents:
        raise ValueError(f"Could not find insertion marker: {INSERT_BEFORE}")
    return contents.replace(INSERT_BEFORE, block + INSERT_BEFORE, 1)


def update_file(path: Path, payload: dict[str, list[str]]) -> None:
    block = render_block(payload)
    updated = upsert_block(path.read_text(), block)
    path.write_text(updated)


def main() -> None:
    slugs = load_feature_slugs()
    enrichment = load_enrichment()

    missing = sorted(set(slugs) - set(enrichment))
    extra = sorted(set(enrichment) - set(slugs))
    if missing or extra:
        problems = []
        if missing:
            problems.append(f"missing: {', '.join(missing)}")
        if extra:
            problems.append(f"extra: {', '.join(extra)}")
        raise SystemExit("Enrichment map mismatch: " + " | ".join(problems))

    for slug in slugs:
        payload = enrichment[slug]
        for key in ("pain", "subfeatures"):
            if not payload.get(key):
                raise SystemExit(f"{slug}: '{key}' must not be empty")
        for path in (
            ROOT / "features" / f"{slug}.html",
            ROOT / "features" / slug / "index.html",
        ):
            if not path.exists():
                raise SystemExit(f"Missing feature page: {path}")
            update_file(path, payload)

    print(f"Updated enrichment blocks for {len(slugs)} feature pages.")


if __name__ == "__main__":
    main()
