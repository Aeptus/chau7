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
FIXTURE_HELPERS="$FIXTURE_ROOT/crates"

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
  unset BUILD_MODE CARGO_INCREMENTAL BUILD_LOG CARGO_BUILD_VERBOSE CHAU7_CTO_OPTIM_ACTIVE
  unset CARGO_TARGET_DIR OPTIM_TARGET_DIR
  unset CARGO_PROFILE_RELEASE_DEBUG CARGO_PROFILE_RELEASE_STRIP
  unset CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG
  unset CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP
  unset CARGO_PROFILE_RELEASE_INCREMENTAL CARGO_PROFILE_RELEASE_LTO
  unset CARGO_PROFILE_RELEASE_OPT_LEVEL CARGO_PROFILE_RELEASE_CODEGEN_UNITS
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$BUILD_MODE" == fast ]]
  [[ -z "${CHAU7_CTO_OPTIM_ACTIVE:-}" ]]
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

# Fast mode leaves an active caller's CTO recursion/output-bypass sentinel intact.
check_fast_preserves_cto_sentinel() (
  unset BUILD_MODE CARGO_INCREMENTAL BUILD_LOG CARGO_BUILD_VERBOSE
  unset CARGO_TARGET_DIR OPTIM_TARGET_DIR
  unset CARGO_PROFILE_RELEASE_DEBUG CARGO_PROFILE_RELEASE_STRIP
  unset CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG
  unset CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP
  unset CARGO_PROFILE_RELEASE_INCREMENTAL CARGO_PROFILE_RELEASE_LTO
  unset CARGO_PROFILE_RELEASE_OPT_LEVEL CARGO_PROFILE_RELEASE_CODEGEN_UNITS
  export CHAU7_CTO_OPTIM_ACTIVE=caller-sentinel
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$BUILD_MODE" == fast ]]
  [[ "$CHAU7_CTO_OPTIM_ACTIVE" == caller-sentinel ]]
)
check_fast_preserves_cto_sentinel

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
printf 'optimizer sentinel: %s\n' "${CHAU7_CTO_OPTIM_ACTIVE:-unset}"
printf 'probe output: %s\n' "$*"
FAKE
chmod 755 "$FAKE_BIN/cargo-probe"
run_diagnostic_probe() (
  cd "$APP_ROOT"
  local BUILD_MODE=diagnostic CARGO_BUILD_VERBOSE=1 CARGO_TARGET_DIR=''
  # This fixture intentionally isolates the caller's sentinel in its subshell.
  # shellcheck disable=SC2030
  local CHAU7_CTO_OPTIM_ACTIVE=''
  local BUILD_LOG="$TMP_ROOT/logs/diagnostic-cargo.log"
  local CARGO_INCREMENTAL CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS
  unset CARGO_INCREMENTAL CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS
  export BUILD_MODE CARGO_BUILD_VERBOSE BUILD_LOG CARGO_TARGET_DIR CHAU7_CTO_OPTIM_ACTIVE
  # shellcheck source=apps/chau7-next/scripts/build-mode.sh
  source "$APP_ROOT/scripts/build-mode.sh"
  [[ "$CARGO_TARGET_DIR" == "$APP_ROOT/target/diagnostic" ]]
  [[ "$CARGO_PROFILE_RELEASE_OPT_LEVEL" == 3 ]]
  [[ "$CARGO_PROFILE_RELEASE_LTO" == off ]]
  [[ "$CARGO_PROFILE_RELEASE_DEBUG" == 2 ]]
  [[ "$CARGO_PROFILE_RELEASE_STRIP" == none ]]
  [[ "$CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG" == 2 ]]
  [[ "$CHAU7_CTO_OPTIM_ACTIVE" == 1 ]]
  [[ -z "${CARGO_PROFILE_RELEASE_DEBUG_ASSERTIONS:-}" ]]
  [[ " ${CARGO_BUILD_ARGS[*]} " == *" -vv "* ]]
  run_cargo "$FAKE_BIN/cargo-probe" diagnostic-check
)
run_diagnostic_probe
assert_file_contains "$TMP_ROOT/logs/diagnostic-cargo.log" 'optimizer sentinel: 1'
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
  */crates)
    products=(chau7-optim chau7-md)
    ;;
  *) exit 3 ;;
esac
for product in "${products[@]}"; do
  printf 'fresh:%s|cwd=%s|targetdir=%s\nuuid=01234567-89AB-CDEF-0123-456789ABCDEF\n' "$product" "$PWD" "$cache_dir" > "$out_dir/$product"
  chmod 755 "$out_dir/$product"
done
printf 'fake cargo build cwd=%s target=%s targetdir=%s\n' "$PWD" "$target" "$cache_dir"
printf 'fake cargo args: %s\n' "$*"
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

cat > "$FAKE_BIN/dsymutil" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -ne 3 || "$1" != -o ]]; then
  if [[ "${1:-}" == --out-file ]]; then
    echo 'unsupported dsymutil option: --out-file (use -o output input)' >&2
  fi
  exit 2
fi
output="$2"
input="$3"
[[ ! -e "$FAKE_STATE/dsymutil-empty" ]] || exit 0
mkdir -p "$output/Contents/Resources/DWARF"
cp "$input" "$output/Contents/Resources/DWARF/$(basename "$input")"
FAKE

cat > "$FAKE_BIN/dwarfdump" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --uuid ]] || exit 2
input="$2"
uuid="$(sed -n 's/^uuid=//p' "$input" | head -n 1)"
[[ -n "$uuid" ]] || exit 3
if [[ -e "$FAKE_STATE/dwarfdump-mismatch" && "$input" == */Contents/Resources/DWARF/* ]]; then
  uuid='00000000-0000-0000-0000-000000000000'
fi
printf 'UUID: %s (arm64) %s\n' "$uuid" "$input"
FAKE

cat > "$FAKE_BIN/xcrun" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_STATE/xcrun.log"
[[ "$1" == --find ]] || exit 2
case "$2" in
  dsymutil) printf '%s\n' "$FAKE_BIN/dsymutil" ;;
  dwarfdump) printf '%s\n' "$FAKE_BIN/dwarfdump" ;;
  *) exit 2 ;;
esac
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
elif [[ -d "$target" && -f "$target/Contents/MacOS/Chau7" ]]; then
  printf '\nfake-codesigned\n' >> "$target/Contents/MacOS/Chau7"
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
  "$FAKE_BIN/dsymutil" \
  "$FAKE_BIN/dwarfdump" \
  "$FAKE_BIN/xcrun" \
  "$FAKE_BIN/clang" \
  "$FAKE_BIN/codesign"
assert_fake_tools_selected() (
  local tool
  local resolved
  for tool in git rustup rustc cargo go dsymutil dwarfdump xcrun clang codesign; do
    resolved="$(PATH="$FAKE_BIN:$PATH" /bin/bash -c 'command -v "$1"' _ "$tool")"
    [[ "$resolved" == "$FAKE_BIN/$tool" ]] \
      || fail "expected fake $tool first in PATH"
  done
)
dsymutil_error="$FAKE_STATE/unsupported-dsymutil.log"
if "$FAKE_BIN/dsymutil" --out-file "$FAKE_STATE/unsupported.dSYM" "$FAKE_STATE/input" >/dev/null 2>"$dsymutil_error"; then
  fail 'fake dsymutil accepted unsupported --out-file'
else
  dsymutil_status=$?
fi
[[ "$dsymutil_status" -eq 2 ]] || fail "unsupported dsymutil option exited $dsymutil_status instead of 2"
assert_file_contains "$dsymutil_error" 'unsupported dsymutil option: --out-file (use -o output input)'
assert_fake_tools_selected

mkdir -p \
  "$FIXTURE_APP/scripts" \
  "$FIXTURE_APP/resources/skills/chau7-next-build" \
  "$FIXTURE_APP/resources/licenses/ondine" \
  "$FIXTURE_APP/vendor/history/0.3.8" \
  "$FIXTURE_ROOT/apps/chau7-macos/Resources" \
  "$FIXTURE_ROOT/services/chau7-proxy" \
  "$FIXTURE_HELPERS" \
  "$FIXTURE_ROOT/services/chau7-remote"
sed "s|/usr/bin/xcrun|$FAKE_BIN/xcrun|" "$APP_ROOT/scripts/bundle-macos.sh" > "$FIXTURE_APP/scripts/bundle-macos.sh"
chmod 755 "$FIXTURE_APP/scripts/bundle-macos.sh"
cp "$APP_ROOT/scripts/build-mode.sh" "$FIXTURE_APP/scripts/build-mode.sh"
cp "$APP_ROOT/scripts/install-chau7-next-cli.sh" "$FIXTURE_APP/scripts/install-chau7-next-cli.sh"
printf 'version = "0.1.0"\n' > "$FIXTURE_APP/Cargo.toml"
printf 'fixture skill\n' > "$FIXTURE_APP/resources/skills/chau7-next-build/SKILL.md"
cp "$APP_ROOT/resources/licenses/ondine/"* "$FIXTURE_APP/resources/licenses/ondine/"
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
  local channel="${7:-next}"
  local output_dir="$TMP_ROOT/out-$label"
  local app_name='Chau7 Next'
  local metadata_stem='Chau7-Next'
  local build_number="fixture-$label"
  if [[ "$channel" == production ]]; then
    app_name='Chau7'
    metadata_stem='Chau7-Production'
    build_number=123
  fi
  local -a env_args=(
    "PATH=$FAKE_BIN:$PATH"
    "FAKE_STATE=$FAKE_STATE"
    "FAKE_BIN=$FAKE_BIN"
    TARGET=aarch64-apple-darwin
    "BUILD_NUMBER=$build_number"
    "OUT_DIR=$output_dir"
    "CHANNEL=$channel"
  )
  if [[ "$channel" == production ]]; then
    env_args+=(RELEASE_VERSION=0.6.0-rc.1)
  fi
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
  ) || return $?
  # Bundling must preserve both upstream license notices and their provenance.
  local notice
  for notice in LICENSE-ONDINE LICENSE-PELE UPSTREAM.md; do
    cmp "$APP_ROOT/resources/licenses/ondine/$notice" \
      "$output_dir/$app_name.app/Contents/Resources/licenses/ondine/$notice" \
      || fail "bundled Ondine notice differs: $notice"
  done
  printf '%s\n' "$output_dir/$app_name.app" "$output_dir/$metadata_stem-aarch64-apple-darwin-${mode/default/fast}.json"
}

validate_bundle() {
  local bundle="$1"
  local manifest="$2"
  local mode="$3"
  local helper_target_dir="$4"
  local app_target_dir="$5"
  local verbose="$6"
  local jobs="$7"
  local channel="${8:-next}"
  python3 - "$bundle" "$manifest" "$mode" "$helper_target_dir" "$app_target_dir" "$verbose" "$jobs" "$FAKE_STATE/codesign.log" "$channel" <<'PY'
import hashlib
import json
import pathlib
import shlex
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
manifest_path = pathlib.Path(sys.argv[2]).resolve()
mode, helper_target_dir, app_target_dir, verbose, jobs, codesign_log, channel = sys.argv[3:]
verified_paths = set()
for line in pathlib.Path(codesign_log).read_text().splitlines():
    arguments = shlex.split(line)
    if len(arguments) == 4 and arguments[:3] == ["--verify", "--strict", "--verbose=2"]:
        verified_paths.add(pathlib.Path(arguments[3]).resolve())
manifest = json.loads(manifest_path.read_text())
app_name = "Chau7" if channel == "production" else "Chau7 Next"
expected = {
    app_name: f"Contents/MacOS/{app_name}",
    "chau7-next-mcp-bridge": "Contents/MacOS/chau7-next-mcp-bridge",
    "chau7-next-cli": "Contents/MacOS/chau7-next-cli",
    "chau7-optim": "Contents/MacOS/chau7-optim",
    "chau7-md": "Contents/MacOS/chau7-md",
    "chau7-remote": "Contents/MacOS/chau7-remote",
    "chau7-proxy": "Contents/MacOS/chau7-proxy",
}
assert manifest["buildMode"] == mode
assert manifest["channel"] == channel
assert manifest["bundleIdentifier"] == ("com.chau7.app" if channel == "production" else "com.chau7.next")
assert manifest["bundlePath"] == f"{app_name}.app"
assert manifest["appExecutable"] == app_name
assert manifest["releaseVersion"] == ("0.6.0-rc.1" if channel == "production" else "0.1.0")
assert manifest["cargoPackageVersion"] == "0.1.0"
assert manifest["version"] == ("0.6.0" if channel == "production" else "0.1.0")
assert manifest["cargoFeatures"] == (["chau7_next_core/production"] if channel == "production" else [])
assert manifest["sourceDirty"] is False
assert manifest["sourceRevision"] == "0123456789abcdef0123456789abcdef01234567"
assert manifest["buildNumber"] == ("123" if channel == "production" else manifest["buildNumber"])
assert manifest["appSignatureVerified"] is True
import plistlib
with (bundle / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleIdentifier"] == manifest["bundleIdentifier"]
assert info["CFBundleExecutable"] == app_name
assert info["Chau7BuildChannel"] == channel
assert info["CFBundleShortVersionString"] == manifest["version"]
assert info["CFBundleVersion"] == manifest["buildNumber"]
installer = bundle / "Contents/Resources/install-chau7-next-cli.sh"
assert installer.exists() == (channel == "next")
if mode == "fast":
    assert manifest["rustDsym"] is None
else:
    dsym = manifest["rustDsym"]
    dsym_bundle = pathlib.Path(dsym["path"]).resolve()
    dwarf_file = dsym_bundle / f"Contents/Resources/DWARF/{app_name}"
    assert dsym_bundle.parent == bundle.parent
    assert dsym_bundle.name == f"{app_name}.app.dSYM"
    assert bundle not in dsym_bundle.parents
    assert dwarf_file.is_file() and dwarf_file.stat().st_size > 0
    assert int(dsym["dwarfSizeBytes"]) == dwarf_file.stat().st_size
    assert dsym["uuid"] == "01234567-89AB-CDEF-0123-456789ABCDEF"
    assert dsym["architecture"] == "arm64"
    assert len(dsym["dwarfSha256"]) == 64
    assert hashlib.sha256(dwarf_file.read_bytes()).hexdigest() == dsym["dwarfSha256"]
    assert pathlib.Path(dsym["dsymutilPath"]).name == "dsymutil"
    assert pathlib.Path(dsym["dwarfdumpPath"]).name == "dwarfdump"
assert manifest["target"] == "aarch64-apple-darwin"
assert manifest["minimumMacOS"] == "13.0"
verbosity_args = ["-vv"] if verbose == "1" else []
expected_command = [
    "cargo", "build", "--locked", "--release", *verbosity_args,
    "--target", "aarch64-apple-darwin", "--bin", "chau7-next",
    "--bin", "chau7-next-mcp-bridge", "--bin", "chau7-next-cli",
]
if channel == "production":
    expected_command.extend(["--features", "chau7_next_core/production"])
assert manifest["cargoCommands"]["app"] == expected_command
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
    if name == app_name:
        app_text = artifact.read_text()
        actual_app_target = app_text.split("targetdir=", 1)[1].splitlines()[0]
        assert pathlib.Path(actual_app_target).resolve() == pathlib.Path(app_target_dir).resolve(), app_text
    if name != app_name:
        assert (bundle / relative_path).resolve() in verified_paths, name
assert bundle in verified_paths
helper = (bundle / expected["chau7-optim"]).read_text()
actual_helper_target = helper.split("targetdir=", 1)[1].splitlines()[0]
assert pathlib.Path(actual_helper_target).resolve() == pathlib.Path(helper_target_dir).resolve(), helper
PY
}

expect_diagnostic_failure() {
  local label="$1"
  local expected_error="$2"
  if run_fake_bundle diagnostic "$label" '' '' 0 '' >/dev/null 2>&1; then
    fail "$label unexpectedly passed diagnostic symbol validation"
  fi
  assert_file_contains "$FAKE_STATE/$label-package.log" "$expected_error"
}

# Diagnostic validation must reject mismatched UUIDs and absent DWARF output.
: > "$FAKE_STATE/dwarfdump-mismatch"
expect_diagnostic_failure diagnostic-uuid-mismatch 'UUID/architecture does not match'
rm "$FAKE_STATE/dwarfdump-mismatch"
: > "$FAKE_STATE/dsymutil-empty"
expect_diagnostic_failure diagnostic-empty-dsym 'did not produce DWARF data'
rm "$FAKE_STATE/dsymutil-empty"

# Default fast packaging shares the per-worktree cache across Rust workspaces
# and hashes bytes after fake codesign changes every executable.
: > "$FAKE_STATE/go-args.log"
: > "$FAKE_STATE/xcrun.log"
fast_paths="$(run_fake_bundle default fast '' '' 0 '')"
[[ ! -s "$FAKE_STATE/xcrun.log" ]] || fail 'fast mode unexpectedly invoked Apple symbol tools'
fast_bundle="$(printf '%s\n' "$fast_paths" | sed -n '1p')"
fast_manifest="$(printf '%s\n' "$fast_paths" | sed -n '2p')"
validate_bundle "$fast_bundle" "$fast_manifest" fast "$FIXTURE_APP/target" "$FIXTURE_APP/target" 0 ''
assert_file_contains "$FAKE_STATE/go-args.log" '-s -w'
[[ -f "$FIXTURE_APP/target/aarch64-apple-darwin/release/chau7-next" ]] || fail 'default main cache was not used'
[[ -f "$FIXTURE_APP/target/aarch64-apple-darwin/release/chau7-optim" ]] || fail 'default shared helper cache was not used'

# Diagnostic mode gets its own default app and helper cache, with package
# evidence still checking the expected target and all seven signed artifacts.
: > "$FAKE_STATE/go-args.log"
diagnostic_default_paths="$(run_fake_bundle diagnostic diagnostic-default '' '' 0 '')"
[[ "$(wc -l < "$FAKE_STATE/xcrun.log" | tr -d ' ')" -eq 2 ]] \
  || fail 'diagnostic mode did not resolve exactly dsymutil and dwarfdump'
diagnostic_default_bundle="$(printf '%s\n' "$diagnostic_default_paths" | sed -n '1p')"
diagnostic_default_manifest="$(printf '%s\n' "$diagnostic_default_paths" | sed -n '2p')"
validate_bundle "$diagnostic_default_bundle" "$diagnostic_default_manifest" diagnostic \
  "$FIXTURE_APP/target/diagnostic" "$FIXTURE_APP/target/diagnostic" 0 ''
[[ -f "$FIXTURE_APP/target/diagnostic/aarch64-apple-darwin/release/chau7-next" ]] \
  || fail 'default diagnostic app cache was not used'
[[ -f "$FIXTURE_APP/target/diagnostic/aarch64-apple-darwin/release/chau7-optim" ]] \
  || fail 'default diagnostic helper cache was not used'

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
  "$FIXTURE_APP/$custom_helpers" "$FIXTURE_APP/$custom_main" 1 3
[[ -f "$FIXTURE_APP/$custom_main/aarch64-apple-darwin/release/chau7-next" ]] || fail 'explicit app CARGO_TARGET_DIR was ignored'
[[ -f "$FIXTURE_APP/$custom_helpers/aarch64-apple-darwin/release/chau7-optim" ]] || fail 'explicit helper OPTIM_TARGET_DIR was ignored'
custom_helpers_resolved="$(cd "$FIXTURE_APP/$custom_helpers" && pwd)"
assert_file_contains "$custom_bundle/Contents/MacOS/chau7-optim" "$custom_helpers_resolved"
assert_file_contains "$FIXTURE_APP/target/logs/diagnostic.log" 'fake cargo build'
if grep -Fq -- '-s -w' "$FAKE_STATE/go-args.log"; then
  fail 'diagnostic Go build unexpectedly stripped symbols'
fi

# The production candidate opts into the shared core feature, gets the
# production bundle identity, and records its prerelease label separately from
# the numeric macOS short version and current workspace package version.
production_paths="$(run_fake_bundle default production-rc '' '' 0 '' production)"
production_bundle="$(printf '%s\n' "$production_paths" | sed -n '1p')"
production_manifest="$(printf '%s\n' "$production_paths" | sed -n '2p')"
validate_bundle "$production_bundle" "$production_manifest" fast \
  "$FIXTURE_APP/target" "$FIXTURE_APP/target" 0 '' production
assert_file_contains "$FAKE_STATE/production-rc-package.log" 'chau7_next_core/production'
assert_file_contains "$production_bundle/Contents/Info.plist" 'com.chau7.app'

# Refuse installed paths and external existing bundles before invoking Cargo.
assert_unsafe_output_refused() {
  local output="$1"
  local message="$2"
  local marker="$FAKE_STATE/no-compile.log"
  if env -i "PATH=$FAKE_BIN:$PATH" "FAKE_STATE=$FAKE_STATE" "FAKE_BIN=$FAKE_BIN" \
    CHANNEL=production RELEASE_VERSION=0.6.0-rc.1 BUILD_NUMBER=123 \
    "OUT_DIR=$output" "$FIXTURE_APP/scripts/bundle-macos.sh" > "$marker" 2>&1; then
    fail 'unsafe output unexpectedly passed'
  fi
  assert_file_contains "$marker" "$message"
  if grep -Fq 'fake cargo build' "$marker"; then fail 'unsafe output reached Cargo'; fi
}
assert_unsafe_output_refused "$TMP_ROOT/Applications" 'must not be inside Applications'
mkdir -p "$TMP_ROOT/existing/Chau7.app"
printf 'preserve-me' > "$TMP_ROOT/existing/Chau7.app/sentinel"
assert_unsafe_output_refused "$TMP_ROOT/existing" 'refuses to replace an existing app'
assert_file_contains "$TMP_ROOT/existing/Chau7.app/sentinel" 'preserve-me'
mkdir -p "$TMP_ROOT/symlink-output"
ln -s "$TMP_ROOT/existing/Chau7.app" "$TMP_ROOT/symlink-output/Chau7.app"
assert_unsafe_output_refused "$TMP_ROOT/symlink-output" 'refuses an app bundle symlink'
ln -s "$TMP_ROOT/Applications" "$TMP_ROOT/indirect-output"
assert_unsafe_output_refused "$TMP_ROOT/indirect-output" 'must not be inside Applications'

printf 'BUILD_MODE source tests passed\n'
