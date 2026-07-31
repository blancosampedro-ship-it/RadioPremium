#!/usr/bin/env bash
#
# install-locally.sh — Build Release + copia a /Applications.
#
# Para uso personal en este Mac. Usa el cert "Apple Development" actual.
# NO firma con Developer ID, NO notariza, NO genera DMG.
#
# Uso:
#   ./scripts/install-locally.sh            # build incremental (rápido)
#   ./scripts/install-locally.sh --clean    # build desde cero
#
# Output:
#   /Applications/Radio Premium.app
#
# ─────────────────────────────────────────────────────────────────────
# POR QUÉ SE COMPILA EN /tmp Y FIRMA XCODE (31-jul-2026)
#
# La versión anterior de este script hacía: build con CODE_SIGNING_ALLOWED=NO
# → xattr -cr → codesign manual con --entitlements RadioPremium.entitlements.
# Eso PRODUCÍA UNA APP QUE NO ARRANCABA. Al firmar con el fichero de
# entitlements en crudo, las variables de Xcode no se expanden: la app quedaba
# con el literal `$(TeamIdentifierPrefix)com.blancosampedro.RadioPremium` y sin
# `application-identifier`, `team-identifier` ni `get-task-allow`. AMFI mataba
# el proceso al lanzarlo (Launch failed / OS_REASON_EXEC / POSIX 163).
#
# Aquel apaño de firma manual existía para esquivar otro error:
#   "resource fork, Finder information, or similar detritus not allowed"
# que salta porque el proyecto vive en ~/Documents = iCloud Drive, e iCloud
# añade xattrs que codesign rechaza.
#
# La raíz era el sitio del build, no la firma. Compilando en /tmp (fuera de
# iCloud) no hay detritus, así que Xcode puede firmar él mismo — expandiendo
# los entitlements correctamente. Se elimina toda la firma manual.
#
# El script verifica ambas cosas antes de instalar, y si la app nueva no
# arranca restaura la anterior automáticamente.
# ─────────────────────────────────────────────────────────────────────
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="RadioPremium"
TARGET_NAME="RadioPremium"
APP_NAME="Radio Premium"
INSTALL_DIR="/Applications"
TARGET_PATH="$INSTALL_DIR/$APP_NAME.app"

# Build FUERA de iCloud — ver cabecera. No usar $PROJECT_ROOT/build.
BUILD_DIR="/tmp/RadioPremium-install-build"
BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/Release/$TARGET_NAME.app"
BACKUP_PATH="$BUILD_DIR/previa-$APP_NAME.app"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; RESET="\033[0m"
log()  { echo -e "${GREEN}▶ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
err()  { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

# PIDs de la app corriendo, o vacío.
#
# OJO con el patrón: pgrep -f usa regex EXTENDIDA. El script original usaba
# "A\|B" creyendo que era una alternancia, pero en ERE `\|` es una barra
# vertical LITERAL, así que nunca casaba con nada. Consecuencia: el bloque de
# "cerrar la app" se saltaba entero, se reemplazaba el bundle con la app
# todavía corriendo, y la verificación de arranque daba un falso OK porque
# encontraba el proceso VIEJO. Aquí `?` hace opcional el espacio, que es lo
# que se pretendía: cubrir "Radio Premium.app" y "RadioPremium.app".
app_pids() {
    pgrep -f "Radio ?Premium\.app/Contents/MacOS" 2>/dev/null || true
}

# Cierra la app: primero por las buenas, luego a lo bruto. 0 si acabó cerrada.
quit_app() {
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    osascript -e "tell application \"$TARGET_NAME\" to quit" 2>/dev/null || true
    for _ in 1 2 3; do
        [ -z "$(app_pids)" ] && return 0
        sleep 1
    done
    pkill -f "Radio ?Premium\.app/Contents/MacOS" 2>/dev/null || true
    for _ in 1 2 3; do
        [ -z "$(app_pids)" ] && return 0
        sleep 1
    done
    return 1
}

CLEAN_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN_BUILD=1 ;;
        -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
        *) err "Argumento desconocido: $arg (usa --clean o --help)" ;;
    esac
done

cd "$PROJECT_ROOT"

# === Avisar si el proyecto está en iCloud ============================
case "$PROJECT_ROOT" in
    "$HOME/Documents"/*|"$HOME/Desktop"/*|*"/Mobile Documents/"*)
        warn "El proyecto vive en una carpeta sincronizada con iCloud."
        warn "Por eso compilamos en $BUILD_DIR y no aquí dentro."
        ;;
esac

# === Build Release, firmado por Xcode ================================
# La app se cierra DESPUÉS de compilar, no antes: así te sigue funcionando
# durante los minutos que tarda el build.
if [ "$CLEAN_BUILD" -eq 1 ]; then
    log "Build limpio: borrando $BUILD_DIR…"
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

log "Build Release en $BUILD_DIR (firma automática de Xcode)…"
# Sin flags de CODE_SIGNING: que Xcode firme y expanda los entitlements.
xcodebuild \
    -project "$PROJECT_ROOT/$SCHEME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -quiet \
    build 2>&1 | tail -10

[ -d "$BUILT_APP" ] || err "No encuentro la app construida en $BUILT_APP"
log "Build OK: $BUILT_APP"

# === Verificar la firma ANTES de instalar ============================
log "Verificando firma…"
codesign --verify --deep --strict "$BUILT_APP" \
    || err "La firma no es válida. No instalo."

ENTS=$(codesign -d --entitlements - --xml "$BUILT_APP" 2>/dev/null | plutil -p - 2>/dev/null || true)

# Este es el chequeo que habría cazado el bug de la firma manual: si una
# variable de Xcode llega sin expandir, AMFI mata la app al arrancarla.
if printf '%s' "$ENTS" | grep -q '\$('; then
    echo "$ENTS"
    err "Hay entitlements SIN EXPANDIR (aparece un \$(...) ahí arriba). La app no arrancaría."
fi

if ! printf '%s' "$ENTS" | grep -q "com.apple.application-identifier"; then
    echo "$ENTS"
    err "Faltan los entitlements del perfil (application-identifier). La app no arrancaría."
fi
log "Entitlements expandidos correctamente."

codesign -dv --verbose=2 "$BUILT_APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -3

# === Cerrar la app antes de reemplazarla =============================
# Crítico: si se reemplaza el bundle con la app corriendo, macOS lo permite
# pero el proceso viejo sigue vivo con el código antiguo, y `open` se limita a
# activarlo. La verificación de arranque daría un OK falso.
if [ -n "$(app_pids)" ]; then
    log "App abierta — cerrándola para poder reemplazarla…"
    quit_app || err "No consigo cerrar la app (PIDs: $(app_pids | tr '\n' ' ')). Ciérrala a mano y reintenta."
    log "Cerrada."
fi

# === Guardar la versión anterior antes de tocar nada =================
if [ -d "$TARGET_PATH" ]; then
    log "Guardando copia de la versión instalada (por si la nueva falla)…"
    rm -rf "$BACKUP_PATH"
    cp -R "$TARGET_PATH" "$BACKUP_PATH"
    rm -rf "$TARGET_PATH"
fi

log "Copiando a $TARGET_PATH…"
cp -R "$BUILT_APP" "$TARGET_PATH"
xattr -dr com.apple.quarantine "$TARGET_PATH" 2>/dev/null || true

# === Verificar que ARRANCA de verdad =================================
# Una firma "válida" no garantiza que la app arranque: los entitlements mal
# formados pasan codesign --verify y luego AMFI mata el proceso. La única
# prueba fiable es lanzarla.
log "Comprobando que arranca…"

# Prerrequisito para que la comprobación signifique algo: no puede quedar
# ninguna instancia viva, o encontraríamos esa y daríamos un OK falso.
[ -z "$(app_pids)" ] || err "Sigue viva una instancia vieja (PIDs: $(app_pids | tr '\n' ' ')). Abortando para no dar un OK falso."

LAUNCH_OK=0
if open -a "$TARGET_PATH" 2>/dev/null; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ -n "$(app_pids)" ]; then
            LAUNCH_OK=1
            break
        fi
        sleep 1
    done
fi

if [ "$LAUNCH_OK" -ne 1 ]; then
    warn "La app instalada NO arranca. Restaurando la versión anterior…"
    rm -rf "$TARGET_PATH"
    if [ -d "$BACKUP_PATH" ]; then
        cp -R "$BACKUP_PATH" "$TARGET_PATH"
        xattr -dr com.apple.quarantine "$TARGET_PATH" 2>/dev/null || true
        warn "Versión anterior restaurada en $TARGET_PATH."
    else
        warn "No había versión anterior que restaurar."
    fi
    echo ""
    echo "Para ver el motivo del fallo:"
    echo "  log show --last 2m --predicate 'eventMessage CONTAINS \"RadioPremium\"' | grep -i 'amfi\\|codesign\\|Launch failed'"
    err "Instalación abortada — se ha dejado el sistema como estaba."
fi
log "Arranca correctamente."

# === Limpiar el registro de LaunchServices ===========================
# Cada xcodebuild registra la app que construye. Si no lo deshacemos, las
# copias de build se acumulan y aparecen apps duplicadas en Spotlight,
# Launchpad y los selectores de apps de otros programas.
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$BUILT_APP" 2>/dev/null || true
    "$LSREGISTER" -f "$TARGET_PATH" 2>/dev/null || true
fi

rm -rf "$BACKUP_PATH"

# === Resumen =========================================================
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET_PATH/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$TARGET_PATH/Contents/Info.plist")

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}✓ INSTALADA EN /Applications — firmada, verificada y arrancando${RESET}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo ""
echo "Ubicación:    $TARGET_PATH"
echo "Versión:      $VERSION"
echo "Bundle ID:    $BUNDLE_ID"
echo ""
echo "Ya está abierta: búscala en la barra de menús (arriba a la derecha)."
echo ""
echo "Para que arranque al iniciar sesión (opcional):"
echo "  System Settings → General → Login Items → '+' → 'Radio Premium'"
echo ""
