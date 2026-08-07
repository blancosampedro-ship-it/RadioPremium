#!/usr/bin/env bash
#
# enable-carplay-device.sh — Activa CarPlay en las builds de DISPOSITIVO.
#
# Ejecutar SOLO cuando Apple haya concedido el entitlement CarPlay Audio
# (llega por email tras solicitarlo en developer.apple.com/contact/carplay).
#
# Qué hace: añade com.apple.developer.carplay-audio al entitlements de
# dispositivo (RadioPremium-iOS.entitlements). Las builds de simulador ya
# lo llevan vía RadioPremium-iOS-CarPlay.entitlements — ver el comentario
# en ese archivo y el CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*] del
# project.pbxproj.
#
# Después de ejecutarlo:
#   1. En developer.apple.com/account → Identifiers → App ID
#      com.blancosampedro.RadioPremium-iOS → marcar la capability CarPlay.
#   2. Recompilar para dispositivo (Xcode regenerará el perfil con el
#      entitlement al usar firma automática):
#        xcodebuild build -project RadioPremium.xcodeproj \
#          -scheme RadioPremium-iOS -destination 'generic/platform=iOS' \
#          -allowProvisioningUpdates
#   3. Instalar en el iPhone y conectar al coche.
#
# Idempotente: ejecutarlo dos veces no duplica nada.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENT="$(cd "$SCRIPT_DIR/.." && pwd)/RadioPremium-iOS/RadioPremium-iOS.entitlements"

[ -f "$ENT" ] || { echo "✗ No encuentro $ENT" >&2; exit 1; }

if /usr/libexec/PlistBuddy -c "Print :com.apple.developer.carplay-audio" "$ENT" >/dev/null 2>&1; then
    echo "✓ El entitlement ya estaba activado en $ENT — nada que hacer."
    exit 0
fi

/usr/libexec/PlistBuddy -c "Add :com.apple.developer.carplay-audio bool true" "$ENT"
plutil -lint "$ENT" >/dev/null

echo "✓ CarPlay activado en las builds de dispositivo:"
echo "    $ENT"
echo ""
echo "Siguientes pasos:"
echo "  1. developer.apple.com/account → Identifiers → marcar CarPlay en el App ID"
echo "  2. Recompilar con -allowProvisioningUpdates (perfil nuevo automático)"
echo "  3. Instalar en el iPhone y probar en el coche"
