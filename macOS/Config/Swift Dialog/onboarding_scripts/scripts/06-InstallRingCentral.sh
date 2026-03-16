#!/bin/bash
set -e

PKG_URL="https://downloads.ringcentral.com/RC-Teams-Plugin/RingCentralForTeams.pkg"
PKG_PATH="/tmp/RingCentralForTeams.pkg"

echo "Downloading RingCentral Teams Plugin..."
curl -L -o "$PKG_PATH" "$PKG_URL"

echo "Installing..."
/usr/sbin/installer -pkg "$PKG_PATH" -target /

rm -f "$PKG_PATH"

echo "Done."