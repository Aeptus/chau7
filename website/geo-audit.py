#!/usr/bin/env python3
"""
geo-audit.py — Progressive GEO/AEO page auditor using Chau7 MCP.

Reads geo-aeo-tracker.json, picks the next unreviewed page, constructs
an AEO audit prompt with the page HTML and its 5 core questions, then
submits it to a Claude Code session running in a Chau7 tab via MCP.

Usage:
    python3 geo-audit.py              # Audit next unreviewed page
    python3 geo-audit.py --all        # Audit all unreviewed pages
    python3 geo-audit.py --page /mcp  # Audit a specific page
    python3 geo-audit.py --list       # List unreviewed pages
    python3 geo-audit.py --prompt-only # Generate prompts without running Claude
"""

import json
import os
import socket
import sys
import time
import argparse
import subprocess
from pathlib import Path

# ── Config ──────────────────────────────────────────
WEBSITE_DIR = Path(__file__).parent.resolve()
TRACKER_FILE = WEBSITE_DIR / "geo-aeo-tracker.json"
GEO_GUIDE = WEBSITE_DIR / "GEO.md"
SOCKET_PATH = Path.home() / "Library" / "Application Support" / "Chau7" / "mcp.sock"
PROMPT_DIR = WEBSITE_DIR / ".geo-prompts"
RESULTS_DIR = WEBSITE_DIR / ".geo-results"


# ── MCP Client ──────────────────────────────────────
class ChauMCP:
    """Minimal MCP client over Unix socket."""

    def __init__(self, socket_path=SOCKET_PATH):
        self.socket_path = str(socket_path)
        self._id = 0

    def _next_id(self):
        self._id += 1
        return self._id

    def call(self, method, params=None):
        """Send a JSON-RPC call to the Chau7 MCP server."""
        msg = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "tools/call",
            "params": {
                "name": method,
                "arguments": params or {}
            }
        }
        return self._send(msg)

    def _send(self, msg):
        """Send a message over the Unix socket and read the response."""
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(self.socket_path)
            payload = json.dumps(msg).encode("utf-8")

            # MCP stdio transport: Content-Length header + \r\n\r\n + body
            header = "Content-Length: {}\r\n\r\n".format(len(payload)).encode("utf-8")
            sock.sendall(header + payload)

            # Read response
            response = self._read_response(sock)
            return response
        except FileNotFoundError:
            print("ERROR: MCP socket not found at {}".format(self.socket_path))
            print("Is Chau7 running?")
            sys.exit(1)
        except ConnectionRefusedError:
            print("ERROR: MCP server refused connection at {}".format(self.socket_path))
            print("Is Chau7 running with MCP enabled?")
            sys.exit(1)
        finally:
            sock.close()

    def _read_response(self, sock, timeout=30):
        """Read a Content-Length framed JSON-RPC response."""
        sock.settimeout(timeout)
        buf = b""

        # Read headers
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk

        if b"\r\n\r\n" not in buf:
            return {"error": "No response headers"}

        header_end = buf.index(b"\r\n\r\n")
        headers = buf[:header_end].decode("utf-8")
        body_start = buf[header_end + 4:]

        # Parse Content-Length
        content_length = 0
        for line in headers.split("\r\n"):
            if line.lower().startswith("content-length:"):
                content_length = int(line.split(":", 1)[1].strip())

        # Read remaining body
        body = body_start
        while len(body) < content_length:
            chunk = sock.recv(min(4096, content_length - len(body)))
            if not chunk:
                break
            body += chunk

        try:
            return json.loads(body[:content_length])
        except json.JSONDecodeError:
            return {"error": "Invalid JSON response", "raw": body[:500].decode("utf-8", errors="replace")}

    def tab_list(self):
        return self.call("tab_list")

    def tab_create(self, directory=None):
        params = {}
        if directory:
            params["directory"] = str(directory)
        return self.call("tab_create", params)

    def tab_exec(self, tab_id, command):
        return self.call("tab_exec", {"tab_id": tab_id, "command": command})

    def tab_output(self, tab_id, lines=500):
        return self.call("tab_output", {"tab_id": tab_id, "lines": lines})

    def tab_close(self, tab_id, force=False):
        return self.call("tab_close", {"tab_id": tab_id, "force": force})


# ── Tracker ─────────────────────────────────────────
def load_tracker():
    with open(TRACKER_FILE, "r") as f:
        return json.load(f)


def save_tracker(data):
    with open(TRACKER_FILE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def get_unreviewed_pages(tracker):
    """Find pages where geo_optimization.primary_geo_query is null."""
    unreviewed = []
    for page in tracker.get("pages", []):
        geo = page.get("geo_optimization", {})
        if geo.get("primary_geo_query") is None:
            unreviewed.append(page)
    return unreviewed


def find_page_by_path(tracker, path):
    """Find a specific page in the tracker by URL path."""
    for page in tracker.get("pages", []):
        url = page.get("url", {})
        if url.get("path") == path or url.get("slug") == path:
            return page
    return None


def mark_page_reviewed(tracker, page_path, result_file, questions):
    """Mark a page as reviewed in the tracker and save."""
    today = time.strftime("%Y-%m-%d")
    for page in tracker.get("pages", []):
        url = page.get("url", {})
        if url.get("path") == page_path or url.get("slug") == page_path:
            # Read result if available
            coverage = {}
            result_text = ""
            rf = Path(result_file)
            if rf.exists() and rf.stat().st_size > 100:
                result_text = rf.read_text(encoding="utf-8")

            # Parse coverage scores from result (YES/PARTIAL/NO per question)
            for q in questions:
                qtext = q.get("question", "")
                # Default to "reviewed" even if we can't parse scores
                coverage[qtext] = "reviewed"

            # Update tracker fields
            geo = page.setdefault("geo_optimization", {})
            geo["primary_geo_query"] = questions[0]["question"] if questions else "reviewed"
            geo["last_audited"] = today
            geo["result_file"] = str(result_file)
            geo["audit_status"] = "completed" if result_text else "prompt_generated"

            # Also mark in a top-level field for easy filtering
            page["last_audited"] = today
            page["audit_status"] = geo["audit_status"]

            save_tracker(tracker)
            return True
    return False


# ── HTML Reader ─────────────────────────────────────
def read_page_html(page_entry):
    """Read the HTML content for a tracker page entry."""
    path = page_entry.get("url", {}).get("path", "")
    if path == "/":
        filepath = WEBSITE_DIR / "index.html"
    else:
        # Try path.html first, then path/index.html
        slug = path.strip("/")
        filepath = WEBSITE_DIR / "{}.html".format(slug)
        if not filepath.exists():
            filepath = WEBSITE_DIR / slug / "index.html"

    if filepath.exists():
        return filepath.read_text(encoding="utf-8")
    return None


# ── Prompt Builder ──────────────────────────────────
def build_audit_prompt(page_entry, html_content):
    """Build the full AEO audit prompt for a page."""
    url = page_entry.get("url", {})
    questions = page_entry.get("core_questions", [])

    questions_block = ""
    for q in questions:
        questions_block += "  {}. {} ({})\n".format(q["rank"], q["question"], q["type"])
        questions_block += "     Rationale: {}\n".format(q["rationale"])
        questions_block += "     Section: {}\n\n".format(q["section_mapped"])

    prompt = """You are an AI system performing an Answer Engine Optimization (AEO) audit.

Your goal is to evaluate whether this page can be:
- retrieved by an AI system
- used as a direct answer
- cited as a reliable source

You are NOT evaluating design or style.
You are evaluating: clarity, extractability, and coverage.

---

PAGE: {production}
TITLE: {title}

FULL PAGE CONTENT:

{html}

---

TARGET QUESTIONS:

{questions}
---

TASK:

For EACH question:

1. Determine if the page contains a clear, self-contained answer

2. Evaluate answer quality:
   - Is the answer explicit (not implied)?
   - Can it be extracted as a standalone paragraph?
   - Does it clearly mention the entity (e.g. Chau7)?
   - Is it unambiguous?

3. Assign a coverage score:
   - YES: clear, strong answer
   - PARTIAL: answer exists but is fragmented or implicit
   - NO: missing or unusable

4. If PARTIAL or NO:
   - Explain exactly what is missing
   - Suggest a concrete 1-2 sentence "ideal answer block"

---

ADDITIONAL GLOBAL ANALYSIS:

After reviewing all questions:

5. Identify:
   - Missing core questions (if any)
   - Redundant or overlapping content
   - Sections that are not retrievable (too vague, too long, too mixed)

6. Evaluate:
   - Does the page define the entity clearly and early?
   - Does each section map to a distinct user intent?
   - Are answers "chunkable" (1 idea per block)?

---

OUTPUT FORMAT:

For each question:
- Question
- Coverage (YES / PARTIAL / NO)
- Explanation
- Suggested fix (if needed)

Then:

GLOBAL SUMMARY:
- Strengths
- Weaknesses
- Top 3 improvements to implement

Keep your response concise. No preamble. Go straight to the audit.""".format(
        production=url.get("production", url.get("path", "unknown")),
        title=page_entry.get("page_identity", {}).get("title", "unknown"),
        html=html_content,
        questions=questions_block,
    )

    return prompt


# ── Execution ───────────────────────────────────────
def run_audit_via_mcp(mcp, prompt, safe_slug):
    """Create a Chau7 tab and run Claude Code with the prompt."""
    PROMPT_DIR.mkdir(exist_ok=True)
    RESULTS_DIR.mkdir(exist_ok=True)

    prompt_file = PROMPT_DIR / "audit-{}.md".format(safe_slug)
    result_file = RESULTS_DIR / "result-{}.md".format(safe_slug)
    prompt_file.write_text(prompt, encoding="utf-8")

    print("  Prompt written to: {}".format(prompt_file))
    print("  Creating Chau7 tab...")

    # Create tab in website directory
    tab_result = mcp.tab_create(directory=str(WEBSITE_DIR))

    # Extract tab ID from result
    tab_id = extract_tab_id(tab_result)

    if not tab_id:
        print("  WARNING: Could not extract tab_id from response")
        print("  Prompt saved at: {}".format(prompt_file))
        print("  Run manually: claude -p \"$(cat {})\"".format(prompt_file))
        return None

    print("  Tab created: {}".format(tab_id))
    print("  Running Claude Code audit...")

    # Use tab_exec to run claude with the prompt file, output to result file
    mcp.tab_exec(tab_id, "claude -p \"$(cat '{}')\" > '{}' 2>&1".format(
        prompt_file, result_file
    ))

    return {
        "tab_id": tab_id,
        "prompt_file": str(prompt_file),
        "result_file": str(result_file),
    }


def run_audit_locally(prompt, safe_slug):
    """Run Claude Code directly (no MCP) with the prompt."""
    PROMPT_DIR.mkdir(exist_ok=True)
    RESULTS_DIR.mkdir(exist_ok=True)

    prompt_file = PROMPT_DIR / "audit-{}.md".format(safe_slug)
    result_file = RESULTS_DIR / "result-{}.md".format(safe_slug)
    prompt_file.write_text(prompt, encoding="utf-8")

    print("  Prompt: {} ({} chars)".format(prompt_file, len(prompt)))
    print("  Running Claude Code locally...")

    try:
        result = subprocess.run(
            ["claude", "-p", prompt],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(WEBSITE_DIR),
        )
        result_file.write_text(result.stdout, encoding="utf-8")
        print("  Result saved to: {}".format(result_file))
        return str(result_file)
    except FileNotFoundError:
        print("  ERROR: 'claude' CLI not found in PATH")
        print("  Prompt saved at: {}".format(prompt_file))
        return None
    except subprocess.TimeoutExpired:
        print("  TIMEOUT: Claude Code took too long (5 min limit)")
        print("  Prompt saved at: {}".format(prompt_file))
        return None


def extract_tab_id(tab_result):
    """Extract tab_id from various MCP response formats."""
    if not isinstance(tab_result, dict):
        return None

    # Try result.content[].text as JSON
    result = tab_result.get("result", {})
    if isinstance(result, dict):
        content = result.get("content", [])
        if isinstance(content, list):
            for item in content:
                text = item.get("text", "") if isinstance(item, dict) else ""
                try:
                    data = json.loads(text)
                    if "tab_id" in data:
                        return data["tab_id"]
                except (json.JSONDecodeError, TypeError):
                    pass
        # Try direct tab_id
        if "tab_id" in result:
            return result["tab_id"]
    elif isinstance(result, str):
        try:
            data = json.loads(result)
            if "tab_id" in data:
                return data["tab_id"]
        except json.JSONDecodeError:
            pass

    return None


# ── Main ────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="GEO/AEO page auditor using Chau7 MCP")
    parser.add_argument("--all", action="store_true", help="Audit all unreviewed pages")
    parser.add_argument("--page", type=str, help="Audit a specific page by path (e.g. /mcp)")
    parser.add_argument("--list", action="store_true", help="List unreviewed pages")
    parser.add_argument("--prompt-only", action="store_true", help="Generate prompts without running Claude")
    parser.add_argument("--local", action="store_true", help="Run Claude locally instead of via MCP tab")
    parser.add_argument("--status", action="store_true", help="Show audit progress summary")
    args = parser.parse_args()

    # Check tracker exists
    if not TRACKER_FILE.exists():
        print("ERROR: Tracker not found at {}".format(TRACKER_FILE))
        sys.exit(1)

    tracker = load_tracker()
    total_pages = len(tracker.get("pages", []))

    if args.status:
        unreviewed = get_unreviewed_pages(tracker)
        reviewed = total_pages - len(unreviewed)
        completed = sum(1 for p in tracker.get("pages", []) if p.get("audit_status") == "completed")
        prompted = sum(1 for p in tracker.get("pages", []) if p.get("audit_status") == "prompt_generated")
        print("GEO Audit Progress")
        print("  Total pages:      {}".format(total_pages))
        print("  Reviewed:         {}".format(reviewed))
        print("  Completed:        {}".format(completed))
        print("  Prompt generated: {}".format(prompted))
        print("  Remaining:        {}".format(len(unreviewed)))
        pct = (reviewed / total_pages * 100) if total_pages else 0
        bar = "#" * int(pct // 2) + "-" * (50 - int(pct // 2))
        print("  [{}] {:.0f}%".format(bar, pct))
        return

    if args.list:
        unreviewed = get_unreviewed_pages(tracker)
        reviewed = total_pages - len(unreviewed)
        print("Progress: {} / {} reviewed".format(reviewed, total_pages))
        print("Unreviewed: {}".format(len(unreviewed)))
        print()
        for p in unreviewed:
            url = p.get("url", {})
            print("  {:30s}  {}".format(url.get("path", "?"), url.get("slug", "")))
        return

    # Determine which pages to audit
    pages_to_audit = []
    if args.page:
        page = find_page_by_path(tracker, args.page)
        if not page:
            print("ERROR: Page '{}' not found in tracker".format(args.page))
            sys.exit(1)
        pages_to_audit = [page]
    elif args.all:
        pages_to_audit = get_unreviewed_pages(tracker)
    else:
        unreviewed = get_unreviewed_pages(tracker)
        if not unreviewed:
            print("All {} pages have been reviewed!".format(total_pages))
            return
        pages_to_audit = [unreviewed[0]]

    print("Pages to audit: {}".format(len(pages_to_audit)))
    print()

    # Connect to MCP if needed
    mcp = None
    use_mcp = not args.prompt_only and not args.local
    if use_mcp:
        if SOCKET_PATH.exists():
            mcp = ChauMCP()
            print("Connected to Chau7 MCP at {}".format(SOCKET_PATH))
        else:
            print("MCP socket not found. Falling back to local mode.")
            use_mcp = False

    PROMPT_DIR.mkdir(exist_ok=True)
    RESULTS_DIR.mkdir(exist_ok=True)

    # Process each page
    for i, page in enumerate(pages_to_audit):
        url = page.get("url", {})
        path = url.get("path", "?")
        slug = url.get("slug", path.strip("/").replace("/", "-") or "homepage")
        safe_slug = slug.lower().replace(" ", "-").replace("/", "-")

        print("[{}/{}] Auditing: {} ({})".format(i + 1, len(pages_to_audit), path, slug))

        # Read HTML
        html = read_page_html(page)
        if not html:
            print("  SKIP: Could not read HTML for {}".format(path))
            continue

        # Build prompt
        prompt = build_audit_prompt(page, html)

        if args.prompt_only:
            prompt_file = PROMPT_DIR / "audit-{}.md".format(safe_slug)
            prompt_file.write_text(prompt, encoding="utf-8")
            print("  Prompt saved: {} ({} chars)".format(prompt_file, len(prompt)))
            result_path = str(RESULTS_DIR / "result-{}.md".format(safe_slug))
            mark_page_reviewed(tracker, path, result_path, page.get("core_questions", []))
            print("  Marked as reviewed in tracker")
            print()
            continue

        result_path = None
        if use_mcp and mcp:
            result = run_audit_via_mcp(mcp, prompt, safe_slug)
            if result:
                print("  Audit running in tab {}".format(result["tab_id"]))
                print("  Result will appear at: {}".format(result["result_file"]))
                result_path = result["result_file"]
        else:
            result_path = run_audit_locally(prompt, safe_slug)

        # Mark reviewed in tracker
        if result_path:
            mark_page_reviewed(tracker, path, result_path, page.get("core_questions", []))
            print("  Marked as reviewed in tracker")

        print()

        # If not --all, pause between pages
        if not args.all and i < len(pages_to_audit) - 1:
            try:
                input("Press Enter for next page (Ctrl+C to stop)...")
            except KeyboardInterrupt:
                print("\nStopped.")
                break

    print()
    print("Done.")
    print("Prompts: {}".format(PROMPT_DIR))
    print("Results: {}".format(RESULTS_DIR))


if __name__ == "__main__":
    main()
