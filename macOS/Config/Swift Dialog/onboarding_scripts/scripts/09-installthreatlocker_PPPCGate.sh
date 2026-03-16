#!/bin/bash
# ThreatLocker MDM Deployment Script - Version 3.0.1

GroupKey="cdc8419c9e888e8430f64980"
Instance="api.c"
InstallerPath="/private/var/tmp"

# Check if the script is run with administrative privileges
if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

# -----------------------------
# Intune gating: wait for ThreatLocker configuration profiles (PPPC/System Extension/Login Items)
# -----------------------------
LOG_DIR="/Library/Logs/Microsoft/IntuneScripts/ThreatLocker"
LOG_FILE="${LOG_DIR}/ThreatLockerInstall.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 755 "$LOG_DIR" 2>/dev/null || true

log() { echo "$(date "+%Y-%m-%d %H:%M:%S") -- $*" | tee -a "$LOG_FILE" >&2; }

is_threatlocker_profiles_ready() {
  # We expect BOTH profiles from ThreatLocker to be installed:
  # - ThreatLocker Configuration (v2.1)  (PPPC + System Extension + Network Filter + Notifications)
  # - ThreatLocker Startup & Lock (v2.1) (Managed Login Items + NonRemovable System Extension)
  if ! command -v profiles >/dev/null 2>&1; then
    log "profiles command not available; cannot verify PPPC readiness."
    return 1
  fi

  local p_list p_conf
  p_list="$(/usr/bin/profiles -P 2>/dev/null || true)"
  p_conf="$(/usr/bin/profiles show -type configuration 2>/dev/null || true)"

  local have_cfg=0 have_start=0
  # Match either the original PayloadIdentifier or the display names (Intune may wrap identifiers).
  if grep -qiE "com\.threatlocker\.macos\.config|ThreatLocker Configuration \(v2\.1\)" <<<"$p_list$p_conf"; then
    have_cfg=1
  fi
  if grep -qiE "com\.threatlocker\.macos\.start-lock|ThreatLocker Startup & Lock \(v2\.1\)" <<<"$p_list$p_conf"; then
    have_start=1
  fi

  # Extra confidence check: PPPC payload name and agent bundle id appear in configuration profile output
  if [[ $have_cfg -eq 1 ]]; then
    if ! grep -qiE "payload\[[0-9]+\] name\s*=\s*ThreatLocker Agent Permissions|com\.threatlocker\.app\.agent" <<<"$p_conf"; then
      # Don't hard-fail; some macOS versions format this output differently.
      log "PPPC check: ThreatLocker Configuration profile detected, but could not confirm PPPC payload name in profiles output yet."
    fi
  fi

  if [[ $have_cfg -eq 1 && $have_start -eq 1 ]]; then
    log "PPPC check: ThreatLocker Configuration + Startup & Lock profiles detected. Proceeding."
    return 0
  fi

  log "PPPC check: ThreatLocker profiles not detected yet (cfg=$have_cfg startlock=$have_start). Exiting 0 so Intune can retry."
  return 2
}


# Clean up the .pkg installer file
cleanup() {
    echo "Cleaning up installation files..."
    rm -f "$InstallerPath/ThreatLocker.pkg"
	rm -f "$InstallerPath/ThreatLockerInstallerArguments.txt"
}

# Check system extension state
check_system_extension_state() {
    extensionIdentifier="com.threatlocker.app.agent"
    extensionStates=$(systemextensionsctl list)

	found=0
    while IFS= read -r line; do
        if [[ $line == *"$extensionIdentifier"* ]]; then
            if [[ $line == *"activated enabled"* ]]; then
                echo "ACTIVE_ENABLED"
                return
            elif [[ $line == *"activated waiting for user"* ]]; then
                echo "ACTIVE_WAITING"
                return
            elif [[ $line == *"terminated waiting to uninstall on reboot"* ]]; then
                echo "TERMINATED_WAITING"
				found=1
            else
                echo "ThreatLocker system extension found but not in an expected state: $line"
                echo "UNEXPECTED_STATE"
                return
            fi
        fi
    done <<< "$extensionStates"
	
	if [ $found -eq 1 ]; then
		echo "TERMINATED_WAITING"
		return
	else
		echo "NOT_FOUND"
		return
	fi
}

# Download and install ThreatLocker
install_agent() {
	Response=$(curl -H "InstallKey: $GroupKey" -s -w "%{http_code}" -o /dev/null "https://api.threatlocker.com/getgroupkey.ashx")
    if [ "$Response" -ne 201 ]; then
        echo "Unable to verify GroupKey."
        exit 1
    fi
	
    cat <<EOF > "$InstallerPath/ThreatLockerInstallerArguments.txt"
InstallKey=$GroupKey
Instance=$Instance
EOF
    if [ $? -ne 0 ]; then
        echo "Unable to create arguments file."
        exit 1
    fi

    curl --output "$InstallerPath/ThreatLocker.pkg" "https://updates.threatlocker.com/repository/MAC/pkg/ThreatLocker.pkg"
    if [ ! -f "$InstallerPath/ThreatLocker.pkg" ]; then
        echo "Unable to download ThreatLocker."
        exit 1
    fi

    echo "Installing ThreatLocker..."
    /usr/sbin/installer -pkg "$InstallerPath/ThreatLocker.pkg" -target / -verbose
    
    if [ $? -eq 0 ]; then
        sleep 10
        state=$(check_system_extension_state)
        
        if [[ "$state" == *"ACTIVE_ENABLED"* ]]; then
            echo "ThreatLocker installed successfully."
        elif [[ "$state" == *"ACTIVE_WAITING"* ]]; then
            echo "Action required: User must permit system extension."
			cleanup
            exit 1
        else
            echo "ThreatLocker installed but in an unexpected state. System extension state: $state"
			cleanup
            exit 1
        fi
    else
        echo "Installation failed."
        cleanup
        exit 1
    fi
    cleanup
}

# Main script logic
echo "Checking ThreatLocker system extension state before installation..."
initial_state=$(check_system_extension_state)
echo "Initial system extension state: $initial_state"

if [[ "$initial_state" == *"ACTIVE_ENABLED"* ]]; then
    echo "ThreatLocker is already installed and running."
    exit 0
fi

if [[ "$initial_state" == *"ACTIVE_WAITING"* ]]; then
    echo "Action required: User must permit system extension. Please permit the system extension under System Settings > Privacy."
    exit 1
fi

if [[ "$initial_state" == *"TERMINATED_WAITING"* ]]; then
    echo "ThreatLocker was uninstalled from the system. Reinstalling ThreatLocker..."
    # Gate install until ThreatLocker profiles (PPPC/System Extension/Login Items) are present
    is_threatlocker_profiles_ready
    gate_rc=$?
    if [[ $gate_rc -eq 2 ]]; then
      exit 0
    elif [[ $gate_rc -ne 0 ]]; then
      exit 1
    fi
    install_agent
fi

if [[ "$initial_state" == *"NOT_FOUND"* ]]; then
    echo "ThreatLocker is not installed. Downloading and installing..."
	# Gate install until ThreatLocker profiles (PPPC/System Extension/Login Items) are present
	is_threatlocker_profiles_ready
	gate_rc=$?
	if [[ $gate_rc -eq 2 ]]; then
	  exit 0
	elif [[ $gate_rc -ne 0 ]]; then
	  exit 1
	fi
	install_agent
fi

if [[ "$initial_state" == *"UNEXPECTED_STATE"* ]]; then
	echo "ThreatLocker found but in an unexpected state."
	exit 1
fi
