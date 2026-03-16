#!/bin/bash
appname="Rename Mac"

updateSplashScreen() {
    if [ -e "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog" ]; then
        echo "$(date) | Updating Swift Dialog monitor for ${appname} to [$1]"
        echo "listitem: title: ${appname}, status: $1, statustext: $2" >> /var/tmp/dialog.log
    fi
}

updateSplashScreen wait "Renaming Mac"

# Get serial number
FULL_SN=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
# Take last 6 characters
PARTIAL_SN=${FULL_SN:(-6)}
# Rename
scutil --set ComputerName "GK-$PARTIAL_SN"
scutil --set HostName "GK-$PARTIAL_SN"
scutil --set LocalHostName "GK-$PARTIAL_SN"

updateSplashScreen success "Renamed"
