#!/usr/bin/env bash
# Source-only regression test for Cargo target-aware CLI artifact discovery.
# All Cargo work is simulated; do not run before the source freeze.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chau7-cli-installer.XXXXXX")"
FAKE_BIN="$TMP_ROOT/fake-bin"
FAKE_STATE="$TMP_ROOT/fake-state"
FIXTURE_ROOT="$TMP_ROOT/repo"
FIXTURE_APP="$FIXTURE_ROOT/apps/chau7-next"
TARGET_TRIPLE="aarch64-apple-darwin"

mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$FIXTURE_APP/scripts" "$FIXTURE_APP/resources"
trap 'rm -rf "$TMP_ROOT"' EXIT
cp "$APP_ROOT/scripts/install-chau7-next-cli.sh" "$FIXTURE_APP/scripts/install-chau7-next-cli.sh"
cp "$APP_ROOT/scripts/build-mode.sh" "$FIXTURE_APP/scripts/build-mode.sh"
cp -R "$APP_ROOT/resources/skills" "$FIXTURE_APP/resources/skills"
if ! /bin/bash -n "$FIXTURE_APP/scripts/install-chau7-next-cli.sh"; then
  echo 'FAIL: copied CLI installer is invalid for the system Bash' >&2
  exit 1
fi

cat > "$FAKE_BIN/cargo" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == build ]] || exit 2
printf '%s\n' "$@" > "$FAKE_STATE/cargo-args.log"
printf 'build\n' >> "$FAKE_STATE/cargo-calls.log"
[[ " $* " == *' --message-format=json-render-diagnostics '* ]] || exit 3
[[ " $* " == *' --bin chau7-next-cli '* ]] || exit 4
target_dir="${CARGO_TARGET_DIR:?}"
if [[ -n "${CARGO_BUILD_TARGET:-}" ]]; then
  output_dir="$target_dir/$CARGO_BUILD_TARGET/release"
else
  output_dir="$target_dir/release"
fi
mkdir -p "$output_dir"
artifact="$output_dir/chau7-next-cli"
printf 'fresh-artifact target=%s\n' "${CARGO_BUILD_TARGET:-host}" > "$artifact"
chmod 755 "$artifact"
python3 - "$artifact" <<'PY'
import json
import sys
print(json.dumps({
    "reason": "compiler-artifact",
    "target": {"name": "chau7-next-cli", "kind": ["bin"]},
    "executable": sys.argv[1],
}))
PY
FAKE
chmod 755 "$FAKE_BIN/cargo"
if [[ "$(PATH="$FAKE_BIN:$PATH" command -v cargo)" != "$FAKE_BIN/cargo" ]]; then
  echo 'FAIL: cargo does not resolve to the fixture fake' >&2
  exit 1
fi

run_installer() {
  local label="$1"
  local skip_build="$2"
  local product_override="$3"
  (
    cd "$FIXTURE_ROOT"
    export PATH="$FAKE_BIN:$PATH" FAKE_STATE
    export CARGO_TARGET_DIR=target CARGO_BUILD_TARGET="$TARGET_TRIPLE"
    export CHAU7_NEXT_CLI_INSTALL_DIR="$TMP_ROOT/install-$label"
    if [[ "$skip_build" == 1 ]]; then
      export CHAU7_NEXT_CLI_SKIP_BUILD=1
    else
      unset CHAU7_NEXT_CLI_SKIP_BUILD
    fi
    if [[ -n "$product_override" ]]; then
      export CHAU7_NEXT_CLI_PRODUCT_BIN="$product_override"
    else
      unset CHAU7_NEXT_CLI_PRODUCT_BIN
    fi
    if ! "$FIXTURE_APP/scripts/install-chau7-next-cli.sh" > "$FAKE_STATE/$label.log" 2>&1; then
      cat "$FAKE_STATE/$label.log" >&2
      return 1
    fi
    if [[ ! -x "$TMP_ROOT/install-$label/chau7-next-cli" ]]; then
      cat "$FAKE_STATE/$label.log" >&2
      echo 'FAIL: installer returned without installing the CLI executable' >&2
      return 1
    fi
  )
}

# A stale host-path executable exists. The target-specific Cargo artifact event
# must determine which newly built file gets installed.
STALE_PRODUCT="$FIXTURE_APP/target/release/chau7-next-cli"
FRESH_PRODUCT="$FIXTURE_APP/target/$TARGET_TRIPLE/release/chau7-next-cli"
mkdir -p "$(dirname "$STALE_PRODUCT")"
printf 'stale-host-artifact\n' > "$STALE_PRODUCT"
chmod 755 "$STALE_PRODUCT"
run_installer target-aware 0 ''
INSTALLED="$TMP_ROOT/install-target-aware/chau7-next-cli"
grep -Fq 'fresh-artifact target=aarch64-apple-darwin' "$INSTALLED" \
  || { echo 'FAIL: installer copied the stale host artifact' >&2; exit 1; }
FRESH_PRODUCT="$(cd "$(dirname "$FRESH_PRODUCT")" && pwd -P)/$(basename "$FRESH_PRODUCT")"
grep -Fq "$FRESH_PRODUCT" "$FAKE_STATE/target-aware.log" \
  || { echo 'FAIL: installer did not report the Cargo artifact path' >&2; exit 1; }
grep -Fq -- '--message-format=json-render-diagnostics' "$FAKE_STATE/cargo-args.log" \
  || { echo 'FAIL: installer did not request Cargo artifact messages' >&2; exit 1; }
for expected_arg in --locked --release -p chau7_next_core --bin chau7-next-cli; do
  grep -Fxq -- "$expected_arg" "$FAKE_STATE/cargo-args.log" \
    || { echo "FAIL: installer Cargo command omitted $expected_arg" >&2; exit 1; }
done
if grep -Fxq -- '--target' "$FAKE_STATE/cargo-args.log"; then
  echo 'FAIL: installer overrode Cargo target configuration' >&2
  exit 1
fi
grep -Fq 'stale-host-artifact' "$STALE_PRODUCT" \
  || { echo 'FAIL: stale host artifact was modified' >&2; exit 1; }

# Keep the explicit product override when a build is requested.
OVERRIDE_PRODUCT="$TMP_ROOT/caller-selected-cli"
printf 'caller-selected-artifact\n' > "$OVERRIDE_PRODUCT"
chmod 755 "$OVERRIDE_PRODUCT"
run_installer override 0 "$OVERRIDE_PRODUCT"
grep -Fq 'caller-selected-artifact' "$TMP_ROOT/install-override/chau7-next-cli" \
  || { echo 'FAIL: CHAU7_NEXT_CLI_PRODUCT_BIN was ignored' >&2; exit 1; }

# Skip-build still uses the caller-selected product and does not invoke Cargo.
SKIP_PRODUCT="$TMP_ROOT/skip-build-cli"
printf 'skip-build-artifact\n' > "$SKIP_PRODUCT"
chmod 755 "$SKIP_PRODUCT"
run_installer skip-build 1 "$SKIP_PRODUCT"
grep -Fq 'skip-build-artifact' "$TMP_ROOT/install-skip-build/chau7-next-cli" \
  || { echo 'FAIL: skip-build product override was ignored' >&2; exit 1; }
[[ "$(wc -l < "$FAKE_STATE/cargo-calls.log" | tr -d ' ')" == 2 ]] \
  || { echo 'FAIL: Cargo ran during the skip-build install' >&2; exit 1; }

printf 'CLI installer source tests passed\n'
