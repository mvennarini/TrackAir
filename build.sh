#!/bin/bash
# TrackAir – build, test e installazione.
#   ./build.sh mac      -> build/TrackAir.app (Release, firmata con il certificato Apple Development)
#   ./build.sh test     -> test automatici del livello sicuro (macOS)
#   ./build.sh ios      -> compila e installa sull'iPhone/iPad collegato
#   ./build.sh all      -> test + mac + ios
#   ./build.sh release  -> build/TrackAir.app firmata "Developer ID" e notarizzata (serve l'account a pagamento)
set -euo pipefail
cd "$(dirname "$0")"

# Identita' di firma e team: rilevati dal certificato "Apple Development" nel portachiavi
# (lo crea Xcode al primo accesso con l'Apple ID). Si possono forzare con le variabili
# d'ambiente TEAM e MAC_SIGN_ID.
MAC_SIGN_ID="${MAC_SIGN_ID:-$(security find-identity -v -p codesigning | grep "Apple Development" | awk '{print $2}' | head -1)}"
TEAM="${TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | grep -oE 'OU=[A-Z0-9]{10}' | head -1 | cut -c4-)}"
BUNDLE_IOS="${BUNDLE_IOS:-com.michelevennarini.trackair}"
DD="DerivedData"
if [ -z "$TEAM" ]; then echo "Nessun certificato Apple Development: apri Xcode > Impostazioni > Account e accedi con l'Apple ID"; exit 1; fi
echo "team: $TEAM"

DEVELOPMENT_TEAM="$TEAM" xcodegen generate >/dev/null

build_mac() {
  echo "==> Mac"
  xcodebuild -project TrackAir.xcodeproj -scheme TrackAirMac -configuration Release -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  rm -rf build/TrackAir.app
  mkdir -p build
  cp -R "$DD/Build/Products/Release/TrackAir.app" build/
  # Firma stabile: il permesso Accessibilita' resta valido tra una build e l'altra.
  if [ -n "$MAC_SIGN_ID" ]; then codesign --force --deep --sign "$MAC_SIGN_ID" build/TrackAir.app; fi
  echo "    -> build/TrackAir.app"
}

run_tests() {
  echo "==> Test"
  xcodebuild -project TrackAir.xcodeproj -scheme TrackAirMac -configuration Debug -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" test 2>&1 \
    | grep -E "error:|Executed|TEST (SUCCEEDED|FAILED)" || true
}

build_ios() {
  echo "==> iOS"
  # UDID del dispositivo fisico (xctrace lo elenca anche quando devicectl lo segna solo "available")
  # Preferisce il primo dispositivo davvero raggiungibile (devicectl risponde), iPhone prima dell'iPad.
  DEVICE=""
  for cand in $(xcrun xctrace list devices 2>/dev/null | grep -viE "simulator|mac" | grep -E "iPhone|iPad" | sort -r | grep -oE "\(([0-9A-F]{8}-[0-9A-F]{16})\)" | tr -d "()"); do
    if xcrun devicectl device info details --device "$cand" >/dev/null 2>&1; then DEVICE="$cand"; break; fi
  done
  if [ -z "$DEVICE" ]; then echo "Nessun iPhone/iPad raggiungibile: collegalo col cavo e sbloccalo"; exit 1; fi
  echo "    dispositivo: $DEVICE"
  xcodebuild -project TrackAir.xcodeproj -scheme TrackAir -configuration Debug -derivedDataPath "$DD" \
    -destination "id=$DEVICE" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  APP="$DD/Build/Products/Debug-iphoneos/TrackAir.app"
  [ -d "$APP" ] || { echo "Build iOS fallita"; exit 1; }
  echo "==> Installo sul dispositivo"
  xcrun devicectl device install app --device "$DEVICE" "$APP" | grep -E "installationURL|rror" || true
  xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE_IOS" | grep -iE "launched|rror" || true
}

build_release() {
  # Richiede: Apple Developer Program, certificato "Developer ID Application",
  # e le credenziali di notarizzazione salvate con:
  #   xcrun notarytool store-credentials trackair --apple-id EMAIL --team-id TEAM
  echo "==> Release Mac (Developer ID + notarizzazione)"
  DEV_ID=$(security find-identity -v -p codesigning | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"')
  [ -n "$DEV_ID" ] || { echo "Nessun certificato Developer ID: serve l'Apple Developer Program"; exit 1; }
  xcodebuild -project TrackAir.xcodeproj -scheme TrackAirMac -configuration Release -derivedDataPath "$DD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEV_ID" ENABLE_HARDENED_RUNTIME=YES build | grep -E "error:|BUILD" || true
  rm -rf build/TrackAir.app && mkdir -p build && cp -R "$DD/Build/Products/Release/TrackAir.app" build/
  codesign --force --deep --options runtime --timestamp --sign "$DEV_ID" build/TrackAir.app
  ditto -c -k --keepParent build/TrackAir.app build/TrackAir.zip
  xcrun notarytool submit build/TrackAir.zip --keychain-profile trackair --wait
  xcrun stapler staple build/TrackAir.app
  echo "    -> build/TrackAir.app notarizzata"
}

case "${1:-all}" in
  mac) build_mac ;;
  test) run_tests ;;
  ios) build_ios ;;
  release) build_release ;;
  all) run_tests; build_mac; build_ios ;;
esac
