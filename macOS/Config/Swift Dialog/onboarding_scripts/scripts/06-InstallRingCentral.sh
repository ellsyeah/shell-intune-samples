#!/bin/bash
set -e

appname="RingCentral for Teams"
PKG_URL="https://downloads.ringcentral.com/RC-Teams-Plugin/RingCentralForTeams.pkg"
PKG_PATH="/tmp/RingCentralForTeams.pkg"

updateSplashScreen() {
    if [ -e "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog" ]; then
        echo "$(date) | Updating Swift Dialog monitor for ${appname} to [$1]"
        echo "listitem: title: ${appname}, status: $1, statustext: $2" >> /var/tmp/dialog.log
    fi
}

trap 'updateSplashScreen fail "Failed"' ERR

updateSplashScreen wait "Downloading"
echo "Downloading RingCentral Teams Plugin..."
curl -L -o "$PKG_PATH" "$PKG_URL"

updateSplashScreen wait "Installing"
echo "Installing..."
/usr/sbin/installer -pkg "$PKG_PATH" -target /

rm -f "$PKG_PATH"
updateSplashScreen success "Installed"
echo "Done."
