"""Docker-exec wrapper, scope enforcement, output parsers.

Defaults to running every tool inside a PentAGI-style sandbox container so the
binaries (nmap, searchsploit, sqlmap, hydra, msfconsole, ...) are wherever the
container has them installed. Override the container with PENTAGI_CONTAINER."""

from __future__ import annotations

import fnmatch
import ipaddress
import json
import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from defusedxml import (
    ElementTree as ET,  # XXE / billion-laughs safe; nmap output includes attacker-influenced service banners
)

from . import state

CONTAINER = os.environ.get("PENTAGI_CONTAINER", "pentagi-sandbox")
# 90s keeps us under Codex/Claude Code's 120s tool-call ceiling.
# Slow scans should run via background = True (see scan_vulns / scan_web / etc.).
DEFAULT_TIMEOUT = int(os.environ.get("PENTAGI_MCP_TIMEOUT", "90"))

# Tag prefix used to mark SNI-forwarding socat processes inside the sandbox
# container so we can find / list / kill them later via pgrep.
PROXY_TAG = "pentagi-mcp-sni-proxy"
PROXY_TAG_REGEX = "[p]entagi-mcp-sni-proxy"


class ScopeError(Exception):
    """Raised when a tool target isn't covered by the engagement's authorized scope."""


@dataclass
class ExecResult:
    cmd: str
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False
    stdout_binary_replaced: bool = False
    stderr_binary_replaced: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {
            "cmd": self.cmd,
            "returncode": self.returncode,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "timed_out": self.timed_out,
            "stdout_binary_replaced": self.stdout_binary_replaced,
            "stderr_binary_replaced": self.stderr_binary_replaced,
        }


@dataclass
class WebTarget:
    """Normalized web target for tools that need URL host, TCP host, and SNI split."""

    original_url: str
    effective_url: str
    logical_host: str
    logical_port: int
    connect_host: str | None
    connect_port: int
    tls_sni: str
    http_host: str
    checked_scope: list[str]
    proxy: dict[str, Any] | None = None

    @property
    def host_header_needed(self) -> bool:
        return self.http_host != _hostport(self.tls_sni, self.logical_port)


def docker_exec(
    cmd: str,
    timeout: int | None = None,
    workdir: str | None = None,
    env: dict[str, str] | None = None,
    wrap_timeout: bool = True,
) -> ExecResult:
    """Run a shell command inside the PentAGI sandbox container.

    The command is wrapped with the container-side `timeout(1)` so long-running
    children (nmap, nuclei, sqlmap) get killed at the boundary instead of being
    orphaned when the host-side subprocess.run times out. Pass `wrap_timeout=False`
    only for fire-and-forget background spawns where the inner process intentionally
    outlives us.
    """
    timeout = timeout or DEFAULT_TIMEOUT
    args = ["docker", "exec"]
    if workdir:
        args += ["-w", workdir]
    if env:
        for k, v in env.items():
            args += ["-e", f"{k}={v}"]
    inner = f"timeout --kill-after=5s {timeout}s sh -c {shlex.quote(cmd)}" if wrap_timeout else cmd
    args += [CONTAINER, "sh", "-c", inner]
    try:
        # errors="replace" — binary output (favicon, etc.) never crashes the wrapper.
        # check=False — we surface returncode in ExecResult; non-zero is expected for
        # many tools (nmap host-down, nuclei no-findings, etc.) and not an error.
        cp = subprocess.run(args, capture_output=True, timeout=timeout + 15, check=False)
        # 124 = container-side `timeout` sent SIGTERM, 137 = SIGKILL aftermath.
        timed_out = cp.returncode in (124, 137)
        stdout = cp.stdout.decode(errors="replace")
        stderr = cp.stderr.decode(errors="replace")
        return ExecResult(
            cmd=cmd,
            returncode=cp.returncode,
            stdout=stdout,
            stderr=stderr,
            timed_out=timed_out,
            stdout_binary_replaced="\ufffd" in stdout,
            stderr_binary_replaced="\ufffd" in stderr,
        )
    except subprocess.TimeoutExpired as e:
        return ExecResult(
            cmd=cmd,
            returncode=-1,
            stdout=(e.stdout or b"").decode(errors="replace")
            if isinstance(e.stdout, (bytes, bytearray))
            else (e.stdout or ""),
            stderr=(e.stderr or b"").decode(errors="replace")
            if isinstance(e.stderr, (bytes, bytearray))
            else (e.stderr or ""),
            timed_out=True,
        )
    except FileNotFoundError:
        return ExecResult(cmd=cmd, returncode=127, stdout="", stderr="docker CLI not found on PATH")


def host_exec(cmd: list[str], timeout: int | None = None) -> ExecResult:
    """Run a command on the HOST (not inside the container). Used by container_file_get."""
    timeout = timeout or DEFAULT_TIMEOUT
    try:
        cp = subprocess.run(cmd, capture_output=True, timeout=timeout, check=False)
        stdout = cp.stdout.decode(errors="replace")
        stderr = cp.stderr.decode(errors="replace")
        return ExecResult(
            cmd=" ".join(shlex.quote(a) for a in cmd),
            returncode=cp.returncode,
            stdout=stdout,
            stderr=stderr,
            stdout_binary_replaced="\ufffd" in stdout,
            stderr_binary_replaced="\ufffd" in stderr,
        )
    except subprocess.TimeoutExpired:
        return ExecResult(cmd=" ".join(cmd), returncode=-1, stdout="", stderr="timed out", timed_out=True)


# --- scope ------------------------------------------------------------------


def _target_matches(target: str, scope_entry: str) -> bool:
    """target may be IP/hostname; scope_entry may be IP, CIDR, hostname, or glob."""
    # CIDR / IP scope
    try:
        net = ipaddress.ip_network(scope_entry, strict=False)
        try:
            return ipaddress.ip_address(target) in net
        except ValueError:
            return False
    except ValueError:
        pass
    # Hostname / glob
    t = target.lower().rstrip(".")
    s = scope_entry.lower().rstrip(".")
    if "*" in s or "?" in s:
        return fnmatch.fnmatch(t, s)
    return t == s or t.endswith("." + s)


def require_scope(target: str, engagement_id: str | None = None) -> str:
    """Raise ScopeError if `target` is not authorized for the (active) engagement.
    Returns the engagement_id on success so callers can carry on with it."""
    eid = engagement_id or state.get_active()
    if not eid:
        raise ScopeError("No active engagement. Call engagement_create or engagement_set_active first.")
    scope = state.get_scope(eid)
    if not scope:
        raise ScopeError(f"Engagement {eid} has no scope entries. Use scope_add to authorize targets.")
    includes = [s["target"] for s in scope if not s["is_excluded"]]
    excludes = [s["target"] for s in scope if s["is_excluded"]]
    if any(_target_matches(target, e) for e in excludes):
        raise ScopeError(f"Target {target!r} is explicitly excluded from engagement {eid}.")
    if not any(_target_matches(target, i) for i in includes):
        raise ScopeError(
            f"Target {target!r} is not in scope for engagement {eid}. "
            f"Allowed: {includes}. Use scope_add to authorize, or pick a different target."
        )
    return eid


def require_engagement(engagement_id: str | None = None) -> str:
    """Return the engagement id without a scope check (for inventory tools, findings, etc.)."""
    eid = engagement_id or state.get_active()
    if not eid:
        raise ScopeError("No active engagement. Call engagement_create or engagement_set_active first.")
    return eid


# --- web target model -------------------------------------------------------


def _default_port(scheme: str) -> int:
    if scheme == "https":
        return 443
    if scheme == "http":
        return 80
    raise ValueError(f"unsupported URL scheme {scheme!r}; expected http or https")


def _hostport(host: str, port: int) -> str:
    default = 443 if port == 443 else 80 if port == 80 else None
    return host if default == port else f"{host}:{port}"


def _scope_host(value: str) -> str:
    """Return a scope-checkable hostname from a host or host:port string."""
    if value.startswith("[") and "]" in value:
        return value[1 : value.index("]")]
    return value.rsplit(":", 1)[0]


def prepare_web_target(
    target_url: str,
    engagement_id: str | None = None,
    *,
    connect_host: str | None = None,
    connect_port: int | None = None,
    tls_sni: str | None = None,
    http_host: str | None = None,
    auto_proxy: bool = True,
) -> WebTarget:
    """Validate scope and produce an effective URL usable from the sandbox.

    `target_url` is the logical target. If `connect_host` is provided and differs
    from the URL/SNI host, a tagged socat proxy is started inside the sandbox so
    scanners can send the correct TLS SNI while TCP connects to the reachable host.
    """
    parsed = urlsplit(target_url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("target_url must start with http:// or https://")
    if not parsed.hostname:
        raise ValueError("target_url must include a hostname")

    logical_host = parsed.hostname
    logical_port = parsed.port or _default_port(parsed.scheme)
    tls_name = tls_sni or logical_host
    http_name = http_host or _hostport(tls_name, logical_port)
    tcp_host = connect_host
    tcp_port = int(connect_port or logical_port)

    checked: list[str] = []
    for candidate in (logical_host, tls_name, _scope_host(http_name), tcp_host):
        if candidate and candidate not in checked:
            require_scope(candidate, engagement_id)
            checked.append(candidate)

    proxy: dict[str, Any] | None = None
    if tcp_host and auto_proxy and (tcp_host != tls_name or tcp_port != logical_port):
        proxy = sni_proxy_start(tls_name, logical_port, tcp_host, tcp_port)
        if proxy.get("status") == "failed":
            raise RuntimeError(
                "failed to start SNI proxy inside sandbox; "
                f"connect_host={tcp_host} connect_port={tcp_port} tls_sni={tls_name}. "
                f"Details: {proxy}"
            )

    netloc = _hostport(tls_name, logical_port)
    path = parsed.path or "/"
    effective_url = urlunsplit((parsed.scheme, netloc, path, parsed.query, parsed.fragment))
    return WebTarget(
        original_url=target_url,
        effective_url=effective_url,
        logical_host=logical_host,
        logical_port=logical_port,
        connect_host=tcp_host,
        connect_port=tcp_port,
        tls_sni=tls_name,
        http_host=http_name,
        checked_scope=checked,
        proxy=proxy,
    )


# --- parsers ----------------------------------------------------------------


def parse_nmap_xml(xml_text: str) -> dict[str, Any]:
    """Squash nmap -oX output into a host/port summary."""
    if not xml_text.strip():
        return {"hosts": [], "raw_empty": True}
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as e:
        return {"error": f"nmap XML parse failed: {e}", "raw": xml_text[:2000]}
    hosts = []
    for h in root.findall("host"):
        status = h.find("status")
        addrs = [a.attrib for a in h.findall("address")]
        hostnames = [hn.attrib.get("name") for hn in h.findall("hostnames/hostname")]
        ports = []
        for p in h.findall("ports/port"):
            state_el = p.find("state")
            service_el = p.find("service")
            ports.append(
                {
                    "port": int(p.attrib.get("portid", "0")),
                    "protocol": p.attrib.get("protocol"),
                    "state": state_el.attrib.get("state") if state_el is not None else None,
                    "service": service_el.attrib.get("name") if service_el is not None else None,
                    "product": service_el.attrib.get("product") if service_el is not None else None,
                    "version": service_el.attrib.get("version") if service_el is not None else None,
                    "extrainfo": service_el.attrib.get("extrainfo") if service_el is not None else None,
                }
            )
        os_matches = [m.attrib for m in h.findall("os/osmatch")][:3]
        hosts.append(
            {
                "addresses": addrs,
                "hostnames": [hn for hn in hostnames if hn],
                "status": status.attrib.get("state") if status is not None else None,
                "ports": ports,
                "os_matches": os_matches,
            }
        )
    return {"hosts": hosts}


def parse_http_headers(text: str) -> dict[str, Any]:
    """Parse `curl -I` output (status line + headers) into a structured shape."""
    if not text.strip():
        return {"status_line": None, "headers": {}}
    lines = [ln.rstrip("\r") for ln in text.split("\n")]
    out: dict[str, Any] = {"status_line": lines[0] if lines else None, "headers": {}}
    for line in lines[1:]:
        if not line.strip() or ":" not in line:
            continue
        k, _, v = line.partition(":")
        out["headers"][k.strip().lower()] = v.strip()
    return out


def parse_web_scan_output(stdout: str) -> list[dict[str, Any]]:
    """Parse common feroxbuster/gobuster result lines into structured entries."""
    results: list[dict[str, Any]] = []
    ferox = re.compile(
        r"^(?P<status>\d{3})\s+(?P<method>[A-Z]+)\s+"
        r"(?P<lines>\d+)l\s+(?P<words>\d+)w\s+(?P<bytes>\d+)c\s+(?P<url>https?://\S+)"
    )
    gobuster = re.compile(
        r"^(?P<path>/\S*)\s+\(Status:\s*(?P<status>\d{3})\)\s+"
        r"\[Size:\s*(?P<bytes>\d+)\]"
    )
    for line in stdout.splitlines():
        text = line.strip()
        if not text:
            continue
        m = ferox.match(text)
        if m:
            item = m.groupdict()
            results.append(
                {
                    "status": int(item["status"]),
                    "method": item["method"],
                    "lines": int(item["lines"]),
                    "words": int(item["words"]),
                    "bytes": int(item["bytes"]),
                    "url": item["url"],
                }
            )
            continue
        m = gobuster.match(text)
        if m:
            item = m.groupdict()
            results.append(
                {
                    "status": int(item["status"]),
                    "method": "GET",
                    "bytes": int(item["bytes"]),
                    "path": item["path"],
                }
            )
    return results


# --- SNI / connect-host proxy ----------------------------------------------
# Many TLS services route by SNI / Host header (Caddy vhosts, k8s ingress).
# When the sandbox container can only reach the target via host.docker.internal
# but the service gates on `localhost`, scan tools end up sending the wrong SNI
# and TLS handshakes fail. The fix: spawn a sandbox-local socat that listens on
# 127.0.0.1:{port} and forwards to the real host. The scan tool then targets
# https://{sni_name}:{port}/ where {sni_name} resolves to 127.0.0.1 (either
# natively for `localhost`, or via an /etc/hosts entry we write).
#
# Proxies are identified by a tag in argv[0] (`exec -a <tag> socat ...`) so we
# can find / list / kill them with pgrep, no extra state file required.


def sni_proxy_start(listen_name: str, listen_port: int, connect_host: str, connect_port: int) -> dict[str, Any]:
    """Idempotent. Ensures `listen_name` resolves to 127.0.0.1 inside the
    sandbox (writes /etc/hosts if needed) and that a socat is listening on
    127.0.0.1:listen_port forwarding to connect_host:connect_port."""
    # Make sure the SNI hostname resolves to 127.0.0.1 in the container.
    if listen_name not in ("localhost", "127.0.0.1"):
        docker_exec(
            f"grep -qE '^127\\.0\\.0\\.1[[:space:]]+.*\\b{listen_name}\\b' /etc/hosts "
            f"|| echo '127.0.0.1 {listen_name}' >> /etc/hosts",
            timeout=10,
        )
    tag = f"{PROXY_TAG}:{listen_port}:{connect_host}:{connect_port}"
    tag_regex = tag.replace(PROXY_TAG, PROXY_TAG_REGEX, 1)
    # Already running?
    if docker_exec(f"pgrep -f {shlex.quote(tag_regex)} >/dev/null", timeout=10).returncode == 0:
        return {
            "status": "already_running",
            "tag": tag,
            "listen_name": listen_name,
            "listen_port": listen_port,
            "connect_host": connect_host,
            "connect_port": connect_port,
        }
    # Spawn a tagged wrapper shell, not bare socat. The wrapper traps TERM,
    # kills socat, and waits for it, avoiding zombie socat processes in
    # containers that were not started with --init/tini.
    socat_cmd = (
        f"socat TCP-LISTEN:{listen_port},bind=127.0.0.1,fork,reuseaddr TCP:{shlex.quote(connect_host)}:{connect_port}"
    )
    wrapper = (
        f"{socat_cmd} & child=$!; "
        'trap \'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0\' TERM INT; '
        'wait "$child"'
    )
    inner = f"exec -a {shlex.quote(tag)} bash -c {shlex.quote(wrapper)}"
    docker_exec(
        f"setsid nohup bash -c {shlex.quote(inner)} >/dev/null 2>&1 < /dev/null &",
        timeout=10,
        wrap_timeout=False,
    )
    # Give it a moment to bind.
    docker_exec("sleep 0.6", timeout=5)
    if docker_exec(f"pgrep -f {shlex.quote(tag_regex)} >/dev/null", timeout=10).returncode == 0:
        return {
            "status": "started",
            "tag": tag,
            "listen_name": listen_name,
            "listen_port": listen_port,
            "connect_host": connect_host,
            "connect_port": connect_port,
        }
    return {
        "status": "failed",
        "tag": tag,
        "hint": "socat may be missing in the container; run container_info to check",
    }


def sni_proxy_list() -> list[dict[str, Any]]:
    r = docker_exec(f"pgrep -af {shlex.quote(PROXY_TAG_REGEX)} 2>/dev/null || true", timeout=10)
    out: list[dict[str, Any]] = []
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, rest = parts
        tag = None
        for tok in rest.split():
            if tok.startswith(PROXY_TAG + ":"):
                tag = tok
                break
        if not tag:
            continue
        fields = tag.split(":")
        # PROXY_TAG itself has no colons → fields = [tag, listen_port, connect_host, connect_port]
        if len(fields) >= 4:
            try:
                out.append(
                    {
                        "pid": int(pid),
                        "tag": tag,
                        "listen_port": int(fields[1]),
                        "connect_host": fields[2],
                        "connect_port": int(fields[3]),
                    }
                )
            except ValueError:
                continue
    return out


def sni_proxy_stop(listen_port: int | None = None, connect_host: str | None = None) -> dict[str, Any]:
    """Kill SNI proxies. Filters compose (both / either / neither)."""
    proxies = sni_proxy_list()
    matched = [
        p
        for p in proxies
        if (listen_port is None or p["listen_port"] == listen_port)
        and (connect_host is None or p["connect_host"] == connect_host)
    ]
    if not matched:
        return {"stopped": 0, "matched": []}
    pids = " ".join(str(p["pid"]) for p in matched)
    r = docker_exec(f"kill {pids} 2>/dev/null; true", timeout=10)
    return {"stopped": len(matched), "matched": matched, "stderr": r.stderr}


def parse_searchsploit(stdout: str) -> list[dict[str, str]]:
    """Parse `searchsploit --json` output, fall back to line scrape."""
    try:
        data = json.loads(stdout)
        return data.get("RESULTS_EXPLOIT") or data.get("RESULTS") or []
    except json.JSONDecodeError:
        results = []
        for raw_line in stdout.splitlines():
            line = raw_line.strip()
            if not line or line.startswith("---") or "Exploit Title" in line:
                continue
            if "|" in line:
                parts = [p.strip() for p in line.split("|")]
                if len(parts) >= 2:
                    results.append({"title": parts[0], "path": parts[-1]})
        return results
