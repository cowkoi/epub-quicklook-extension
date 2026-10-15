#!/bin/bash
# Builds EPUBQuickLookHost.app from source and installs it into /Applications.
#
#   ./scripts/install.sh            # sign with your Apple Development certificate if you
#                                   # have one, otherwise sign ad hoc ("run locally")
#   TEAM_ID=ABCDE12345 ./scripts/install.sh
#
# Requires Xcode (not just the Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")/.."
APP=EPUBQuickLookHost.app
EXT_ID=arytek.EPUBQuickLookHost.EPUBQuickLook

if ! xcodebuild -version >/dev/null 2>&1; then
  if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  else
    echo "Xcode is required: install it from the App Store, then re-run." >&2
    exit 1
  fi
fi

# Team ID = the OU field of an "Apple Development" certificate.
if [ -z "${TEAM_ID:-}" ]; then
  CERT=$(security find-certificate -c "Apple Development" -p 2>/dev/null || true)
  if [ -n "$CERT" ]; then
    TEAM_ID=$(printf '%s' "$CERT" | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
              | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')
  fi
fi

if [ -n "${TEAM_ID:-}" ]; then
  echo "Signing with team $TEAM_ID"
  SIGN=(DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates)
else
  echo "No Apple Development certificate found; signing ad hoc."
  SIGN=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi

xcodebuild -project EPUBQuickLookHost.xcodeproj -scheme EPUBQuickLookHost \
  -configuration Release -derivedDataPath build "${SIGN[@]}" build \
  | grep -E "error:|warning: |BUILD" | grep -v appintentsmetadataprocessor || true
[ -d "build/Build/Products/Release/$APP" ] || { echo "Build failed." >&2; exit 1; }

osascript -e 'quit app "EPUBQuickLookHost"' >/dev/null 2>&1 || true
rm -rf "/Applications/$APP"
cp -R "build/Build/Products/Release/$APP" /Applications/

# Launching the app once registers the extension with PlugInKit.
open -g "/Applications/$APP"
sleep 2
osascript -e 'quit app "EPUBQuickLookHost"' >/dev/null 2>&1 || true
pluginkit -e use -i "$EXT_ID" || true
qlmanage -r >/dev/null 2>&1 || true
killall -u "$USER" QuickLookUIService >/dev/null 2>&1 || true

if pluginkit -m -p com.apple.quicklook.preview | grep -q "^+.*$EXT_ID"; then
  echo "Installed. Select an .epub in Finder and press Space."
else
  echo "Installed, but the extension isn't enabled yet: System Settings → General →"
  echo "Login Items & Extensions → Quick Look → enable EPUBQuickLook."
fi
