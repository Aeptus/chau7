#!/bin/bash
# French typographic apostrophes below are literal message text.
# shellcheck disable=SC1112
# Shared status and exit reporting for upgrade-macos-production.command.
# The caller defines STAGE, RESULT, STATUS_FILE, BACKUP, and LOG before installing traps.

write_status() {
  local result_value="$1" exit_value="$2" temp_file="$STATUS_FILE.tmp.$$"
  mkdir -p "$(dirname "$STATUS_FILE")" || return 1
  if ! python3 - "$temp_file" "$STAGE" "$result_value" "$exit_value" "$BACKUP" "$LOG" <<'PY'
import json, os, sys
target, stage, result, code, backup, log = sys.argv[1:]
data = {'stage': stage, 'result': result, 'exitCode': int(code) if code else None,
        'backupPath': backup, 'logPath': log}
with open(target, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
PY
  then
    rm -f "$temp_file"
    return 1
  fi
  /bin/mv -f "$temp_file" "$STATUS_FILE"
}

set_stage() {
  STAGE="$1"
  write_status "$RESULT" '' || printf 'Statut non actualisé : %s\n' "$STATUS_FILE" >&2
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

on_error() {
  local code="$1"
  RESULT=failure
  printf '\nÉchec de commande (code %s), étape « %s ».\n' "$code" "$STAGE" >&2
  return "$code"
}

on_signal() {
  local signal="$1" code="$2"
  if [[ "$signal" == INT ]]; then
    RESULT=interrupted
  else
    RESULT=terminated
  fi
  exit "$code"
}

report_exit() {
  if [[ "$RESULT" == success ]]; then
    printf '\nSUCCÈS : Chau7 Rust est installé et vérifié. Il n’a PAS été ouvert automatiquement.\n'
    printf 'Pour ouvrir Chau7 Rust :\n\nopen "/Applications/Chau7.app"\n'
    return
  fi
  printf '\nRÉSULTAT : %s (étape « %s »).\n' "$RESULT" "$STAGE" >&2
  case "$RESULT" in
    interrupted) printf 'Interruption par Ctrl-C à l’étape « %s ».\n' "$STAGE" >&2 ;;
    terminated) printf 'Arrêt demandé par le système à l’étape « %s ».\n' "$STAGE" >&2 ;;
  esac
  case "$STAGE" in
    applying_import)
      printf 'L’import a commencé, mais son résultat n’est pas confirmé. Le bundle installé n’a pas été remplacé. Gardez les apps fermées et ne relancez pas l’import; conservez les rapports pour vérifier si la restauration est déjà présente.\n' >&2 ;;
    verify_import)
      printf 'L’import peut avoir été appliqué, mais son reçu n’est pas confirmé. Le bundle installé n’a pas été remplacé. Ne relancez pas l’import; conservez profils et rapports pour examen.\n' >&2 ;;
    restoration_imported|preparing_install|staged_bundle_verified)
      printf 'La restauration est importée et la version précédente est toujours installée. Le bundle n’a pas été remplacé. Gardez Chau7 fermé, ne relancez pas l’import, et conservez profils et sauvegarde avant toute reprise.\n' >&2 ;;
    moving_existing_bundle|moving_new_bundle|bundle_swap_uncertain)
      printf 'L’échange du bundle est incertain. N’ouvrez pas Chau7 et ne déplacez ni ne supprimez aucun bundle. Vérifiez /Applications/Chau7.app et la sauvegarde avant toute action.\n' >&2 ;;
    old_bundle_moved)
      printf 'La restauration est importée. L’ancien bundle a été déplacé dans la sauvegarde; le nouveau n’est pas encore installé. Gardez Chau7 fermé et examinez le journal avant toute reprise.\n' >&2 ;;
    restored_old_bundle)
      printf 'La restauration est importée; l’installation a échoué et l’ancien bundle a été remis en place. Cette remise en place a été confirmée. Gardez Chau7 fermé et conservez la sauvegarde.\n' >&2 ;;
    new_bundle_in_place|verify_installed_bundle)
      printf 'Le nouveau bundle est en place, mais sa vérification n’est pas confirmée. N’ouvrez pas Chau7. Vérifiez les deux bundles et le journal avant toute action.\n' >&2 ;;
    installed_bundle_verification_failed)
      printf 'Le nouveau bundle a échoué à la vérification après installation. N’ouvrez pas Chau7. L’ancien bundle est conservé dans la sauvegarde; examinez les deux bundles et le journal.\n' >&2 ;;
    checking_installed_swift)
      printf 'Aucune restauration ni remplacement n’a été effectué. Le bundle Swift attendu est absent ou lié symboliquement; vérifiez l’installation avant de relancer.\n' >&2 ;;
    checking_rust_target)
      printf 'Un profil Rust existait déjà et a été conservé sans modification. Cette exécution n’a effectué aucun nouvel import ni remplacement du bundle.\n' >&2 ;;
    validating_home)
      printf 'Aucune restauration ni remplacement n’a été effectué. Exécutez le script dans le Terminal de votre compte utilisateur habituel.\n' >&2 ;;
    *)
      printf 'MISE À NIVEAU NON EFFECTUÉE : le bundle installé reste inchangé et aucune restauration n’a été appliquée par cette exécution.\n' >&2 ;;
  esac
}

on_exit() {
  local code="$1"
  trap - EXIT ERR
  trap '' INT TERM
  if [[ "$RESULT" == running ]]; then
    if [[ "$code" -eq 0 && "$STAGE" == completed ]]; then
      RESULT=success
    else
      RESULT=failure
      [[ "$code" -ne 0 ]] || code=1
    fi
  fi
  write_status "$RESULT" "$code" || printf 'Impossible d’enregistrer le statut : %s\n' "$STATUS_FILE" >&2
  report_exit
  printf 'Sauvegarde : %s\nJournal : %s\nStatut : %s\n' "$BACKUP" "$LOG" "$STATUS_FILE"
  if [[ -t 0 ]]; then
    printf '\nAppuyez sur Entrée pour fermer cette fenêtre de statut… '
    IFS= read -r _ || true
  fi
  exit "$code"
}

install_status_traps() {
  trap 'on_exit "$?"' EXIT
  trap 'on_error "$?"' ERR
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
}
