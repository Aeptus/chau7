#!/bin/bash
# French messages are literal; bash -c variables expand in the child shell.
# shellcheck disable=SC1112,SC2016
set -Eeuo pipefail

if [[ "$#" -gt 1 ]]; then
  printf 'Usage: %s [path to chau7-upgrade-status.sh]\n' "$0" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
STATUS_HELPER="${1:-$SCRIPT_DIR/chau7-upgrade-status.sh}"
[[ -r "$STATUS_HELPER" ]] || { printf 'Status helper not found: %s\n' "$STATUS_HELPER" >&2; exit 2; }
STATUS_DIR="$(cd "$(dirname "$STATUS_HELPER")" && pwd -P)"

STATUS_TEST_DIR="$(mktemp -d /private/tmp/chau7-upgrade-status.XXXXXX)"
trap 'rm -rf "$STATUS_TEST_DIR"' EXIT

run_exit_case() {
  local name="$1" stage="$2" initial_result="$3" code="$4"
  local expected_result="$5" required_text="$6" forbidden_text="$7"
  local case_dir="$STATUS_TEST_DIR/$name" status_file output_file backup log actual
  backup="$case_dir/backup"
  log="$case_dir/upgrade.log"
  status_file="$case_dir/status.json"
  output_file="$case_dir/output.txt"
  mkdir -p "$case_dir"

  if env STAGE="$stage" RESULT="$initial_result" STATUS_FILE="$status_file" BACKUP="$backup" LOG="$log" \
    bash -c 'source "$1"; on_exit "$2"' bash "$STATUS_HELPER" "$code" </dev/null >"$output_file" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  [[ "$actual" -eq "$code" ]] || { printf '%s: exit code %s, expected %s\n' "$name" "$actual" "$code" >&2; return 1; }

  python3 - "$status_file" "$output_file" "$stage" "$expected_result" "$code" "$backup" "$log" "$required_text" "$forbidden_text" <<'PY'
import json, pathlib, sys
status_path, output_path, stage, result, code, backup, log, required, forbidden = sys.argv[1:]
status = json.loads(pathlib.Path(status_path).read_text())
output = pathlib.Path(output_path).read_text()
assert (status['stage'], status['result'], status['exitCode']) == (stage, result, int(code)), status
assert status['backupPath'] == backup and status['logPath'] == log, status
assert required in output, output
assert not forbidden or forbidden not in output, output
PY
}

run_signal_case() {
  local name="$1" signal="$2" result="$3" code="$4" required_text="$5"
  local case_dir="$STATUS_TEST_DIR/$name" status_file output_file backup log actual
  backup="$case_dir/backup"
  log="$case_dir/upgrade.log"
  status_file="$case_dir/status.json"
  output_file="$case_dir/output.txt"
  mkdir -p "$case_dir"

  if env STAGE=applying_import RESULT=running STATUS_FILE="$status_file" BACKUP="$backup" LOG="$log" \
    bash -c 'source "$1"; install_status_traps; on_signal "$2" "$3"' \
      bash "$STATUS_HELPER" "$signal" "$code" </dev/null >"$output_file" 2>&1; then
    actual=0
  else
    actual=$?
  fi
  [[ "$actual" -eq "$code" ]] || { printf '%s: exit code %s, expected %s\n' "$name" "$actual" "$code" >&2; return 1; }

  python3 - "$status_file" "$output_file" "$result" "$code" "$backup" "$log" "$required_text" <<'PY'
import json, pathlib, sys
status_path, output_path, result, code, backup, log, required = sys.argv[1:]
status = json.loads(pathlib.Path(status_path).read_text())
output = pathlib.Path(output_path).read_text()
assert (status['stage'], status['result'], status['exitCode']) == ('applying_import', result, int(code)), status
assert status['backupPath'] == backup and status['logPath'] == log, status
assert required in output, output
assert 'L’import a commencé, mais son résultat n’est pas confirmé' in output, output
PY
}

run_exit_case success completed running 0 success 'PAS été ouvert automatiquement' ''
run_exit_case pre_import_failure preflight failure 2 failure 'le bundle installé reste inchangé' ''
run_exit_case existing_rust_profile checking_rust_target failure 1 failure 'conservé sans modification' ''
run_exit_case applying_import applying_import failure 1 failure 'son résultat n’est pas confirmé' ''
run_exit_case verify_import verify_import failure 1 failure 'son reçu n’est pas confirmé' ''
run_exit_case imported_before_install preparing_install failure 1 failure 'Le bundle n’a pas été remplacé' ''
run_exit_case uncertain_swap bundle_swap_uncertain failure 1 failure 'échange du bundle est incertain' 'a été remis en place'
run_exit_case confirmed_rollback restored_old_bundle failure 1 failure 'Cette remise en place a été confirmée' ''
run_exit_case verifying_installed_bundle verify_installed_bundle failure 1 failure 'vérification n’est pas confirmée' ''
run_exit_case installed_bundle_verification_failed installed_bundle_verification_failed failure 1 failure 'a échoué à la vérification après installation' ''
run_signal_case ctrl_c INT interrupted 130 'Interruption par Ctrl-C'
run_signal_case term TERM terminated 143 'Arrêt demandé par le système'

MAIN_SCRIPT=
for candidate in "$STATUS_DIR/upgrade-macos-production.command" "$STATUS_DIR/chau7-canonical-upgrade.command"; do
  if [[ -f "$candidate" ]]; then MAIN_SCRIPT="$candidate"; break; fi
done
if [[ -n "$MAIN_SCRIPT" ]]; then
  python3 - "$MAIN_SCRIPT" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r'(?ms)^verify_bundle\(\)\s*\{(.*?)^\}', source)
assert match, 'verify_bundle function not found'
body = match.group(1).splitlines()
python_line = next((i for i, line in enumerate(body) if 'python3 ' in line), None)
codesign_line = next((i for i, line in enumerate(body) if 'codesign ' in line), None)
assert python_line is not None and '|| return $?' in body[python_line], 'Python hash/source failures must return from verify_bundle'
assert codesign_line is not None and '|| return $?' in body[codesign_line], 'codesign failures must return from verify_bundle'
assert python_line < codesign_line, 'Bundle checks must run before codesign'
print('Bundle verifier failure-propagation check passed.')
PY
else
  printf 'Skipped verifier check: no sibling upgrade-macos-production.command or chau7-canonical-upgrade.command.\n'
fi

printf 'Upgrade status regression checks passed.\n'
