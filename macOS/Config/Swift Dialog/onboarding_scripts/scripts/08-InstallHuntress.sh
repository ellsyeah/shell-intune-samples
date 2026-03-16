#!/usr/bin/env zsh

# Copyright (c) 2025 Huntress Labs, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#    * Redistributions of source code must retain the above copyright
#      notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above copyright
#      notice, this list of conditions and the following disclaimer in the
#      documentation and/or other materials provided with the distribution.
#    * Neither the name of the Huntress Labs nor the names of its contributors
#      may be used to endorse or promote products derived from this software
#      without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL HUNTRESS LABS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
# OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


# The Huntress installer needs an Account Key and an Organization Key (a user
# specified name or description) which is used to affiliate an Agent with a
# specific Organization within the Huntress Partner's Account. These keys can be
# hard coded below or passed in when the script is run.

# For more details, see our KB article
# https://support.huntress.io/hc/en-us/articles/25013857741331-Critical-Steps-for-Complete-macOS-EDR-Deployment


##############################################################################
## Begin user modified variables
##############################################################################

# Replace __ACCOUNT_KEY__ with your account secret key (from your Huntress portal's "download agent" section)
defaultAccountKey="f076f701e45eab311ab1491b11102233"

# If you have a preferred "placeholder" organization name for Mac agents, you can set that below.
# Otherwise, provide the appropriate Organization Key when running the script in your RMM.
defaultOrgKey="gk"

# Put the name of your RMM below. This helps our support team understand which RMM tools
# are being used to deploy the Huntress macOS Agent. Simply replace the text in quotes below.
rmm="Unspecified RMM"

# Option to install the system extension after the Huntress Agent is installed. In order for this to happen
# without security prompts on the endpoint, permissions need to be applied to the endpoint by an MDM before this script
# is run. See the following KB article for instructions:
# https://support.huntress.io/hc/en-us/articles/21286543756947-Instructions-for-the-MDM-Configuration-for-macOS
install_system_extension=true

##############################################################################
## Do not modify anything below this line
##############################################################################


appname="Huntress"

updateSplashScreen() {
  if [ -e "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog" ]; then
    echo "$(date) | Updating Swift Dialog monitor for ${appname} to [$1]"
    echo "listitem: title: ${appname}, status: $1, statustext: $2" >> /var/tmp/dialog.log
  fi
}

scriptVersion="April 15, 2025"

version="1.1 - $scriptVersion"
dd=$(date "+%Y-%m-%d  %H:%M:%S")
log_file="/tmp/HuntressInstaller.log"
log_file_location="/Users/Shared/"
install_script="/tmp/HuntressMacInstall.sh"
invalid_key="Invalid account secret key"
pattern="[a-f0-9]{32}"

# Using logger function to provide helpful logs within RMM tools in addition to log file
logger() {
    echo "$dd -- $*";
    echo "$dd -- $*" >> $log_file;
}

# Compatibility aliases used by appended PPPC gating logic
log_message() { logger "$@"; }
log_error()  { logger "ERROR: $*"; }


# --- PPPC readiness detection (Huntress) ---
# Returns 0 when required FDA approvals exist in TCC.db; otherwise returns 1.
# This allows Intune/RMM to retry later without marking the script as failed.
is_huntress_pppc_ready() {
  # Goal: detect whether the Huntress PPPC profile (FDA pre-approval) has been installed.
  # IMPORTANT: PPPC approvals are delivered via configuration profiles and may NOT appear in TCC.db until the app actually accesses the protected resource.
  # So the most reliable "is the policy applied?" check is: confirm the PPPC payload exists in installed profiles.

  # NOTE: These IDs must match the PPPC payload's Identifier values.
  local app_id="com.huntress.app"
  local sysext_id="com.huntress.sysext"

  # What we can reliably see from the installed profile (Intune wraps custom payloads with a www.windowsintune.com.custompayload.* identifier).
  # So we match on human-friendly strings shown in `profiles show` output.
  local pppc_payload_name_regex="Huntress PPPC"
  local pppc_profile_hint_regex="Huntress System Extension"

  # 1) Preferred: check installed configuration profiles (works even before the app prompts/uses FDA)
  if command -v /usr/bin/profiles >/dev/null 2>&1; then
    # Try to get installed profiles as XML first; if that fails (varies by macOS version), fall back to text output.
    local profiles_xml
    profiles_xml="$(/usr/bin/profiles -P -o stdout-xml 2>/dev/null || true)"

    if [[ -n "${profiles_xml}" ]]; then
      # If we can see the payload name or obvious Huntress hints in the profile XML, treat PPPC as present.
      if grep -qiE "${pppc_payload_name_regex}|${pppc_profile_hint_regex}" <<<"${profiles_xml}"; then
        log_message "PPPC check: Detected Huntress PPPC payload in installed profiles (XML)."
        return 0
      fi
    else
      # Text-based fallback (Sequoia/older Macs can be inconsistent with stdout-xml)
      local profiles_text
      profiles_text="$(/usr/bin/profiles show -type configuration 2>/dev/null || true)"
      if [[ -n "${profiles_text}" ]] && grep -qiE "${pppc_payload_name_regex}|${pppc_profile_hint_regex}" <<<"${profiles_text}"; then
        log_message "PPPC check: Detected Huntress PPPC payload in installed profiles (text)."
        return 0
      fi
    fi
  fi

  # 2) Fallback (best-effort): query TCC.db for already-materialized decisions.
  # This is NOT reliable as a readiness signal on modern macOS, but it can still be useful for troubleshooting.
  if ! command -v /usr/bin/sqlite3 >/dev/null 2>&1; then
    log_message "PPPC check: sqlite3 not available; cannot query TCC.db. Treating as not ready."
    return 1
  fi

  _tcc_count_rows() {
    local db_path="$1"
    [[ -r "${db_path}" ]] || { echo "0"; return 0; }

    # Detect schema: older macOS uses 'allowed'; newer uses 'auth_value'
    local schema
    schema="$(/usr/bin/sqlite3 "${db_path}" "PRAGMA table_info(access);" 2>/dev/null | cut -d'|' -f2 | tr '
' ' ')"

    local allow_pred="1=0"
    if echo "${schema}" | grep -qw "allowed"; then
      allow_pred="allowed=1"
    elif echo "${schema}" | grep -qw "auth_value"; then
      # auth_value: 2=Allow, 0=Deny; be permissive and treat >=1 as granted/limited
      allow_pred="auth_value>=1"
    fi

    local q
    q="SELECT count(*) FROM access WHERE service IN ('${svc_allfiles}','${svc_sysadmin}') AND client IN ('${app_id}','${sysext_id}') AND (${allow_pred});"
    /usr/bin/sqlite3 "${db_path}" "${q}" 2>/dev/null | tr -d '[:space:]' || echo "0"
  }

  local total_rows=0

  # System TCC
  local sys_tcc="/Library/Application Support/com.apple.TCC/TCC.db"
  local sys_rows
  sys_rows="$(_tcc_count_rows "${sys_tcc}")"
  [[ -n "${sys_rows}" ]] || sys_rows="0"
  total_rows=$(( total_rows + sys_rows ))

  # User TCC (console user)
  local console_user
  console_user="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -n "${console_user}" && "${console_user}" != "root" && "${console_user}" != "loginwindow" ]]; then
    local user_home
    user_home="$(/usr/bin/dscl . -read "/Users/${console_user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "${user_home}" ]]; then
      local user_tcc="${user_home}/Library/Application Support/com.apple.TCC/TCC.db"
      local user_rows
      user_rows="$(_tcc_count_rows "${user_tcc}")"
      [[ -n "${user_rows}" ]] || user_rows="0"
      total_rows=$(( total_rows + user_rows ))
    fi
  fi

  if [[ "${total_rows}" -gt 0 ]]; then
    log_message "PPPC check: Found Huntress entries in TCC.db (rows=${total_rows})."
    return 0
  fi

  log_message "PPPC check: Huntress PPPC payload not detected yet (profiles/TCC)."
  return 1
}

# Copies the log from a temp location to /users/shared/  and exits with the given code
# Using this folder as /tmp/ is wiped on reboot, Huntress folders are protected by TP, and because any user should have access to this folder
copyLog() {
    # capture exit command for script finish-up
    local exitCode="$?"
    if [ -d $log_file_location ]; then
        logger "Copying log file to /Users/Shared/"
        cp "$log_file" "${log_file_location}/HuntressInstaller.log"
    fi
    if [ $exitCode -ne "0" ]; then
        logger "Exit with error, please send ${log_file_location}HuntressInstaller.log to support."
    fi
    exit "$exitCode"
}
trap copyLog EXIT

# Log system info for troubleshooting
logger "macOS version: $(sw_vers --ProductVersion)"
logger "Free disk space: "$(df -Pk . | sed 1d | grep -v used | awk '{ print $4 "\t" }')
logger $(top -l 1 | head -n 7 | tail -n 1)
logger $(top -l 1 | head -n 3 | tail -n 1)
logger "System uptime: $(uptime)"
logger "User id (should be 0): "$(id -u)
logger "Huntress install script last updated $scriptVersion"

# Check for root
updateSplashScreen wait "Starting"

if [ $EUID -ne 0 ]; then
    logger "This script must be run as root, exiting..."
    exit 1
fi

# Clean up any old installer scripts.
if [ -f "$install_script" ]; then
    logger "Installer file present in /tmp; deleting."
    rm -f "$install_script"
fi

##
## This section handles the assigning `=` character for options.
## Since most RMMs treat spaces as delimiters in Mac Scripting,
## we have to use `=` to assign the option value, but must remove
## it because, well, bash. https://stackoverflow.com/a/28466267/519360
##

usage() {
    cat <<EOF
Usage: $0 [options...] --account_key=<account_key> --organization_key=<organization_key>

-a, --account_key      <account_key>      The account key to use for this agent install
-o, --organization_key <organization_key> The org key to use for this agent install
-t, --tags             <tags>             A comma-separated list of agent tags to use for this agent install
-i, --install_system_extension            If passed, automatically install the system extension
-h, --help                                Print this message

EOF
}

reinstall=false
while getopts "a:o:t:ihr-:" OPT; do
    if [ "$OPT" = "-" ]; then
        OPT="${OPTARG%%=*}"       # extract long option name
        OPTARG="${OPTARG#$OPT}"   # extract long option argument (may be empty)
        OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
    else
        # the user used a short option, but we still want to strip the assigning `=`
        OPTARG="${OPTARG#=}"      # if long option argument, remove assigning `=`
    fi
    case "$OPT" in
        a | account_key)
            account_key="$OPTARG"
            ;;
        o | organization_key)
            organization_key="$OPTARG"
            ;;
        t | tags)
            tags="$OPTARG"
            ;;
        i | install_system_extension)
            logger "Running with System Extension immediate install option"
            install_system_extension=true
            ;;
        r | reinstall)
            logger "Running with the -reinstall flag"
            reinstall=true
            ;;
        h | help)
            usage
            exit 0
            ;;
        ??*)
            logger "Illegal option --$OPT"
                exit 2
            ;;  # bad long option
        \? )
                exit 2
            ;;  # bad short option (error reported via getopts)
    esac
done
shift $((OPTIND-1)) # remove parsed options and args from $@ list

# try/catch, if the connectivity tester fails to execute we'll log that as an error.
for hostn in "update.huntress.io" "huntress.io" "eetee.huntress.io" "huntress-installers.s3.amazonaws.com" "huntress-updates.s3.amazonaws.com" "huntress-uploads.s3.us-west-2.amazonaws.com" "huntress-user-uploads.s3.amazonaws.com" "huntress-rio.s3.amazonaws.com" "huntress-survey-results.s3.amazonaws.com"; do
    logger "$(nc -z -v $hostn 443 2>&1)" || (logger "error occured during network connectivity test")
done

# Check for existing Huntress install, if already installed exit with error. Bypass if using the reinstall flag.
if [ $reinstall = false ]; then
    if [ -d "/Applications/Huntress.app/Contents/Macos" ]; then
        logger "Huntress assets found, checking for running processes"
        numServicesStopped=0
        for HuntressProcess in "HuntressAgent" "HuntressUpdater"; do
            if [ $(pgrep "$HuntressProcess" > /dev/null) ]; then
                logger "Warning: process $HuntressProcess is stopped"
                numServicesStopped++
            else
                logger "Process $HuntressProcess is running"
            fi
        done
        if [ $numServicesStopped -gt 0 ]; then
            logger "Installation appears damaged, suggest running with the -reinstall flag"
        else
            logger "Installation found and processes are running. If you suspect this agent is damaged try running this script with the -reinstall flag"
        fi
        exit 1
    fi
fi


logger "=========== INSTALL START AT $dd ==============="
logger "=========== $rmm Deployment Script | Version: $version ==============="

# validate options passed to script, remove all invalid characters except spaces are converted to dash
if [ -z "$organization_key" ]; then
    organizationKey=$(echo "$defaultOrgKey" | tr -dc '[:alnum:]- ' | tr ' ' '-' | xargs)
    logger "--organization_key parameter not present, using defaultOrgKey instead: $defaultOrgKey, formatted to $organizationKey "
  else
    organizationKey=$(echo "$organization_key" | tr -dc '[:alnum:]- ' | tr ' ' '-' | xargs)
    logger "--organization_key parameter present, set to: $organization_key, formatted to $organizationKey "
fi

if ! [[ "$account_key" =~ $pattern ]]; then
    logger "Invalid --account_key provided, checking defaultAccountKey..."
    accountKey=$(echo "$defaultAccountKey" | xargs)
    if ! [[ $accountKey =~ $pattern ]]; then
        # account key is invalid if script gets to this branch, so write the key unmasked for troubleshooting
        logger "ERROR: Invalid --account_key, $accountKey was provided. Please check Huntress support documentation."
        exit 1
    fi
    else
        accountKey=$(echo "$account_key" | xargs)
fi

if [ -n "$tags" ]; then
  logger "using tags: $tags"
fi

if [ "$install_system_extension" = true ]; then
  logger "automatically installing system extension"
fi

# Hide most of the account key in the logs, keeping the front and tail end for troubleshooting
masked="$(echo "${accountKey:0:4}")"
masked+="************************"
masked+="$(echo "${accountKey: (-4)}")"

# OPTIONS REQUIRED (account key could be invalid in this branch, so mask it)
if [ -z "$accountKey" ] || [ -z "$organizationKey" ]
then
    logger "Error: --account_key and --organization_key are both required" >> $log_file
    logger "Account key: $masked and Org Key: $organizationKey were provided"
    echo
    usage
    exit 1
fi


logger "Provided Huntress key: $masked"
logger "Provided Organization Key: $organizationKey"

# --- PPPC gate: if we are doing system extension auto-install, wait for MDM PPPC/FDA approvals ---
if [ "$install_system_extension" = true ]; then
    logger "System extension install requested; validating PPPC readiness first..."
    if ! is_huntress_pppc_ready; then
  updateSplashScreen pending "Waiting for PPPC profile"
        logger "PPPC not ready yet. Exiting 0 so Intune can retry later."
        exit 0
    fi
    logger "PPPC is ready; continuing with Huntress install."
fi

updateSplashScreen wait "Downloading installer"
result=$(curl -w "%{http_code}" -L "https://huntress.io/script/darwin/$accountKey" -o "$install_script")

if [ $? != "0" ]; then
   logger "ERROR: Download failed with error: $result"
   exit 1
fi

if grep -Fq "$invalid_key" "$install_script"; then
   logger "ERROR: --account_key is invalid. You entered: $accountKey"
   exit 1
fi

if [ "$install_system_extension" = true ]; then
    install_result="$(/bin/bash "$install_script" -a "$accountKey" -o "$organizationKey" -t "$tags" -v --install_system_extension)"
else
    install_result="$(/bin/bash "$install_script" -a "$accountKey" -o "$organizationKey" -t "$tags" -v)"
fi

logger "=============== Begin Installer Logs ==============="

if [ $? != "0" ]; then
    logger "Installer Error: $install_result"
    exit 1
fi

logger "$install_result"
logger "=========== INSTALL FINISHED AT $dd ==============="
updateSplashScreen success "Installed"

exit 0
