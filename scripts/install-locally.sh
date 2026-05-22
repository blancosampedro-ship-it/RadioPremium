#!/usr/bin/env bash
#
# install-locally.sh — Build Release + copia a /Applications.
#
# Para uso personal en este Mac. Usa el cert "Apple Development" actual.
# NO firma con Developer ID, NO notariza, NO genera DMG.
#
# Estrategia: build sin firmar → strip xattrs → codesign manual → copy.
# El strip+resign manual evita el error de codesign con detritus xattr
# que aparece cuando los iconos PNG arrastran metadatos del sistema.
#
# Output:
#   /Applications/Radio Premium.app
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="RadioPremium"
TARGET_NAME="RadioPremium"
APP_NAME="Radio Premium"
ENTITLEMENTS="$PROJECT_ROOT/RadioPremium.entitlements"
BUILD_DIR="$PROJECT_ROOT/build"
INSTALL_DIR="/Applications"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; RESET="\033[0m"
log()  { echo -e "${GREEN}▶ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
err()  { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }

cd "$PROJECT_ROOT"

# === Detectar identidad de firma ======================================
SIGN_IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Apple Development" | head -1 \
    | sed -E 's/.*"(Apple Development:[^"]+)".*/\1/')
[ -n "$SIGN_IDENTITY" ] || err "No encuentro un cert 'Apple Development' en el Keychain."
log "Cert: $SIGN_IDENTITY"

# === Si la app está corriendo, cerrarla =============================
if pgrep -f "Radio Premium.app/Contents/MacOS\|/RadioPremium.app/Contents/MacOS" >/dev/null 2>&1; then
    log "App abierta — cerrándola para poder reemplazarla…"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    osascript -e "tell application \"$TARGET_NAME\" to quit" 2>/dev/null || true
    sleep 1
    pkill -f "Radio Premium.app/Contents/MacOS" 2>/dev/null || true
    pkill -f "RadioPremium.app/Contents/MacOS" 2>/dev/null || true
    sleep 1
fi

# === Limpiar build anterior ==========================================
log "Limpiando build anterior…"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# === Build Release SIN firmar ========================================
# Codesign con xattr "detritus" en assets falla. Construimos sin firmar
# y firmamos manualmente después de un xattr -cr al .app entero.
log "Build Release (sin firmar)…"
xcodebuild \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -quiet \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build 2>&1 | tail -10

BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/Release/$TARGET_NAME.app"
[ -d "$BUILT_APP" ] || err "No encuentro la app construida en $BUILT_APP"
log "Build OK: $BUILT_APP"

# === Función: strip xattrs prohibidos por codesign ===================
# codesign rechaza FinderInfo, ResourceFork, metadata:* y quarantine como
# "detritus". provenance lo añade el kernel y NO está prohibido.
strip_detritus() {
    local target="$1"
    # Limpieza global recursiva
    xattr -cr "$target" 2>/dev/null || true
    # Y específicos por si quedaron sticky
    find "$target" -exec xattr -d com.apple.FinderInfo {} \; 2>/dev/null || true
    find "$target" -exec xattr -d com.apple.ResourceFork {} \; 2>/dev/null || true
    find "$target" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true
    find "$target" \( -name "*.metadata*" -o -path "*/_kMDItemUserTags" \) \
        -exec xattr -d com.apple.metadata:_kMDItemUserTags {} \; 2>/dev/null || true
}

log "Limpiando xattrs del bundle (pre-firma)…"
strip_detritus "$BUILT_APP"

# === Firmar manualmente con entitlements + hardened runtime ==========
log "Firmando con $SIGN_IDENTITY…"
codesign \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --deep \
    --force \
    --timestamp=none \
    "$BUILT_APP"

# Algunos xattrs vuelven después de codesign --deep porque cada bundle
# anidado se reescribe. Strip otra vez y verificar.
log "Limpiando xattrs del bundle (post-firma)…"
strip_detritus "$BUILT_APP"

# === Verificar firma =================================================
log "Verificando firma…"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP" 2>&1 | tail -5 || warn "verify reportó algo, sigo"
codesign -dv --verbose=2 "$BUILT_APP" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head -5

# === Instalar en /Applications =======================================
TARGET_PATH="$INSTALL_DIR/$APP_NAME.app"

if [ -d "$TARGET_PATH" ]; then
    log "Eliminando versión anterior de $TARGET_PATH…"
    rm -rf "$TARGET_PATH"
fi

log "Copiando a $TARGET_PATH…"
cp -R "$BUILT_APP" "$TARGET_PATH"

# Quitar quarantine (por si la copia lo añade)
xattr -dr com.apple.quarantine "$TARGET_PATH" 2>/dev/null || true

# === Resumen =========================================================
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET_PATH/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$TARGET_PATH/Contents/Info.plist")

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}✓ INSTALADA EN /Applications${RESET}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo ""
echo "Ubicación:    $TARGET_PATH"
echo "Versión:      $VERSION"
echo "Bundle ID:    $BUNDLE_ID"
echo ""
echo "Cómo usarla:"
echo "  • Launchpad → busca 'Radio Premium'"
echo "  • Finder → Aplicaciones → Radio Premium"
echo "  • Spotlight (Cmd+Space) → 'Radio Premium'"
echo ""
echo "Para que arranque al iniciar sesión (opcional):"
echo "  System Settings → General → Login Items → '+' → 'Radio Premium'"
echo ""
echo "Para abrirla ahora:"
echo "  open \"$TARGET_PATH\""
echo ""
