#!/bin/bash
# Get serial number
FULL_SN=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
# Take last 6 characters
PARTIAL_SN=${FULL_SN:(-6)}
# Rename
scutil --set ComputerName "GK-$PARTIAL_SN"
scutil --set HostName "GK-$PARTIAL_SN"
scutil --set LocalHostName "GK-$PARTIAL_SN"