#!/bin/bash
# French typographic apostrophes below are literal message text.
# shellcheck disable=SC1112
# shellcheck source-path=SCRIPTDIR
# Local production upgrade; executed by the user in Terminal.app.
set -Eeuo pipefail
umask 077

UPGRADE_HOME="${HOME:-}"
REPO="${CHAU7_UPGRADE_REPO:-}"
CHAU7_UPGRADE_APP="${CHAU7_UPGRADE_APP:-}"
CHAU7_UPGRADE_RECEIPT="${CHAU7_UPGRADE_RECEIPT:-}"
CHAU7_UPGRADE_EXPECTED_SHA="${CHAU7_UPGRADE_EXPECTED_SHA:-}"
export PATH="$UPGRADE_HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CARGO_HOME="$UPGRADE_HOME/.cargo" RUSTUP_HOME="$UPGRADE_HOME/.rustup" RUSTC_WRAPPER=''
export CHAU7_CTO_OPTIM_ACTIVE=1
unset CHAU7_NEXT_HOME_ROOT CHAU7_NEXT_ISOLATED_TEST_MODE CHAU7_HOME_ROOT CHAU7_ISOLATED_TEST_MODE CFFIXED_USER_HOME
STAMP="upgrade-$$"
BACKUP="${UPGRADE_HOME:-/private/tmp}/Library/Application Support/Chau7 Upgrade Backups/$STAMP"
OUT=
APP="$CHAU7_UPGRADE_APP"
RECEIPT="$CHAU7_UPGRADE_RECEIPT"
LOG="$BACKUP/upgrade.log"
STATUS_FILE="${UPGRADE_HOME:-/private/tmp}/Library/Logs/Chau7/upgrade-status-$STAMP.json"
STAGE=initializing
RESULT=running

source "$(dirname "$0")/chau7-upgrade-status.sh"
install_status_traps
write_status "$RESULT" '' || printf 'Impossible de créer le statut : %s\n' "$STATUS_FILE" >&2
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP="${UPGRADE_HOME:-/private/tmp}/Library/Application Support/Chau7 Upgrade Backups/$STAMP"
LOG="$BACKUP/upgrade.log"
write_status "$RESULT" '' || printf 'Impossible d’actualiser le statut : %s\n' "$STATUS_FILE" >&2

set_stage validating_home
[[ "$UPGRADE_HOME" == /* && "$UPGRADE_HOME" != /root && $EUID -ne 0 ]] || fail 'Exécuter dans le Terminal de votre compte habituel, sans sudo.'
set_stage checking_installed_swift
[[ -d /Applications/Chau7.app && ! -L /Applications/Chau7.app ]] || fail 'Le bundle /Applications/Chau7.app attendu est absent ou est un lien.'
set_stage preflight
if [[ -z "$REPO" ]]; then
  REPO="$(cd "$(dirname "$0")/../../.." && pwd -P)"
else
  REPO="$(cd "$REPO" && pwd -P)"
fi
[[ -d "$REPO" ]] || fail 'Le dépôt Chau7 indiqué est absent.'
[[ -z "$(/bin/launchctl getenv CHAU7_NEXT_HOME_ROOT || true)" ]] || fail 'Un profil de test est défini dans launchctl. Arrêt sans import.'
SOURCE_HEAD="$(git -C "$REPO" rev-parse HEAD)"
[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]] || fail 'Le dépôt contient des modifications. Arrêt.'
EXPECTED_SHA="${CHAU7_UPGRADE_EXPECTED_SHA:-$SOURCE_HEAD}"
[[ "$EXPECTED_SHA" == "$SOURCE_HEAD" ]] || fail 'La révision attendue ne correspond pas au HEAD source. Arrêt.'
OUT="$REPO/apps/chau7-next/target/bundle/production-$STAMP"
if [[ -z "$APP" && -z "$RECEIPT" ]]; then
  APP="$OUT/Chau7.app"
  RECEIPT="$OUT/Chau7-Production-aarch64-apple-darwin-fast.json"
fi
STATE="$UPGRADE_HOME/Library/Application Support/Chau7/RustV1"
CONFIG="$UPGRADE_HOME/.chau7/rust-v1"
check_target() {
  [[ ! -e "$STATE" && ! -L "$STATE" && ! -e "$CONFIG" && ! -L "$CONFIG" ]] || fail 'Un profil Rust existe déjà : il est conservé, aucun nouvel import ne sera appliqué.'
}
set_stage checking_rust_target
check_target
set_stage preflight
if [[ -n "$CHAU7_UPGRADE_APP" && -z "$CHAU7_UPGRADE_RECEIPT" ]] ||
   [[ -z "$CHAU7_UPGRADE_APP" && -n "$CHAU7_UPGRADE_RECEIPT" ]]; then
  fail 'Fournir ensemble CHAU7_UPGRADE_APP et CHAU7_UPGRADE_RECEIPT, ou aucun des deux.'
fi
if [[ -n "$CHAU7_UPGRADE_APP" ]]; then
  [[ -d "$APP" && ! -L "$APP" && -f "$RECEIPT" && ! -L "$RECEIPT" ]] || fail 'Le bundle candidat ou son reçu est absent, invalide, ou lié symboliquement.'
fi
mkdir -p "$BACKUP"
printf 'Sauvegardes et journal : %s\nStatut : %s\n' "$BACKUP" "$STATUS_FILE"
exec > >(tee -a "$LOG") 2>&1

cat > "$BACKUP/verify-bundle.py" <<'PY'
import hashlib, json, pathlib, plistlib, sys
app, receipt, expected = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
    return digest.hexdigest()
def require(ok, message):
    if not ok: raise SystemExit(message)
r = json.loads(receipt.read_text())
require(r['channel'] == 'production' and r['bundleIdentifier'] == 'com.chau7.app', 'Mauvais canal ou identifiant')
require(r['sourceRevision'] == expected and r['sourceDirty'] is False, 'Source non conforme')
require(r['appSignatureVerified'] is True and 'chau7_next_core/production' in r['cargoFeatures'], 'Production non vérifiée')
require(set(r['artifacts']) == {'Chau7', 'chau7-next-mcp-bridge', 'chau7-next-cli', 'chau7-optim', 'chau7-md', 'chau7-remote', 'chau7-proxy'}, 'Liste de helpers incomplète')
p = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
require(p['CFBundleIdentifier'] == 'com.chau7.app' and p['Chau7SourceRevision'] == expected, 'Bundle non conforme')
for name, item in r['artifacts'].items():
    path = app / item['path']
    require(path.is_file() and bool(item['sha256']), 'Helper absent : ' + name)
    require(sha256_file(path) == item['sha256'], 'Empreinte incorrecte : ' + name)
print('Bundle et sept exécutables vérifiés.')
PY
verify_bundle() {
  python3 "$BACKUP/verify-bundle.py" "$1" "$RECEIPT" "$EXPECTED_SHA" || return $?
  /usr/bin/codesign --verify --deep --strict "$1" || return $?
}
if [[ -n "$CHAU7_UPGRADE_APP" ]]; then
  set_stage verifying_prepared_candidate
  printf '\nVérification du bundle candidat fourni; aucune compilation ne sera lancée.\n'
else
  set_stage building
  printf '\nConstruction de Chau7 Rust, version locale 0.6.0-rc.1…\n'
  (
    cd "$REPO/apps/chau7-next"
    CHANNEL=production RELEASE_VERSION=0.6.0-rc.1 BUILD_MODE=fast \
    TARGET=aarch64-apple-darwin CARGO_BUILD_JOBS=2 GOMAXPROCS=2 GOFLAGS=-p=2 \
    CARGO_TARGET_DIR="$REPO/apps/chau7-next/target/fast-199" \
    REQUIRE_REMOTE_AGENT=1 REQUIRE_PROXY=1 OUT_DIR="$OUT" \
      ./scripts/bundle-macos.sh
  )
  set_stage verifying_built_candidate
fi
verify_bundle "$APP"
cp "$RECEIPT" "$BACKUP/build-receipt.json"

apps_stopped() {
  local running status
  running="$(/usr/bin/osascript -l JavaScript <<'JS'
ObjC.import('AppKit');
var found = [], apps = $.NSWorkspace.sharedWorkspace.runningApplications;
for (var i = 0; i < apps.count; i++) {
  var app = apps.objectAtIndex(i);
  var name = ObjC.unwrap(app.localizedName) || '';
  var id = ObjC.unwrap(app.bundleIdentifier) || '';
  if (name.indexOf('Chau7') === 0 || id.indexOf('com.chau7.') === 0) found.push(name);
}
found.join('\n');
JS
  )" || fail 'Impossible de vérifier les applications ouvertes.'
  [[ -z "$running" ]] || { printf 'Encore ouvert : %s\n' "$running"; return 1; }
  if /usr/bin/pgrep -x 'Chau7|Chau7 Next|chau7_next' >/dev/null; then
    printf 'Un processus Chau7 est encore ouvert.\n'; return 1
  else
    status=$?
    [[ $status -eq 1 ]] || fail 'Impossible de vérifier les processus.'
  fi
}
printf '\nLe bundle est prêt. Dans Chau7 et Chau7 Next, utilisez Quitter (Cmd+Q), sans fermer les onglets un par un.\nNe les rouvrez pas pendant la migration. Ce script ne ferme aucune app.\n'
set_stage awaiting_app_shutdown
while true; do
  read -r -p 'Après leur fermeture normale, appuyez sur Entrée dans ce Terminal : ' _
  if apps_stopped; then break; fi
done
check_target

set_stage backing_up_swift_data
python3 - "$UPGRADE_HOME" "$BACKUP/home" <<'PY'
import hashlib, os, pathlib, shutil, stat, sys
home, backup = map(pathlib.Path, sys.argv[1:])
items = ['.chau7-next', '.chau7', 'Library/Application Support/Chau7 Next', 'Library/Application Support/Chau7', 'Library/Preferences/com.chau7.app.plist', 'Library/Preferences/com.chau7.next.plist']
def ignore_runtime(directory, names):
    return [n for n in names if stat.S_ISSOCK(os.lstat(os.path.join(directory, n)).st_mode) or stat.S_ISFIFO(os.lstat(os.path.join(directory, n)).st_mode)]
def manifest(root):
    result = {}
    def scan(path):
        mode = path.lstat().st_mode
        key = str(path.relative_to(root))
        if stat.S_ISLNK(mode): result[key] = ('symlink', os.readlink(path))
        elif stat.S_ISDIR(mode):
            result[key] = ('dir',)
            for child in path.iterdir(): scan(child)
        elif stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with path.open('rb') as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
            result[key] = ('file', digest.hexdigest())
        elif not (stat.S_ISSOCK(mode) or stat.S_ISFIFO(mode)): raise SystemExit('Fichier spécial inattendu : ' + key)
    scan(root)
    return result
for relative in items:
    source, target = home / relative, backup / relative
    if source.is_symlink(): raise SystemExit('Profil lié symboliquement : arrêt sans import')
    if not source.exists(): continue
    before = manifest(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir(): shutil.copytree(source, target, symlinks=True, ignore=ignore_runtime)
    else: shutil.copy2(source, target)
    if before != manifest(target) or before != manifest(source):
        raise SystemExit('La source a changé ou la sauvegarde diffère : arrêt sans import')
    print('Sauvegarde vérifiée : ' + relative)
print('Seuls les sockets et tubes de communication temporaires sont exclus.')
PY
/usr/bin/ditto -c -k --sequesterRsrc --keepParent /Applications/Chau7.app "$BACKUP/Chau7-before-upgrade.zip"
apps_stopped || fail 'Une app a été rouverte : arrêt avant import.'
check_target
set_stage dry_run_import
"$APP/Contents/MacOS/Chau7" --import-chau7-restoration swift --source-home "$BACKUP/home" --dry-run > "$BACKUP/import-dry-run.json"
python3 - "$BACKUP/import-dry-run.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if r.get('source') != 'swift' or r.get('dry_run') is not True or any(r.get(k, 0) <= 0 for k in ('windows', 'tabs', 'panes')):
    raise SystemExit('Restauration vide ou source incorrecte : arrêt sans import')
print('Résumé de restauration : {windows} fenêtres, {tabs} onglets, {panes} panneaux.'.format(**r))
preserved = r.get('preserved', {})
def count(value):
    if isinstance(value, int): return value
    if isinstance(value, (list, dict)): return len(value)
    return 0
print('Informations conservées, sans reprise automatique : {0} blocs de commande dans {1} onglets; {2} aperçus d’onglet.'.format(
    count(preserved.get('tab_command_blocks', 0)),
    count(preserved.get('tabs_with_command_blocks', 0)),
    count(preserved.get('tab_preview_images', 0))))
print('Métadonnées conservées : {0} identifiants IA internes inertes; ils ne lancent aucune commande.'.format(
    count(preserved.get('inert_ai_identities', 0))))
if any(r.get('warnings', {}).values()):
    raise SystemExit('Avertissements de migration : arrêt sans import. Conserver ce rapport pour examen.')
PY
apps_stopped || fail 'Une app a été rouverte : arrêt avant import.'
set_stage applying_import
"$APP/Contents/MacOS/Chau7" --import-chau7-restoration swift --source-home "$BACKUP/home" > "$BACKUP/import-applied.json"
set_stage verify_import
python3 - "$BACKUP/import-dry-run.json" "$BACKUP/import-applied.json" "$STATE/TabRestoreBundles/import-receipt.json" <<'PY'
import json, sys
expected, applied, receipt = [json.load(open(p)) for p in sys.argv[1:]]
expected['dry_run'] = False
if applied != expected or receipt != expected:
    raise SystemExit('Le reçu de restauration diffère : arrêt, conserver tous les fichiers')
print('Import vérifié : {windows} fenêtres, {tabs} onglets, {panes} panneaux.'.format(**applied))
preserved = applied.get('preserved', {})
def count(value):
    if isinstance(value, int): return value
    if isinstance(value, (list, dict)): return len(value)
    return 0
print('Informations conservées, sans reprise automatique : {0} blocs de commande dans {1} onglets; {2} aperçus.'.format(
    count(preserved.get('tab_command_blocks', 0)),
    count(preserved.get('tabs_with_command_blocks', 0)),
    count(preserved.get('tab_preview_images', 0))))
print('Métadonnées IA internes inertes conservées : {0}; elles ne lancent aucune commande.'.format(
    count(preserved.get('inert_ai_identities', 0))))
PY
set_stage restoration_imported

STAGED="/Applications/.Chau7-upgrade-$STAMP.app"
[[ ! -e "$STAGED" && ! -L "$STAGED" ]] || fail 'Le chemin de préparation existe déjà.'
printf '\nInstallation du bundle ; macOS peut demander votre mot de passe administrateur.\n'
set_stage preparing_install
sudo /usr/bin/ditto "$APP" "$STAGED"
verify_bundle "$STAGED"
set_stage staged_bundle_verified
apps_stopped || fail 'Une app a été rouverte : arrêt avant remplacement du bundle.'
mkdir "$BACKUP/previous"
set_stage moving_existing_bundle
sudo /bin/mv /Applications/Chau7.app "$BACKUP/previous/Chau7.app"
set_stage old_bundle_moved
set_stage moving_new_bundle
if ! sudo /bin/mv "$STAGED" /Applications/Chau7.app; then
  set_stage bundle_swap_uncertain
  if [[ ! -e /Applications/Chau7.app && ! -L /Applications/Chau7.app ]] &&
     sudo /bin/mv "$BACKUP/previous/Chau7.app" /Applications/Chau7.app; then
    set_stage restored_old_bundle
    fail 'Installation interrompue ; ancien bundle remis en place et commande confirmée.'
  else
    fail 'Installation interrompue et remise en place non confirmée. Ne déplacez aucun bundle avant inspection.'
  fi
fi
set_stage new_bundle_in_place
set_stage verify_installed_bundle
if ! verify_bundle /Applications/Chau7.app; then
  set_stage installed_bundle_verification_failed
  fail 'La vérification du bundle installé a échoué; aucun retour arrière automatique n’a été tenté.'
fi
set_stage completed
