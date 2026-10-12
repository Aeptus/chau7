#!/usr/bin/env bash
# Source-only tests for BUILD_MODE and the packaging evidence path.
# All compiler, Go, Git, and codesign commands are fakes. This test is not run
# by the build script and must be executed only after the source freeze.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chau7-next-build-mode.XXXXXX")"
FAKE_BIN="$TMP_ROOT/fake-bin"
FAKE_STATE="$TMP_ROOT/fake-state"
FIXTURE_ROOT="$TMP_ROOT/repo"
FIXTURE_APP="$FIXTURE_ROOT/apps/chau7-next"
FIXTURE_HELPERS="$FIXTURE_ROOT/apps/chau7-macos/rust"

mkdir -p "$FAKE_BIN" "$FAKE_STATE"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

# Fast mode is the default, retains a local incremental profile, and preserves
# the CI-wide CARGO_INCREMENTAL=0 override when one is already set.
(
  unset BUILD_MODE CARGO_INCREMENTAL BUILD_LOG CARGO_BUILD_VERBOSE
  unset CARGO_TARGET_DIR OPTIM_TARGET_DIR
  unset CARGO_PROFILE_RELEASE_DEBUG CARGO_PROFILE_RELEASE_STRIP
  unset CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG
  unset CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP
  unset CARGO_PROFILE_RELEASE_INCREMENTAL CARGO_PROFILE_RELEASE_LTO
  unset CARGO_PROFILE_RELEASE_OPT_LEVEL CARGO_PROFILE_RELEASE_CODEGEN_UNITS
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$BUILD_MODE" == fast ]]
  [[ -z "${CARGO_TARGET_DIR:-}" ]]
  [[ "$CARGO_PROFILE_RELEASE_OPT_LEVEL" == 3 ]]
  [[ "$CARGO_PROFILE_RELEASE_CODEGEN_UNITS" == 64 ]]
  [[ "$CARGO_PROFILE_RELEASE_LTO" == off ]]
  [[ "$CARGO_PROFILE_RELEASE_INCREMENTAL" == true ]]
  [[ "$CARGO_PROFILE_RELEASE_DEBUG" == 0 ]]
  [[ "$CARGO_PROFILE_RELEASE_STRIP" == symbols ]]
  [[ "$CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG" == 0 ]]
  [[ "$CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP" == none ]]
  [[ " ${CARGO_BUILD_ARGS[*]} " == *" --locked "* ]]
  [[ " ${CARGO_BUILD_ARGS[*]} " == *" --release "* ]]
)
check_ci_incremental_override() {
  local BUILD_MODE BUILD_LOG CARGO_BUILD_VERBOSE CARGO_INCREMENTAL=0
  local CARGO_PROFILE_RELEASE_DEBUG CARGO_PROFILE_RELEASE_STRIP
  local CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP
  local CARGO_PROFILE_RELEASE_INCREMENTAL CARGO_PROFILE_RELEASE_LTO
  local CARGO_PROFILE_RELEASE_OPT_LEVEL CARGO_PROFILE_RELEASE_CODEGEN_UNITS
  local -a CARGO_BUILD_ARGS
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$BUILD_MODE" == fast ]]
  [[ "$CARGO_INCREMENTAL" == 0 ]]
}
check_ci_incremental_override

# Invalid mode fails during setup, before any compiler command is invoked.
set +e
BUILD_MODE=invalid bash -c 'source "$1"' _ "$APP_ROOT/scripts/build-mode.sh" >/dev/null 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -eq 2 ]] || fail "invalid BUILD_MODE returned $invalid_status, expected 2"

# Diagnostic mode retains the optimized profile and requests full Rust symbols
# without changing debug assertions. Verbose Cargo output is captured on demand.
cat > "$FAKE_BIN/cargo-probe" <<'FAKE'
#!/usr/bin/env bash
printf 'probe output: %s\n' "$*"
FAKE
chmod 755 "$FAKE_BIN/cargo-probe"
run_diagnostic_probe() (
  cd "$APP_ROOT"
  local BUILD_MODE=diagnostic CARGO_BUILD_VERBOSE=1 CARGO_TARGET_DIR=''
  local BUILD_LOG="$TMP_ROOT/logs/diagnostic-cargo.log"
  local CARGO_INCREMENTAL CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS
  unset CARGO_INCREMENTAL CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS
  export BUILD_MODE CARGO_BUILD_VERBOSE BUILD_LOG CARGO_TARGET_DIR
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$CARGO_TARGET_DIR" == "$APP_ROOT/target/diagnostic" ]]
  [[ "$CARGO_PROFILE_RELEASE_OPT_LEVEL" == 3 ]]
  [[ "$CARGO_PROFILE_RELEASE_LTO" == off ]]
  [[ "$CARGO_PROFILE_RELEASE_DEBUG" == 2 ]]
  [[ "$CARGO_PROFILE_RELEASE_STRIP" == none ]]
  [[ "$CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG" == 2 ]]
  [[ -z "${CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS:-}" ]]
  [[ " ${CARGO_BUILD_ARGS[*]} " == *" -vv "* ]]
  run_cargo "$FAKE_BIN/cargo-probe" diagnostic-check
)
run_diagnostic_probe
assert_file_contains "$TMP_ROOT/logs/diagnostic-cargo.log" 'probe output: diagnostic-check'

# An explicit diagnostic CARGO_TARGET_DIR wins over the isolated default.
run_diagnostic_explicit_target_probe() (
  cd "$APP_ROOT"
  local BUILD_MODE=diagnostic CARGO_BUILD_VERBOSE=0
  local CARGO_TARGET_DIR="$TMP_ROOT/explicit-diagnostic-target"
  local BUILD_LOG="$TMP_ROOT/logs/diagnostic-explicit-cargo.log"
  export BUILD_MODE CARGO_BUILD_VERBOSE CARGO_TARGET_DIR BUILD_LOG
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$CARGO_TARGET_DIR" == "$TMP_ROOT/explicit-diagnostic-target" ]]
  run_cargo "$FAKE_BIN/cargo-probe" diagnostic-explicit-check
)
run_diagnostic_explicit_target_probe
assert_file_contains "$TMP_ROOT/logs/diagnostic-explicit-cargo.log" 'probe output: diagnostic-explicit-check'

# Fake every external build/signing tool so the package flow checks cache
# precedence, post-sign hashes, and sidecar placement without compiling code.
cat > "$FAKE_BIN/git" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -C ]] || exit 2
shift 2
case "${1:-}" in
  rev-parse) printf '%s\n' '0123456789abcdef0123456789abcdef01234567' ;;
  status) ;;
  *) exit 2 ;;
esac
FAKE

cat > "$FAKE_BIN/rustup" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat > "$FAKE_BIN/rustc" <<'FAKE'
#!/usr/bin/env bash
printf 'rustc fake "1.99.0"\tline\nnext\n'
FAKE

cat > "$FAKE_BIN/cargo" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  printf 'cargo fake 1.99.0\n'
  exit 0
fi
[[ "${1:-}" == build ]] || exit 2
target='unknown-target'
args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[index]}" == --target ]]; then
    target="${args[index + 1]}"
    break
  fi
done
cache_dir="${CARGO_TARGET_DIR:-$PWD/target}"
out_dir="$cache_dir/$target/release"
mkdir -p "$out_dir"
case "$PWD" in
  */apps/chau7-next)
    products=(chau7-next chau7-next-mcp-bridge chau7-next-cli)
    ;;
  */apps/chau7-macos/rust)
    products=(chau7-optim chau7-md)
    ;;
  *) exit 3 ;;
esac
for product in "${products[@]}"; do
  printf 'fresh:%s|cwd=%s|targetdir=%s\n' "$product" "$PWD" "$cache_dir" > "$out_dir/$product"
  chmod 755 "$out_dir/$product"
done
printf 'fake cargo build cwd=%s target=%s targetdir=%s\n' "$PWD" "$target" "$cache_dir"
FAKE

cat > "$FAKE_BIN/go" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == version ]]; then
  printf 'go version fake 1.27.2 darwin/arm64\n'
  exit 0
fi
printf '%s\n' "$*" >> "$FAKE_STATE/go-args.log"
output=''
while (($#)); do
  if [[ "$1" == -o ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
[[ -n "$output" ]] || exit 2
mkdir -p "$(dirname "$output")"
printf 'fresh-go:%s\n' "$output" > "$output"
chmod 755 "$output"
FAKE

cat > "$FAKE_BIN/clang" <<'FAKE'
#!/usr/bin/env bash
printf 'Apple clang fake 17.0.0\n'
FAKE

cat > "$FAKE_BIN/codesign" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_STATE/codesign.log"
printf '\n' >> "$FAKE_STATE/codesign.log"
[[ " $* " == *' --verify '* ]] && exit 0
target=''
for argument in "$@"; do target="$argument"; done
if [[ -f "$target" ]]; then
  printf '\nfake-codesigned\n' >> "$target"
elif [[ -d "$target" && -f "$target/Contents/MacOS/Chau7 Next" ]]; then
  printf '\nfake-codesigned\n' >> "$target/Contents/MacOS/Chau7 Next"
fi
FAKE

# All package tool calls must resolve to these fakes. A missing executable
# bit would otherwise allow PATH lookup to reach a real compiler or signer.
chmod 755 \
  "$FAKE_BIN/git" \
  "$FAKE_BIN/rustup" \
  "$FAKE_BIN/rustc" \
  "$FAKE_BIN/cargo" \
  "$FAKE_BIN/go" \
  "$FAKE_BIN/clang" \
  "$FAKE_BIN/codesign"
assert_fake_tools_selected() (
  local tool
  local resolved
  for tool in git rustup rustc cargo go clang codesign; do
    resolved="$(PATH="$FAKE_BIN:$PATH" /bin/bash -c 'command -v "$1"' _ "$tool")"
    [[ "$resolved" == "$FAKE_BIN/$tool" ]] \
      || fail "expected fake $tool first in PATH"
  done
)
assert_fake_tools_selected

mkdir -p \
  "$FIXTURE_APP/scripts" \
  "$FIXTURE_APP/resources/skills/chau7-next-build" \
  "$FIXTURE_APP/vendor/history/0.3.8" \
  "$FIXTURE_ROOT/apps/chau7-macos/Resources" \
  "$FIXTURE_ROOT/apps/chau7-macos/chau7-proxy" \
  "$FIXTURE_HELPERS" \
  "$FIXTURE_ROOT/services/chau7-remote"
cp "$APP_ROOT/scripts/bundle-macos.sh" "$FIXTURE_APP/scripts/bundle-macos.sh"
cp "$APP_ROOT/scripts/build-mode.sh" "$FIXTURE_APP/scripts/build-mode.sh"
printf 'version = "0.1.0"\n' > "$FIXTURE_APP/Cargo.toml"
printf 'fixture skill\n' > "$FIXTURE_APP/resources/skills/chau7-next-build/SKILL.md"
printf 'icon\n' > "$FIXTURE_ROOT/apps/chau7-macos/Resources/AppDockIcon.icns"
printf 'history\n' > "$FIXTURE_APP/vendor/history/0.3.8/README.md"
for audit in README.md gpui-provenance.json gpui-modifications.json gpui-rebase-0.3.8-to-0.3.9.json; do
  printf 'audit\n' > "$FIXTURE_APP/vendor/$audit"
done
for package in gpui-pre gpui-pre-macos gpui-pre-apple; do
  mkdir -p "$FIXTURE_APP/vendor/$package"
  printf 'Apache License\n' > "$FIXTURE_APP/vendor/$package/LICENSE-APACHE"
done

run_fake_bundle() {
  local mode="$1"
  local label="$2"
  local target_cache="$3"
  local helper_cache="$4"
  local verbose="$5"
  local jobs="$6"
  local output_dir="$TMP_ROOT/out-$label"
  local -a env_args=(
    "PATH=$FAKE_BIN:$PATH"
    "FAKE_STATE=$FAKE_STATE"
    TARGET=aarch64-apple-darwin
    "BUILD_NUMBER=fixture-$label"
    "OUT_DIR=$output_dir"
  )
  if [[ "$mode" != default ]]; then env_args+=("BUILD_MODE=$mode"); fi
  if [[ -n "$target_cache" ]]; then env_args+=("CARGO_TARGET_DIR=$target_cache"); fi
  if [[ -n "$helper_cache" ]]; then env_args+=("OPTIM_TARGET_DIR=$helper_cache"); fi
  if [[ "$verbose" == 1 ]]; then
    env_args+=(CARGO_BUILD_VERBOSE=1 "BUILD_LOG=target/logs/$label.log")
  fi
  if [[ -n "$jobs" ]]; then env_args+=("CARGO_BUILD_JOBS=$jobs"); fi
  (
    cd "$FIXTURE_ROOT"
    if ! env -i "${env_args[@]}" "$FIXTURE_APP/scripts/bundle-macos.sh" \
      > "$FAKE_STATE/$label-package.log" 2>&1; then
      cat "$FAKE_STATE/$label-package.log" >&2
      return 1
    fi
  )
  printf '%s\n' "$output_dir/Chau7 Next.app" "$output_dir/Chau7-Next-aarch64-apple-darwin-${mode/default/fast}.json"
}

validate_bundle() {
  local bundle="$1"
  local manifest="$2"
  local mode="$3"
  local helper_target_dir="$4"
  local verbose="$5"
  local jobs="$6"
  python3 - "$bundle" "$manifest" "$mode" "$helper_target_dir" "$verbose" "$jobs" "$FAKE_STATE/codesign.log" <<'PY'
import hashlib
import json
import pathlib
import shlex
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
manifest_path = pathlib.Path(sys.argv[2]).resolve()
mode, helper_target_dir, verbose, jobs, codesign_log = sys.argv[3:]
verified_paths = set()
for line in pathlib.Path(codesign_log).read_text().splitlines():
    arguments = shlex.split(line)
    if len(arguments) == 4 and arguments[:3] == ["--verify", "--strict", "--verbose=2"]:
        verified_paths.add(pathlib.Path(arguments[3]).resolve())
manifest = json.loads(manifest_path.read_text())
expected = {
    "Chau7 Next": "Contents/MacOS/Chau7 Next",
    "chau7-next-mcp-bridge": "Contents/MacOS/chau7-next-mcp-bridge",
    "chau7-next-cli": "Contents/MacOS/chau7-next-cli",
    "chau7-optim": "Contents/MacOS/chau7-optim",
    "chau7-md": "Contents/MacOS/chau7-md",
    "chau7-remote": "Contents/MacOS/chau7-remote",
    "chau7-proxy": "Contents/MacOS/chau7-proxy",
}
assert manifest["buildMode"] == mode
assert manifest["sourceDirty"] is False
assert manifest["sourceRevision"] == "0123456789abcdef0123456789abcdef01234567"
assert manifest["appSignatureVerified"] is True
assert manifest["target"] == "aarch64-apple-darwin"
assert manifest["minimumMacOS"] == "13.0"
verbosity_args = ["-vv"] if verbose == "1" else []
assert manifest["cargoCommands"]["app"] == [
    "cargo", "build", "--locked", "--release", *verbosity_args,
    "--target", "aarch64-apple-darwin", "--bin", "chau7-next",
    "--bin", "chau7-next-mcp-bridge", "--bin", "chau7-next-cli",
]
assert manifest["cargoCommands"]["sharedHelpers"] == [
    "cargo", "build", "--locked", "--release", *verbosity_args,
    "--target", "aarch64-apple-darwin", "-p", "chau7_optim", "-p", "chau7_md",
]
assert set(manifest["artifacts"]) == set(expected)
assert manifest["profile"]["optLevel"] == 3
assert manifest["profile"]["codegenUnits"] == 64
assert manifest["profile"]["lto"] == "off"
assert manifest["profile"]["incremental"] is True
assert manifest["profile"]["cargoVerbose"] == str(verbose)
assert manifest["cargoBuildJobsEnv"] == (jobs or "unset")
if mode == "fast":
    assert manifest["profile"]["debugLevel"] == 0
    assert manifest["profile"]["strip"] == "symbols"
    assert manifest["profile"]["buildOverrideDebug"] == "0"
    assert manifest["goBuild"]["ldflags"] == ["-s", "-w"]
else:
    assert manifest["profile"]["debugLevel"] == 2
    assert manifest["profile"]["strip"] == "none"
    assert manifest["profile"]["buildOverrideDebug"] == "2"
    assert manifest["goBuild"]["ldflags"] == []
assert manifest["compilers"]["rustc"] == 'rustc fake "1.99.0"\tline\nnext'
assert manifest["compilers"]["cargo"] == "cargo fake 1.99.0"
assert manifest["compilers"]["go"] == "go version fake 1.27.2 darwin/arm64"
assert manifest["compilers"]["clang"] == "Apple clang fake 17.0.0"
assert manifest_path.parent == bundle.parent
assert bundle not in manifest_path.parents
assert not list(bundle.rglob(manifest_path.name))
for name, relative_path in expected.items():
    artifact = bundle / relative_path
    entry = manifest["artifacts"][name]
    assert entry["path"] == relative_path
    actual_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
    assert entry["sha256"] == actual_hash, name
    assert b"fake-codesigned" in artifact.read_bytes(), f"{name} was not signed before hashing"
    if name != "Chau7 Next":
        assert (bundle / relative_path).resolve() in verified_paths, name
assert bundle in verified_paths
helper = (bundle / expected["chau7-optim"]).read_text()
actual_helper_target = helper.split("targetdir=", 1)[1].splitlines()[0]
assert pathlib.Path(actual_helper_target).resolve() == pathlib.Path(helper_target_dir).resolve(), helper
PY
}

# Default fast packaging shares the per-worktree cache across Rust workspaces
# and hashes bytes after fake codesign changes every executable.
: > "$FAKE_STATE/go-args.log"
fast_paths="$(run_fake_bundle default fast '' '' 0 '')"
fast_bundle="$(printf '%s\n' "$fast_paths" | sed -n '1p')"
fast_manifest="$(printf '%s\n' "$fast_paths" | sed -n '2p')"
validate_bundle "$fast_bundle" "$fast_manifest" fast "$FIXTURE_APP/target" 0 ''
assert_file_contains "$FAKE_STATE/go-args.log" '-s -w'
[[ -f "$FIXTURE_APP/target/aarch64-apple-darwin/release/chau7-next" ]] || fail 'default main cache was not used'
[[ -f "$FIXTURE_APP/target/aarch64-apple-darwin/release/chau7-optim" ]] || fail 'default shared helper cache was not used'
assert_file_contains "$FIXTURE_APP/target/aarch64-apple-darwin/release/chau7-next" "targetdir=$FIXTURE_APP/target"

# Diagnostic mode gets its own default app and helper cache, with package
# evidence still checking the expected target and all seven signed artifacts.
: > "$FAKE_STATE/go-args.log"
diagnostic_default_paths="$(run_fake_bundle diagnostic diagnostic-default '' '' 0 '')"
diagnostic_default_bundle="$(printf '%s\n' "$diagnostic_default_paths" | sed -n '1p')"
diagnostic_default_manifest="$(printf '%s\n' "$diagnostic_default_paths" | sed -n '2p')"
validate_bundle "$diagnostic_default_bundle" "$diagnostic_default_manifest" diagnostic \
  "$FIXTURE_APP/target/diagnostic" 0 ''
[[ -f "$FIXTURE_APP/target/diagnostic/aarch64-apple-darwin/release/chau7-next" ]] \
  || fail 'default diagnostic app cache was not used'
[[ -f "$FIXTURE_APP/target/diagnostic/aarch64-apple-darwin/release/chau7-optim" ]] \
  || fail 'default diagnostic helper cache was not used'
assert_file_contains "$FIXTURE_APP/target/diagnostic/aarch64-apple-darwin/release/chau7-next" \
  "targetdir=$FIXTURE_APP/target/diagnostic"

# Explicit relative cache paths resolve from the app workspace. OPTIM_TARGET_DIR
# wins for shared helpers even with CARGO_TARGET_DIR set; a stale default helper
# is present to ensure the bundle uses the output from the selected cache.
custom_main="cache/main-target"
custom_helpers="cache/helper-target"
stale_helpers="$FIXTURE_APP/target/aarch64-apple-darwin/release"
mkdir -p "$stale_helpers"
printf 'stale-helper\n' > "$stale_helpers/chau7-optim"
chmod 755 "$stale_helpers/chau7-optim"
: > "$FAKE_STATE/go-args.log"
custom_paths="$(run_fake_bundle diagnostic diagnostic "$custom_main" "$custom_helpers" 1 3)"
custom_bundle="$(printf '%s\n' "$custom_paths" | sed -n '1p')"
custom_manifest="$(printf '%s\n' "$custom_paths" | sed -n '2p')"
validate_bundle "$custom_bundle" "$custom_manifest" diagnostic \
  "$FIXTURE_APP/$custom_helpers" 1 3
[[ -f "$FIXTURE_APP/$custom_main/aarch64-apple-darwin/release/chau7-next" ]] || fail 'explicit app CARGO_TARGET_DIR was ignored'
[[ -f "$FIXTURE_APP/$custom_helpers/aarch64-apple-darwin/release/chau7-optim" ]] || fail 'explicit helper OPTIM_TARGET_DIR was ignored'
custom_helpers_resolved="$(cd "$FIXTURE_APP/$custom_helpers" && pwd)"
assert_file_contains "$custom_bundle/Contents/MacOS/chau7-optim" "$custom_helpers_resolved"
assert_file_contains "$FIXTURE_APP/target/logs/diagnostic.log" 'fake cargo build'
if grep -Fq -- '-s -w' "$FAKE_STATE/go-args.log"; then
  fail 'diagnostic Go build unexpectedly stripped symbols'
fi

printf 'BUILD_MODE source tests passed\n'
