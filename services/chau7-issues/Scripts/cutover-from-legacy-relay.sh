#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ISSUES_CONFIG="$ROOT_DIR/services/chau7-issues/wrangler.toml"
ISSUES_DOMAIN="${ISSUES_DOMAIN:-issues.chau7.sh}"
ISSUES_WORKER="${ISSUES_WORKER:-chau7-issues}"
LEGACY_WORKER="${LEGACY_WORKER:-chau7-relay}"
RUN_SMOKE="${RUN_SMOKE:-1}"
DELETE_LEGACY_WORKER="${DELETE_LEGACY_WORKER:-1}"

if [[ -n "${WRANGLER_BIN:-}" ]]; then
  WRANGLER="$WRANGLER_BIN"
elif [[ -x "$ROOT_DIR/services/chau7-relay/node_modules/.bin/wrangler" ]]; then
  WRANGLER="$ROOT_DIR/services/chau7-relay/node_modules/.bin/wrangler"
elif command -v wrangler >/dev/null 2>&1; then
  WRANGLER="$(command -v wrangler)"
else
  echo "error: wrangler not found. Install dependencies in services/chau7-relay or set WRANGLER_BIN." >&2
  exit 1
fi

if [[ -z "${GITHUB_ISSUE_PAT:-}" ]]; then
  echo "error: GITHUB_ISSUE_PAT is required. Use a fine-grained GitHub PAT scoped to the private intake repo with Issues read/write." >&2
  exit 1
fi

if [[ -z "${GITHUB_ISSUE_REPO:-}" ]]; then
  echo "error: GITHUB_ISSUE_REPO is required, for example owner/repo." >&2
  exit 1
fi

if [[ ! "$GITHUB_ISSUE_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "error: GITHUB_ISSUE_REPO must be in owner/repo format." >&2
  exit 1
fi

echo "Using wrangler: $WRANGLER"
echo "Issue worker: $ISSUES_WORKER"
echo "Legacy worker to retire: $LEGACY_WORKER"
echo "Domain to cut over: $ISSUES_DOMAIN"

echo
echo "1/5 Ensuring $ISSUES_WORKER exists before domain cutover..."
if "$WRANGLER" versions list --config "$ISSUES_CONFIG" >/dev/null 2>&1; then
  echo "$ISSUES_WORKER already exists; skipping bootstrap deploy."
else
  "$WRANGLER" deploy --config "$ISSUES_CONFIG" --keep-vars --message "Create issue intake worker before domain cutover"
fi

echo
echo "2/5 Installing issue intake secrets on $ISSUES_WORKER..."
printf '%s' "$GITHUB_ISSUE_PAT" | "$WRANGLER" secret put GITHUB_ISSUE_PAT --config "$ISSUES_CONFIG"
printf '%s' "$GITHUB_ISSUE_REPO" | "$WRANGLER" secret put GITHUB_ISSUE_REPO --config "$ISSUES_CONFIG"

echo
echo "3/5 Routing $ISSUES_DOMAIN to $ISSUES_WORKER..."
"$WRANGLER" deploy \
  --config "$ISSUES_CONFIG" \
  --keep-vars \
  --domain "$ISSUES_DOMAIN" \
  --message "Route $ISSUES_DOMAIN to issue intake worker"

echo
echo "4/5 Verifying $ISSUES_DOMAIN is served by $ISSUES_WORKER..."
landing=""
for attempt in {1..12}; do
  landing="$(curl -fsSL "https://$ISSUES_DOMAIN/" || true)"
  if grep -q "Chau7 Issue Intake" <<<"$landing"; then
    break
  fi
  echo "Domain is not serving Chau7 Issue Intake yet; retrying ($attempt/12)..."
  sleep 5
done

if ! grep -q "Chau7 Issue Intake" <<<"$landing"; then
  echo "error: $ISSUES_DOMAIN did not return the Chau7 Issue Intake landing page." >&2
  echo "The domain may still be attached to $LEGACY_WORKER. Not deleting legacy worker." >&2
  exit 1
fi

if [[ "$RUN_SMOKE" == "1" ]]; then
  smoke_body_file="$(mktemp)"
  trap 'rm -f "$smoke_body_file"' EXIT
  smoke_title="Chau7 issue intake cutover smoke $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  smoke_payload="{\"title\":\"$smoke_title\",\"body\":\"Automated cutover smoke test for $ISSUES_DOMAIN.\"}"
  status="$(curl -sS -o "$smoke_body_file" -w '%{http_code}' \
    -X POST "https://$ISSUES_DOMAIN/issue" \
    -H 'Content-Type: application/json' \
    --data "$smoke_payload")"
  if [[ "$status" != "200" && "$status" != "201" ]]; then
    echo "error: smoke issue creation failed with HTTP $status." >&2
    cat "$smoke_body_file" >&2
    echo >&2
    echo "Not deleting legacy worker." >&2
    exit 1
  fi
  echo "Smoke issue creation succeeded: $(cat "$smoke_body_file")"
  rm -f "$smoke_body_file"
  trap - EXIT
else
  echo "Skipping POST smoke test because RUN_SMOKE=$RUN_SMOKE."
fi

echo
echo "5/5 Retiring legacy issue worker state..."
if [[ "$DELETE_LEGACY_WORKER" == "1" ]]; then
  "$WRANGLER" delete "$LEGACY_WORKER" --force
  echo "Deleted legacy worker $LEGACY_WORKER."
else
  printf 'y\n' | "$WRANGLER" secret delete GITHUB_ISSUE_PAT --name "$LEGACY_WORKER" || true
  printf 'y\n' | "$WRANGLER" secret delete GITHUB_ISSUE_REPO --name "$LEGACY_WORKER" || true
  echo "Kept legacy worker $LEGACY_WORKER, but attempted to remove stale issue secrets."
fi

echo
echo "Cutover complete. $ISSUES_DOMAIN is owned by $ISSUES_WORKER."
