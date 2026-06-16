"""SQLite-backed state. Engagements, scope entries, findings, shells, evidence,
and a single active-engagement pointer used so most tools can omit engagement_id."""

from __future__ import annotations

import os
import sqlite3
import uuid
from collections.abc import Iterable, Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

DB_PATH = Path(
    os.environ.get(
        "PENTAGI_MCP_DB",
        str(Path.home() / ".pentagi-mcp" / "state.db"),
    )
)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS engagements (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    authorization_note TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    closed_at TEXT
);
CREATE TABLE IF NOT EXISTS scope (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    engagement_id TEXT NOT NULL,
    target TEXT NOT NULL,
    is_excluded INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(engagement_id) REFERENCES engagements(id)
);
CREATE TABLE IF NOT EXISTS findings (
    id TEXT PRIMARY KEY,
    engagement_id TEXT NOT NULL,
    severity TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    target TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(engagement_id) REFERENCES engagements(id)
);
CREATE TABLE IF NOT EXISTS evidence (
    id TEXT PRIMARY KEY,
    finding_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    content TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(finding_id) REFERENCES findings(id)
);
CREATE TABLE IF NOT EXISTS shells (
    id TEXT PRIMARY KEY,
    engagement_id TEXT NOT NULL,
    target TEXT NOT NULL,
    shell_type TEXT NOT NULL,
    connection_string TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    notes TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(engagement_id) REFERENCES engagements(id)
);
CREATE TABLE IF NOT EXISTS active_engagement (
    pk INTEGER PRIMARY KEY CHECK (pk = 1),
    engagement_id TEXT
);
INSERT OR IGNORE INTO active_engagement (pk, engagement_id) VALUES (1, NULL);
"""


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


@contextmanager
def _connect() -> Iterator[sqlite3.Connection]:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init() -> None:
    with _connect() as c:
        c.executescript(_SCHEMA)


# --- engagements -----------------------------------------------------------


def create_engagement(
    name: str, authorization_note: str, scope_targets: Iterable[str], scope_excludes: Iterable[str]
) -> dict[str, Any]:
    eid = _new_id("eng")
    with _connect() as c:
        c.execute(
            "INSERT INTO engagements(id, name, authorization_note, status, created_at) VALUES (?, ?, ?, 'active', ?)",
            (eid, name, authorization_note, _now()),
        )
        for t in scope_targets:
            c.execute("INSERT INTO scope(engagement_id, target, is_excluded) VALUES (?, ?, 0)", (eid, t))
        for t in scope_excludes:
            c.execute("INSERT INTO scope(engagement_id, target, is_excluded) VALUES (?, ?, 1)", (eid, t))
        c.execute("UPDATE active_engagement SET engagement_id = ? WHERE pk = 1", (eid,))
    return get_engagement(eid)


def list_engagements(include_closed: bool = False) -> list[dict[str, Any]]:
    with _connect() as c:
        q = "SELECT * FROM engagements"
        if not include_closed:
            q += " WHERE status = 'active'"
        q += " ORDER BY created_at DESC"
        return [dict(r) for r in c.execute(q)]


def get_engagement(eid: str) -> dict[str, Any]:
    with _connect() as c:
        row = c.execute("SELECT * FROM engagements WHERE id = ?", (eid,)).fetchone()
        if not row:
            raise ValueError(f"engagement {eid} not found")
        eng = dict(row)
        eng["scope"] = [
            dict(r) for r in c.execute("SELECT target, is_excluded FROM scope WHERE engagement_id = ?", (eid,))
        ]
        eng["finding_count"] = c.execute("SELECT COUNT(*) FROM findings WHERE engagement_id = ?", (eid,)).fetchone()[0]
        eng["shell_count"] = c.execute(
            "SELECT COUNT(*) FROM shells WHERE engagement_id = ? AND status = 'active'", (eid,)
        ).fetchone()[0]
        return eng


def close_engagement(eid: str, status: str = "closed") -> dict[str, Any]:
    with _connect() as c:
        c.execute("UPDATE engagements SET status = ?, closed_at = ? WHERE id = ?", (status, _now(), eid))
        cur = c.execute("SELECT engagement_id FROM active_engagement WHERE pk = 1").fetchone()
        if cur and cur["engagement_id"] == eid:
            c.execute("UPDATE active_engagement SET engagement_id = NULL WHERE pk = 1")
    return get_engagement(eid)


def set_active(eid: str | None) -> str | None:
    with _connect() as c:
        if eid is not None:
            row = c.execute("SELECT id FROM engagements WHERE id = ?", (eid,)).fetchone()
            if not row:
                raise ValueError(f"engagement {eid} not found")
        c.execute("UPDATE active_engagement SET engagement_id = ? WHERE pk = 1", (eid,))
    return eid


def get_active() -> str | None:
    with _connect() as c:
        row = c.execute("SELECT engagement_id FROM active_engagement WHERE pk = 1").fetchone()
        return row["engagement_id"] if row else None


# --- scope ------------------------------------------------------------------


def add_scope(eid: str, target: str, is_excluded: bool) -> None:
    with _connect() as c:
        c.execute(
            "INSERT INTO scope(engagement_id, target, is_excluded) VALUES (?, ?, ?)",
            (eid, target, 1 if is_excluded else 0),
        )


def get_scope(eid: str) -> list[dict[str, Any]]:
    with _connect() as c:
        return [dict(r) for r in c.execute("SELECT target, is_excluded FROM scope WHERE engagement_id = ?", (eid,))]


# --- findings ---------------------------------------------------------------


def add_finding(eid: str, severity: str, title: str, description: str, target: str | None) -> dict[str, Any]:
    fid = _new_id("fnd")
    with _connect() as c:
        c.execute(
            "INSERT INTO findings(id, engagement_id, severity, title, description, target, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (fid, eid, severity, title, description, target, _now()),
        )
        return dict(c.execute("SELECT * FROM findings WHERE id = ?", (fid,)).fetchone())


def list_findings(eid: str, severity: str | None = None) -> list[dict[str, Any]]:
    with _connect() as c:
        if severity:
            rows = c.execute(
                "SELECT * FROM findings WHERE engagement_id = ? AND severity = ? ORDER BY created_at DESC",
                (eid, severity),
            )
        else:
            rows = c.execute("SELECT * FROM findings WHERE engagement_id = ? ORDER BY created_at DESC", (eid,))
        return [dict(r) for r in rows]


def attach_evidence(fid: str, kind: str, content: str) -> dict[str, Any]:
    evid = _new_id("evd")
    with _connect() as c:
        row = c.execute("SELECT id FROM findings WHERE id = ?", (fid,)).fetchone()
        if not row:
            raise ValueError(f"finding {fid} not found")
        c.execute(
            "INSERT INTO evidence(id, finding_id, kind, content, created_at) VALUES (?, ?, ?, ?, ?)",
            (evid, fid, kind, content, _now()),
        )
        return dict(c.execute("SELECT * FROM evidence WHERE id = ?", (evid,)).fetchone())


def list_evidence(fid: str) -> list[dict[str, Any]]:
    with _connect() as c:
        return [dict(r) for r in c.execute("SELECT * FROM evidence WHERE finding_id = ? ORDER BY created_at", (fid,))]


# --- shells -----------------------------------------------------------------


def register_shell(eid: str, target: str, shell_type: str, connection_string: str, notes: str | None) -> dict[str, Any]:
    sid = _new_id("shl")
    with _connect() as c:
        c.execute(
            "INSERT INTO shells(id, engagement_id, target, shell_type, connection_string, status, notes, created_at) "
            "VALUES (?, ?, ?, ?, ?, 'active', ?, ?)",
            (sid, eid, target, shell_type, connection_string, notes, _now()),
        )
        return dict(c.execute("SELECT * FROM shells WHERE id = ?", (sid,)).fetchone())


def list_shells(eid: str, include_dead: bool = False) -> list[dict[str, Any]]:
    with _connect() as c:
        if include_dead:
            rows = c.execute("SELECT * FROM shells WHERE engagement_id = ? ORDER BY created_at DESC", (eid,))
        else:
            rows = c.execute(
                "SELECT * FROM shells WHERE engagement_id = ? AND status = 'active' ORDER BY created_at DESC",
                (eid,),
            )
        return [dict(r) for r in rows]


def get_shell(sid: str) -> dict[str, Any]:
    with _connect() as c:
        row = c.execute("SELECT * FROM shells WHERE id = ?", (sid,)).fetchone()
        if not row:
            raise ValueError(f"shell {sid} not found")
        return dict(row)


def mark_shell_dead(sid: str) -> None:
    with _connect() as c:
        c.execute("UPDATE shells SET status = 'dead' WHERE id = ?", (sid,))
