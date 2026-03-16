#!/bin/sh -e
# ESET PROTECT
# Copyright (c) 1992-2023 ESET, spol. s r.o. All Rights Reserved

files2del="$(mktemp -q /tmp/EraAgentOnlineInstaller.XXXXXXXX)"
dirs2del="$(mktemp -q /tmp/EraAgentOnlineInstaller.XXXXXXXX)"
echo "$dirs2del" >> "$files2del"
dirs2umount="$(mktemp -q /tmp/EraAgentOnlineInstaller.XXXXXXXX)"
echo "$dirs2umount" >> "$files2del"

# -----------------------------
# Intune PPPC/System Extension readiness gate (ESET)
# This prevents installer execution until the ESET PPPC/System Extension profile is installed.
# NOTE: We deliberately detect profile presence via 'profiles' output, not TCC.db rows.
# -----------------------------
PPPC_PROFILE_DISPLAYNAME="ESET Endpoint Security v8"
PPPC_PROFILE_IDENTIFIER="garybusey.1630DC74-1387-4975-8D3B-BB7F8F20F06E"
PPPC_TCC_PAYLOAD_IDENTIFIER="com.apple.TCC.configuration-profile-policy.7E2CC352-64F4-40C0-848A-1A4B5033E60B"
PPPC_REQUIRED_BUNDLEID_1="com.eset.endpoint"
PPPC_REQUIRED_BUNDLEID_2="com.eset.securityextension"  # may or may not appear depending on product/version

log_ts() {
  # ISO-ish timestamp
  /bin/date "+%Y-%m-%d %H:%M:%S"
}

log() {
  echo "$(log_ts) -- $*"
}

is_eset_pppc_ready() {
  # Returns 0 when the ESET PPPC / System Extension profile appears installed.
  # First, basic installed profiles list (works across macOS versions)
  if command -v /usr/bin/profiles >/dev/null 2>&1; then
    /usr/bin/profiles -P 2>/dev/null | /usr/bin/grep -i "eset" >/dev/null 2>&1 && return 0

    # Next, look for payload names/descriptions
    /usr/bin/profiles show -type configuration 2>/dev/null | /usr/bin/grep -i "ESET" >/dev/null 2>&1 && return 0
    /usr/bin/profiles show -type configuration 2>/dev/null | /usr/bin/grep -i "$PPPC_PROFILE_DISPLAYNAME" >/dev/null 2>&1 && return 0

    # Most reliable: parse installed profiles as XML and search for the PPPC payload + expected identifiers
    xml=$(/usr/bin/profiles -P -o stdout-xml 2>/dev/null)
    if [ -n "$xml" ]; then
      echo "$xml" | /usr/bin/grep -i "$PPPC_TCC_PAYLOAD_IDENTIFIER" >/dev/null 2>&1 && \
      echo "$xml" | /usr/bin/grep -i "SystemPolicyAllFiles" >/dev/null 2>&1 && \
      echo "$xml" | /usr/bin/grep -i "$PPPC_REQUIRED_BUNDLEID_1" >/dev/null 2>&1 && return 0

      # Fallback matches (some Intune-wrapped payloads don't preserve the original profile identifier)
      echo "$xml" | /usr/bin/grep -i "$PPPC_PROFILE_IDENTIFIER" >/dev/null 2>&1 && return 0
      echo "$xml" | /usr/bin/grep -i "$PPPC_PROFILE_DISPLAYNAME" >/dev/null 2>&1 && return 0
    fi
  fi

  return 1
}

# If PPPC isn't ready yet, exit 0 so Intune can retry later.
if ! is_eset_pppc_ready; then
  log "PPPC check: ESET PPPC/System Extension payload not detected yet (profiles)."
  log "PPPC not ready yet. Exiting 0 so Intune can retry later."
  exit 0
fi

log "PPPC check: ESET PPPC/System Extension payload detected. Proceeding with installer."


finalize()
{
  set +e

  echo "Cleaning up:"

  if test -f "$dirs2umount"
  then
    while read f
    do
      sudo -S hdiutil detach "$f"
    done < "$dirs2umount"
  fi

  if test -f "$dirs2del"
  then
    while read f
    do
      test -d "$f" && rm -rf "$f"
    done < "$dirs2del"
  fi

  if test -f "$files2del"
  then
    while read f
    do
      rm -f "$f"
    done < "$files2del"
    rm -f "$files2del"
  fi
}

trap 'finalize' HUP INT QUIT TERM EXIT

eraa_server_hostname="av1.keytelhosting.net"
eraa_server_port="2222"
eraa_server_company_name=""
eraa_peer_cert_b64="MIIK0gIBAzCCCo4GCSqGSIb3DQEHAaCCCn8Eggp7MIIKdzCCBhAGCSqGSIb3DQEHAaCCBgEEggX9MIIF+TCCBfUGCyqGSIb3DQEMCgECoIIE9jCCBPIwHAYKKoZIhvcNAQwBAzAOBAg80DmzMt5+NwICB9AEggTQ7LQJwo6htgO1Tiim4RhqYzwUMjz0nbk81sxaz3CPYVM0OIiXAHvQnEcOBQMlZOtPA5HLKDiq/jdasFBQJ7K+iVxM3TBnkgBnJypex9xE/q/vDde8R91x4Ze2Z5yFvSYYodikI+LighD2znaNBDPuDhz0qENzg1Bq7fzcc7Z6bQLVVOyvBj3L2iUXOxaJ85r+dvQtE6PW9UVaAK3GV0OXW6jTePjQ1NoiMAtxvZvnE77yKUfV43iMvVuyHOd30ifAVStPC+2XqPvOXItwpetadxrf6HV2KklmIb9sEdL/Ymr7FTTNjCeJ0PSdKlMuGD/LM/+j4IVXVvZGsdz+pqPHKNWsQxAfN1xnE40DOZ4jC18qyBn/KiLW+Zs5t4UMbsFJth8UJvak0R/2xjrJnzUeZRw/2g80FhSdwfIZSVQnCGEzU27RjYxnovLm8ZQoQVO4p879/Z7NNX1qtG8k/Vnt+UES2zQbqEyclY5RkU8lQqAFHN5x5WautWvRIGBZu+Fm5syDICnGl3a5U3Q/9aI5BVkjKOu+u5KGTScMHPHxfkELqv0sb1NPqEjVGgvPg9pXn4KFMherMSyyPBJNX7lyfH1DbPD8QSlEUStsFeS5DnBCqFqMp0aEtktYAmGgo1O6/vAUCkxgu5lJqkHbZOnqssCaMHh/XHNq9JMUmLMCXBpFr2gMA8IttUCDx+uuql3/uWv64/27e9cAfsIcsEYabYfo0tUOrtt+nUwBTrO6U55+bOtxjKg6avDaraXe4YpyvQpoEbSzz7EAXgvI32FWXZlui8KpphxaZHnJLwGPLRQGdCyvdxfS3u7huBR2X1cDD8Imzr3LcZrwQlSmVxrEk/Mqfuo/cNK9q5TFYRT5pclpWC0A3TtCLfybJ2RMDcsmPX+Ix4C80q/8dr2SAjoUWPs9Uw4YccOoBiQh0yZPFSOhJa6QvashqQdoW/lz55ly93SPyGJxPaNQgR3QSwgK9Y/8wA/JHXl9MOlwU00Mrp/SVFjpMFrJtC20ivFHwvJj6PlovT5qOoIkOGy2pJioFZHsHlOUlT6jbV6rdyaJLILGHld53xCqwYmnnPS0QYm3z89LsiAvJgtiFb0lEG0UETsFZQb9z9ffx6FPRO2S1qDviEsIWqqSbaE79yspKfLGVl1gfZx71FylFES+YlawLm5P66KnfI31lzc0/K3eroZYjunFH0GHkbFYmurNZwywhnvD9xDh0LQyYVR4n0jplDBtb9YhzA3K/18pVWlzmBZFr26b0nlB0EqnrVyZYYiYJ2SCeAn48e4OHSYZGwNlF3Lr7KQrL45s3EeTYxLEUR7H/U4vl0vCPyZyiWddsmhiFD/fzUohB4Pd7BdIuZyNJQ8YvU2pE8EH437a3Il1qsMwDopTwYe/Bxln1TxQ0cpHsvosoPGubDa2s2kuBp5Y9Uze6VJP02+dSdiX910D7QtzyARax9jxKaj42eEagcxC/v/awnzJPBQKxHrT6h4kUpRXBG72c1vtbEPWF4mcJHraqrZpo8xATveHT7XBmjNKzRADkamsNJwseMJ2+N7XjOwDWlKfONa4VV07vP9VkZoc0zK5xv1zFO0Itvvk2d64K/1QhJvOV+LA5JjVlDSyXsENSJPuQ/DhDk9JJJDdz48xgeswEwYJKoZIhvcNAQkVMQYEBAEAAAAwZwYJKoZIhvcNAQkUMVoeWABFAFMARQBUAC0AUgBBAC0AYgA0AGEANwA1AGMANQBmAC0AMABmADEAYQAtADQAOQBjAGMALQA4ADIAYgAyAC0AMAAxADEAOAAzADIAMgAyADYANwBiAGEwawYJKwYBBAGCNxEBMV4eXABNAGkAYwByAG8AcwBvAGYAdAAgAEUAbgBoAGEAbgBjAGUAZAAgAEMAcgB5AHAAdABvAGcAcgBhAHAAaABpAGMAIABQAHIAbwB2AGkAZABlAHIAIAB2ADEALgAwMIIEXwYJKoZIhvcNAQcGoIIEUDCCBEwCAQAwggRFBgkqhkiG9w0BBwEwHAYKKoZIhvcNAQwBAzAOBAjAZxYbi4La4gICB9CAggQYTkzUvUl/8qmAYauSQUV/A8P2b6SQ5CBwFlur5F2rE3S55rrEupSFcY1xT98wu9XvaVBmgEw6MTgWJTRq3aRgtReB/PteCStOddV7ncvtWdwa5VvBRgDp8cSnR1anCImnQYcnb4OU1fckYO0FaPqgD/6Pogkwl0TNusFv+T+GINzQw65fGfd1pjFZ/k+W0fAlEPiqyYoHV9SRsB2MJL/aLrXHe5j3i38CfEJ0BOinNJ872BSC/Aix5kATlZ4AJBVv3e74Yn9XQUlKK+SQh+Tg2xEJuu+uibNg8glI27s2kmrLde+qB0/flg2kYFDCz1oWbNgXNRhv2hJ2ZSKuIuvt3chIGDW+P7OPEWHJ6/S8gPxB4EB9y48OUvGhkKCEN3h7GLyjc8nPadVWgN7nT9chF69AJDt9VY1cL+B4tOJEkB5+mpmNQZJ2Y1VUDPkzpfYu0w4OVfKs1NLK6VatumSqcGyh0pttxAUUbRpIvc98qjDomnsR7FOgr7g31gJrzesBCOGWRhQyZls8QeMuNSC2DSPkPqoLYFMTNPfjxvDITGL7xdKhCJHKoK6FWf7x2uB+KTL5m9zt/2JQ1kAwO6m7HguN9xGuNzxhnWYy7RCMvAbfo8XGYy9PlzUpTFHk2XjGepC1nbk5PhVyMJDZifO4G81742wtphesUAP4IwyRuk36yqwMpxRDBQ9fgAeOt6MCA7xa1ZerTrv7k5ExYsexzgEvHYy+q1qIfecq0L5p7EAYWPc+AOpnUrAnEZagt0DoUWfL4fK3fSKUGyvAhBdmsR/NR4NJDwkzAaXQL1MDKuUXFKEld1PuZ6pCrCpBT2gP/bqldL6TrmoNjvExiXt9CfKK0i+/JIZiVZvZpdCJwzrvx7n6pctujA/r5Nj2sKyyDnPVgws7VBUV/Ttj/TijGliWVj5SbWZZTQuK5MtesvT5eo4D8X+jH2i+z7X4pnWrduGxTe/v/F7jOPM2lZlbnEp4ydJ1ryKRm2m4xeDXme5EXlImkUXLgAJkLji7tIVcWzoNmC+5pkuni3QZePuQdjoNgLpdXcdbVgCFUBLC1xdAbwfMs4egCNpaO7De3F32T3MXFyBucbo0YY/NxU2Z9a+SOizbPzyguQU5V5I0vjQUb2Wq/J0ILKoX4Duvt5AwehBanNX0EgX84rP5iX1IweqgLdDtSdcpMWOOAkcAq8Kic0KqFUgSjl9FPYx2oez79LarcxApUBV4v38ZmZ3t5FmduIuq/ve+1uLeD0El1f5CHOqD3QKp9l5rySVD5K5MBDFACv1w0fBepS2k4u0bEWa7Imdb7VAukegoTl3wSQ8n6dP1AYYvSU5JZrTDqFh4jmYmSY5h6wlWF4G2ivZVgqV7LIkLPffrzeou+W3CD8+KhGUQ2ULqPDA7MB8wBwYFKw4DAhoEFGUoAE1jN2H1dzszj0c2Q6ZQpUNlBBTjeHpNJLTr+D/a1htCAxLjTe9jfQICB9AAAAAAAAAAAA=="
eraa_peer_cert_pwd=""
eraa_ca_cert_b64="MIIEJzCCAo+gAwIBAgIQGi4PVBYocIhF15iIiFVraDANBgkqhkiG9w0BAQsFADAsMSowKAYDVQQDEyFFU01DIENlcnRpZmljYXRpb24gYXV0aG9yaXR5IDIwMjQwHhcNMjQwMjI2MDUwMDAwWhcNMzQwMjI3MDQ1OTU5WjAsMSowKAYDVQQDEyFFU01DIENlcnRpZmljYXRpb24gYXV0aG9yaXR5IDIwMjQwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGKAoIBgQDGEQ3AinnsY14lrWnLy8fLmfpu/jqdt8Ac/5ZROWE0+TsZJpurfuSiFIpYv5hxUfSAI0YXgLn09FINgbIWTznyqdkAVt8aD551IO2TG0AIhRtuJsWP4FiwvH2IH8JFaB89uvcvhGWa5axQ5kAnRXKdwEqjm68YSR5deTQsgZYH/b4QcHpVraZZkEUmDoBxW0eV/YbM0nVVt8y3M5dCmFB+rt38P34wQCvspUumNAP/M5zLxTOLgECw8H+CqmmPYLeNZw+JXn/dwhtN30//mL82K6ezqUPP1At4xtqmmA+lpZ4DlskpFCNaH0DZxLHsBtcr4xHN0yY1i1Bwz8p4ykJP+qXRRcOKlpxnSrjOuzGo5bWDvLqDK1h5eRpDbCoTmOqiDsbMQFlsfGWAa4nWsZyuW9+VSEWGAHX/VBwkB/nvYkCfkccjP8YzSmH40s/1Q792xWkp5kWhISkhtZeBaf6HpLTX1BIm0uRD7Box16n8b5e7slUykXawbzhapk7DG1kCAwEAAaNFMEMwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwHQYDVR0OBBYEFEFXh2blInmgBfudOpQy98FlAuBMMA0GCSqGSIb3DQEBCwUAA4IBgQAq+7VykHp1T+zxVULTcfvM/v9u86nPdi6Zeyi/zB4p3FI9OrVibn6KxUo+W57lz7f/9Koi0e7WxUxouWygjL66XuWHwCvMTnSUxgVvD3ENIHwOLGDmzy//HauDuxNPtN2Qdgudm8T++cTHyqtwvkxdofkm5oWxdqR+K3BJnfL0SainyyP3xlnZcNMuKXaUfK4Zf6Cdrt5wgVUdSZRhlk0IV4XKHSgawDuAPYT8F8sa+6g/osnleKm6vePXSz6msJFt+Lokz28wtaiNOH8dxiUANInBPWIQx1Eyl45dz3QFsCdGjqyTYGIMRnb37rW9W7HssWRyYXeE74NmLLtwSrrli4KxKqD6JsmD8M4S3SaFdBaGAQqVEo+lCp5uaPwMvXoEn2YWdG6tXThn01brrjXwN8aO5YZGbyySok4TEN2DI+9IsYkxna098asbqyVw8B2MeaSZxyavva1wCTEE+5MbJRQpYFxc+PRRxWW4CWvZqDT4RYqhJYXdUeZbOUZhses="
eraa_product_uuid=""
eraa_initial_sg_token="YTI2Nzc3YTEtY2U1Mi00YjBjLWE3MWItM2I2NTA5ZWM2M2U4tm5XAPR9R6msbKYXSOTjOExHTSnoDUF5ijC6OzY8XZfFae2As9b9EFAr7ERlvSlZz3id1w=="
eraa_enable_telemetry="0"
eraa_policy_data="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"

eraa_http_proxy_use="0"
eraa_http_proxy_hostname=""
eraa_http_proxy_port=""
eraa_http_proxy_user=""
eraa_http_proxy_password=""

arch=$(uname -m)
eraa_installer_url="http://repository.eset.com/v1/com/eset/apps/business/era/agent/v11/11.0.503.0/agent_macosx_x86_64.dmg"
eraa_installer_checksum="7dc33adb4347c7c9b1e79db007b7b57f8e4d72183aafe739e5aa34b72ae0f817"
if $(echo "$arch" | grep -E "^(x86_64|amd64)$" 2>&1 > /dev/null)
then
    eraa_installer_url="http://repository.eset.com/v1/com/eset/apps/business/era/agent/v11/11.0.503.0/agent_macosx_x86_64.dmg"
    eraa_installer_checksum="7dc33adb4347c7c9b1e79db007b7b57f8e4d72183aafe739e5aa34b72ae0f817"
elif $(echo "$arch" | grep -E "^(arm64)$" 2>&1 > /dev/null)
then
    eraa_installer_url="http://repository.eset.com/v1/com/eset/apps/business/era/agent/v11/11.0.503.0/agent_macosx_x86_64.dmg"
    eraa_installer_checksum="7dc33adb4347c7c9b1e79db007b7b57f8e4d72183aafe739e5aa34b72ae0f817"
    if test -z $eraa_installer_url
    then
        eraa_installer_url="http://repository.eset.com/v1/com/eset/apps/business/era/agent/v11/11.0.503.0/agent_macosx_x86_64.dmg"
        eraa_installer_checksum="7dc33adb4347c7c9b1e79db007b7b57f8e4d72183aafe739e5aa34b72ae0f817"
    fi
fi

echo "ESET Management Agent live installer script. Copyright © 1992-2023 ESET, spol. s r.o. - All rights reserved."

if test ! -z $eraa_server_company_name
then
  echo " * CompanyName: $eraa_server_company_name"
fi
echo " * Hostname: $eraa_server_hostname"
echo " * Port: $eraa_server_port"
echo " * Installer: $eraa_installer_url"
echo

if test -z $eraa_installer_url
then
  echo "No installer available for '$arch' arhitecture."
  exit 1
fi

local_params_file="/tmp/postflight.plist"
echo "$local_params_file" >> "$files2del"

echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" >> "$local_params_file"
echo "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" >> "$local_params_file"
echo "<plist version=\"1.0\">" >> "$local_params_file"
echo "<dict>" >> "$local_params_file"

echo "  <key>Hostname</key><string>$eraa_server_hostname</string>" >> "$local_params_file"
echo "  <key>SendTelemetry</key><string>$eraa_enable_telemetry</string>" >> "$local_params_file"

echo "  <key>Port</key><string>$eraa_server_port</string>" >> "$local_params_file"

if test -n "$eraa_peer_cert_pwd"
then
  echo "  <key>PeerCertPassword</key><string>$eraa_peer_cert_pwd</string>" >> "$local_params_file"
  echo "  <key>PeerCertPasswordIsBase64</key><string>yes</string>" >> "$local_params_file"
fi

echo "  <key>PeerCertContent</key><string>$eraa_peer_cert_b64</string>" >> "$local_params_file"


if test -n "$eraa_ca_cert_b64"
then
  echo "  <key>CertAuthContent</key><string>$eraa_ca_cert_b64</string>" >> "$local_params_file"
fi
if test -n "$eraa_product_uuid"
then
  echo "  <key>ProductGuid</key><string>$eraa_product_uuid</string>" >> "$local_params_file"
fi
if test -n "$eraa_initial_sg_token"
then
  echo "  <key>InitialStaticGroup</key><string>$eraa_initial_sg_token</string>" >> "$local_params_file"
fi
if test -n "$eraa_policy_data"
then

  echo "  <key>CustomPolicy</key><string>$eraa_policy_data</string>" >> "$local_params_file"
fi

if test "$eraa_http_proxy_use" = "1"
then
  echo "  <key>UseProxy</key><string>$eraa_http_proxy_use</string>" >> "$local_params_file"
  echo "  <key>ProxyHostname</key><string>$eraa_http_proxy_hostname</string>" >> "$local_params_file"
  echo "  <key>ProxyPort</key><string>$eraa_http_proxy_port</string>" >> "$local_params_file"
  echo "  <key>ProxyUsername</key><string>$eraa_http_proxy_user</string>" >> "$local_params_file"
  echo "  <key>ProxyPassword</key><string>$eraa_http_proxy_password</string>" >> "$local_params_file"
fi

echo "</dict>" >> "$local_params_file"
echo "</plist>" >> "$local_params_file"

local_installer="$(dirname $0)"/"$(basename $eraa_installer_url)"

if $(echo "$eraa_installer_checksum  $local_installer" | shasum -a 256 -c 2> /dev/null > /dev/null)
then
    echo "Verified local installer was found: '$local_installer'"
else
    local_installer=""

    local_installer_dir="$(mktemp -q -d /tmp/EraAgentOnlineInstaller.XXXXXXXX)"
    echo "Downloading installer image '$eraa_installer_url':"

    eraa_http_proxy_value=""
    if test -n "$eraa_http_proxy_value"
    then
      export use_proxy=yes
      export http_proxy="$eraa_http_proxy_value"
      cd "$local_installer_dir" && { curl --fail --connect-timeout 300 --insecure -O -J "$eraa_installer_url" || curl --fail --connect-timeout 300 --noproxy "*" --insecure -O -J "$eraa_installer_url" ; cd - > /dev/null ; } && echo "$local_installer_dir" >> "$dirs2del"
    else
      cd "$local_installer_dir" && { curl --fail --connect-timeout 300 --insecure -O -J "$eraa_installer_url" ; cd - > /dev/null ; } && echo "$local_installer_dir" >> "$dirs2del"
    fi

    installer_filename="$(ls $local_installer_dir)"

    if [ "$installer_filename" ];
    then
        local_installer="$local_installer_dir"/"$installer_filename" && echo "$local_installer" >> "$files2del"
    fi

    if test ! -s "$local_installer"
    then
       echo "Failed to download installer file"
       exit 2
    fi

    /bin/echo -n "Checking integrity of downloaded package " && echo "$eraa_installer_checksum  $local_installer" | shasum -a 256 -c
fi

if $(echo "$local_installer" | grep -E "\.dmg$" 2>&1 > /dev/null)
then
    local_mount="$(mktemp -q -d /tmp/EraAgentOnlineInstaller.XXXXXXXX)" && echo "$local_mount" | tee "$dirs2del" >> "$dirs2umount"
    echo "Mounting image '$local_installer':" && sudo -S hdiutil attach "$local_installer" -mountpoint "$local_mount" -nobrowse

    local_pkg="$(ls "$local_mount" | grep "\.pkg$" | head -n 1)"

    echo "Installing package '$local_mount/$local_pkg':" && sudo -S installer -pkg "$local_mount/$local_pkg" -target /
elif $(echo "$local_installer" | grep -E "\.pkg$" 2>&1 > /dev/null)
then
    echo "Installing package '$local_installer':" && sudo -S installer -pkg "$local_installer" -target /
else
    echo "Installing package '$local_installer' has unsupported package type"
fi
