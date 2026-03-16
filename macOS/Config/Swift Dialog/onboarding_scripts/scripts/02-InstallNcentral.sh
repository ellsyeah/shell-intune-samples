#!/bin/bash
# N-central macOS Agent Bootstrap (dynamic registration token)
#
# Mirrors the logic of N-CentralAgentBootstrap.ps1:
#   1) Authenticate JWT -> access token
#   2) Resolve CUSTOMER orgUnitId by customer name
#   3) Fetch registration token for that customer
#   4) Download (or use local) Mac Agent installer (.pkg)
#   5) Write /tmp/ncentral_silent_install.params
#   6) Run macOS installer
#
# Requirements: curl, python3 (for JSON parsing). No jq needed.

set -euo pipefail

# -------------------- Defaults --------------------
BASE_URL="https://n.keytelhosting.net"
JWT="eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJTb2xhcndpbmRzIE1TUCBOLWNlbnRyYWwiLCJ1c2VyaWQiOjE3NzIwNTY3NjAsImlhdCI6MTc2ODQyNTg1OH0.XtFxFB2tHwfoqsKr4RGgOyVsv_Aga1rjNOBdx8Vnkbk"
CUSTOMER_NAME="GoKeyless"
CUSTOMER_ID_OVERRIDE=""
# Optional: if your environment needs the *hashed* customer name (some N-central scripts do)
CUSTOMER_NAME_VALUE_OVERRIDE=""  # what gets written to NC_IVPRM_NAME

SERVER_HOST_OVERRIDE=""          # if empty, derived from BASE_URL
PROTOCOL="https"
PORT="443"
PROXY=""
USING_URLS_LIST="false"
SERVERS_URLS=""                  # only used if USING_URLS_LIST=true

# Installer controls
INSTALLER_PATH=""                # if set, use this file instead of downloading
DOWNLOAD_LATEST="true"           # download latest pkg from server by default
# SIS fallback (from the provided "386" script)
SIS_FALLBACK_URL="https://sis.n-able.com/GenericFiles/NcentralMacAgent/1.13.2.0/Install_N-central_Agent_v1.13.2.656.pkg"

LOG_DIR="/Library/Logs/N-central Agent"
LOG_FILE="$LOG_DIR/nagent.bootstrap.log"
PARAMS_FILE="/tmp/ncentral_silent_install.params"
TMP_INSTALLER="/tmp/Install_N-central_Agent.pkg"

# Exit codes aligned with N-able sample scripts
EXIT_ERROR_INVALID_PARAMETERS=1
EXIT_ERROR_NO_INSTALLER=2
EXIT_ERROR_NO_SUDO=3
EXIT_ERROR_AGENT_ALREADY_INSTALLED=5

appname="N-central Agent"

updateSplashScreen() {
  if [ -e "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog" ]; then
    log INFO "Updating Swift Dialog monitor for ${appname} to [$1] - $2"
    echo "listitem: title: ${appname}, status: $1, statustext: $2" >> /var/tmp/dialog.log
  fi
}

trap 'updateSplashScreen fail "Failed"' ERR


# -------------------- Helpers --------------------
usage() {
  cat <<USAGE
Usage:
  sudo $0 --base-url https://n.keytelhosting.net --jwt <JWT> --customer-name "Customer Display Name" [options]

Required:
  --base-url              N-central base URL (e.g. https://n.keytelhosting.net)
  --jwt                   JWT used with /api/auth/authenticate (Authorization: Bearer <JWT>)
  --customer-name         Customer/site name as shown in N-central (used to locate org unit)

Optional:
  --customer-id           Override customerId/orgUnitId (skips org-unit lookup)
  --customer-name-value   Override value written to NC_IVPRM_NAME (use if your installer expects a hash)
  --server-host           Override server hostname written to params (default: derived from --base-url)
  --protocol              Default: https
  --port                  Default: 443
  --proxy                 Proxy string written to NC_IVPRM_PROXY (default: empty)
  --using-urls-list       true|false (default: false)
  --servers-urls          When using urls list: e.g. "https://n.keytelhosting.net:443"

Installer options:
  --installer             Use a local .pkg instead of downloading
  --no-download           Do not download; requires --installer
  --sis-fallback-url      Override SIS fallback URL

USAGE
}

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %T')"
  mkdir -p "$LOG_DIR" || true
  echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE" >/dev/null
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo $0 ..." >&2
    exit "$EXIT_ERROR_NO_SUDO"
  fi
}

json_get() {
  # json_get '<json>' 'python expression that returns a string or None'
  local json="$1"
  local expr="$2"
  python3 - <<PY
import json,sys
j=json.loads(sys.stdin.read())
val=($expr)
if val is None:
  sys.exit(2)
print(val)
PY
}

curl_json() {
  # curl_json METHOD URL AUTH_HEADER_JSONDATA(optional)
  local method="$1"; shift
  local url="$1"; shift
  local auth="$1"; shift
  local data="${1:-}"

  if [ -n "$data" ]; then
    curl -fsS -X "$method" "$url" -H "Authorization: Bearer $auth" -H "Content-Type: application/json" -d "$data"
  else
    curl -fsS -X "$method" "$url" -H "Authorization: Bearer $auth"
  fi
}

agent_already_installed() {
  if [ -f "/Library/N-central Agent/nagent" ] || [ -d "/Applications/Mac_Agent.app" ]; then
    return 0
  fi
  return 1
}

# -------------------- Args --------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2;;
    --jwt) JWT="$2"; shift 2;;
    --customer-name) CUSTOMER_NAME="$2"; shift 2;;

    --customer-id) CUSTOMER_ID_OVERRIDE="$2"; shift 2;;
    --customer-name-value) CUSTOMER_NAME_VALUE_OVERRIDE="$2"; shift 2;;

    --server-host) SERVER_HOST_OVERRIDE="$2"; shift 2;;
    --protocol) PROTOCOL="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --proxy) PROXY="$2"; shift 2;;

    --using-urls-list) USING_URLS_LIST="$2"; shift 2;;
    --servers-urls) SERVERS_URLS="$2"; shift 2;;

    --installer) INSTALLER_PATH="$2"; shift 2;;
    --no-download) DOWNLOAD_LATEST="false"; shift;;
    --sis-fallback-url) SIS_FALLBACK_URL="$2"; shift 2;;

    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage; exit "$EXIT_ERROR_INVALID_PARAMETERS";;
  esac
done

# -------------------- Validate --------------------
require_root

if [ -z "$BASE_URL" ] || [ -z "$JWT" ] || [ -z "$CUSTOMER_NAME" ]; then
  echo "Missing required argument(s)." >&2
  usage
  exit "$EXIT_ERROR_INVALID_PARAMETERS"
fi

# Normalize BaseUrl (strip trailing slash)
BASE_URL="${BASE_URL%/}"

# Derive server host if not overridden
if [ -n "$SERVER_HOST_OVERRIDE" ]; then
  SERVER_HOST="$SERVER_HOST_OVERRIDE"
else
  # Extract host from URL (works for https://host:port)
  # Extract host from URL (works for https://host:port)
  if command -v /usr/bin/python3 >/dev/null 2>&1; then
    SERVER_HOST="$(/usr/bin/python3 -c 'import sys,urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); print(u.hostname or "")' "$BASE_URL")"
  elif command -v python3 >/dev/null 2>&1; then
    SERVER_HOST="$(python3 -c 'import sys,urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); print(u.hostname or "")' "$BASE_URL")"
  else
    # Fallback: strip protocol/path/port without python
    SERVER_HOST="$(printf "%s" "$BASE_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s#:.*$##')"
  fi
fi

if [ -z "$SERVER_HOST" ]; then
  log ERROR "Could not derive server hostname from BASE_URL='$BASE_URL'. Use --server-host."
  exit "$EXIT_ERROR_INVALID_PARAMETERS"
fi

log INFO "=== N-central macOS Agent Bootstrap starting ==="
updateSplashScreen wait "Starting"
log INFO "BaseUrl: $BASE_URL"
log INFO "CustomerName (lookup): $CUSTOMER_NAME"
log INFO "ServerHost (params): $SERVER_HOST"
log INFO "Protocol/Port: $PROTOCOL/$PORT"

if agent_already_installed; then
  log WARNING "Agent appears already installed. Exiting successfully (no action)."
  updateSplashScreen success "Installed"
exit 0
fi

# -------------------- API: JWT -> access token --------------------
log INFO "Authenticating: POST $BASE_URL/api/auth/authenticate"
updateSplashScreen wait "Authenticating"
AUTH_JSON="$(curl -fsS -X POST "$BASE_URL/api/auth/authenticate" -H "Authorization: Bearer $JWT")" || {
  log ERROR "Authentication call failed. Check BaseUrl/JWT."; exit "$EXIT_ERROR_INVALID_PARAMETERS"; }

ACCESS_TOKEN="$(json_get "$AUTH_JSON" "j.get('tokens',{}).get('access',{}).get('token')")" || {
  log ERROR "Access token missing from authenticate response."; exit "$EXIT_ERROR_INVALID_PARAMETERS"; }

log INFO "Access token acquired (len=${#ACCESS_TOKEN})."

# -------------------- API: resolve customerId --------------------
if [ -n "$CUSTOMER_ID_OVERRIDE" ]; then
  CUSTOMER_ID="$CUSTOMER_ID_OVERRIDE"
  log INFO "Using overridden customerId: $CUSTOMER_ID"
else
  log INFO "OrgUnits: GET $BASE_URL/api/org-units?pageNumber=1&pageSize=200"
  ORGS_JSON="$(curl_json GET "$BASE_URL/api/org-units?pageNumber=1&pageSize=200" "$ACCESS_TOKEN")" || {
    log ERROR "Failed to fetch org-units."; exit "$EXIT_ERROR_INVALID_PARAMETERS"; }

  CUSTOMER_ID="$(python3 - <<PY
import json,sys
j=json.loads(sys.stdin.read())
name=sys.argv[1]
items=j.get('data') or []
# exact match first
for it in items:
  if it.get('orgUnitType')=='CUSTOMER' and it.get('orgUnitName')==name:
    print(it.get('orgUnitId',''))
    raise SystemExit
# contains match
lname=name.lower()
for it in items:
  if it.get('orgUnitType')=='CUSTOMER' and lname in (it.get('orgUnitName','').lower()):
    print(it.get('orgUnitId',''))
    raise SystemExit
print('')
PY
"$CUSTOMER_NAME" <<<"$ORGS_JSON")"

  if [ -z "$CUSTOMER_ID" ]; then
    log ERROR "Customer not found in org-units list. CustomerName='$CUSTOMER_NAME'"
    exit "$EXIT_ERROR_INVALID_PARAMETERS"
  fi
  log INFO "Resolved customerId/orgUnitId: $CUSTOMER_ID"
fi

# -------------------- API: registration token --------------------
log INFO "Registration token: GET $BASE_URL/api/customers/$CUSTOMER_ID/registration-token"
RT_JSON="$(curl_json GET "$BASE_URL/api/customers/$CUSTOMER_ID/registration-token" "$ACCESS_TOKEN")" || {
  log ERROR "Failed to fetch registration token."; exit "$EXIT_ERROR_INVALID_PARAMETERS"; }

REG_TOKEN="$(json_get "$RT_JSON" "j.get('data',{}).get('registrationToken')")" || {
  log ERROR "registrationToken missing from response."; exit "$EXIT_ERROR_INVALID_PARAMETERS"; }

REG_EXPIRY=""
REG_EXPIRY="$(python3 - <<PY
import json,sys
j=json.loads(sys.stdin.read())
print(j.get('data',{}).get('registrationTokenExpiryDate',''))
PY
<<<"$RT_JSON" || true)"

log INFO "Registration token acquired (len=${#REG_TOKEN})."
if [ -n "$REG_EXPIRY" ]; then
  log INFO "Registration token expires: $REG_EXPIRY"
fi

# Decide what to write into NC_IVPRM_NAME
if [ -n "$CUSTOMER_NAME_VALUE_OVERRIDE" ]; then
  CUSTOMER_NAME_VALUE="$CUSTOMER_NAME_VALUE_OVERRIDE"
else
  CUSTOMER_NAME_VALUE="$CUSTOMER_NAME"
fi

# -------------------- Installer acquisition --------------------
if [ -n "$INSTALLER_PATH" ]; then
  if [ ! -f "$INSTALLER_PATH" ]; then
    log ERROR "Installer not found: $INSTALLER_PATH"
    exit "$EXIT_ERROR_NO_INSTALLER"
  fi
  PARAM_INSTALLER="$INSTALLER_PATH"
  log INFO "Using local installer: $PARAM_INSTALLER"
else
  if [ "$DOWNLOAD_LATEST" != "true" ]; then
    log ERROR "--no-download was set but no --installer was provided."
    exit "$EXIT_ERROR_NO_INSTALLER"
  fi

  DOWNLOAD_URL="$PROTOCOL://$SERVER_HOST/download/latest/macosx/N-central/Install_N-central_Agent.pkg"
  log INFO "Downloading installer: $DOWNLOAD_URL"
  if ! curl -fsSL -o "$TMP_INSTALLER" "$DOWNLOAD_URL"; then
    log WARNING "Primary download failed; trying SIS fallback: $SIS_FALLBACK_URL"
    if ! curl -fsSL -o "$TMP_INSTALLER" "$SIS_FALLBACK_URL"; then
      log ERROR "Failed to download installer from server and SIS."
      exit "$EXIT_ERROR_NO_INSTALLER"
    fi
  fi
  PARAM_INSTALLER="$TMP_INSTALLER"
fi

# Basic sanity check
if [ ! -s "$PARAM_INSTALLER" ]; then
  log ERROR "Installer file is empty or missing: $PARAM_INSTALLER"
  exit "$EXIT_ERROR_NO_INSTALLER"
fi

# -------------------- Write params file --------------------
rm -f "$PARAMS_FILE"

{
  echo "NC_IVPRM_TOKEN=\"$REG_TOKEN\""
  echo "NC_IVPRM_PROXY=\"$PROXY\""

  if [ "$USING_URLS_LIST" = "true" ]; then
    if [ -z "$SERVERS_URLS" ]; then
      # default to base URL with port
      SERVERS_URLS="$PROTOCOL://$SERVER_HOST:$PORT"
    fi
    echo "NC_IVPRM_SERVERS_URLS=\"$SERVERS_URLS\""
  else
    echo "NC_IVPRM_SERVER=\"$SERVER_HOST\""
    echo "NC_IVPRM_PORT=\"$PORT\""
    echo "NC_IVPRM_PROTOCOL=\"$PROTOCOL\""
  fi

  echo "NC_IVPRM_ID=\"$CUSTOMER_ID\""
  echo "NC_IVPRM_NAME=\"$CUSTOMER_NAME_VALUE\""
} >> "$PARAMS_FILE"

chmod 600 "$PARAMS_FILE" || true
log INFO "Installer configured at '$PARAMS_FILE'"

# -------------------- Install --------------------
log INFO "Installing: $PARAM_INSTALLER"

# Capture installer output to log for troubleshooting
if installer -pkg "$PARAM_INSTALLER" -target / >>"$LOG_FILE" 2>&1; then
  log INFO "Install SUCCESS."
  exit 0
else
  rc=$?
  log ERROR "Install FAILED with exit code $rc. See $LOG_FILE"
  exit $rc
fi
