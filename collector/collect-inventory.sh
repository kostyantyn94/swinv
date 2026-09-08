#!/usr/bin/env bash
# =====================================================================
#  SWInv collector for Linux and macOS  (payload contract v1.0, see docs/CONTRACT-collector.md)
#
#  Collects installed software "down to packages" from every package manager found on the host,
#  writes one UTF-8 JSON file and POSTs it to the n8n ingest webhook with a shared-secret header.
#  Same contract as the Windows collector, so both feed the same dictionaries.
#
#  Sources (auto-detected, each isolated: a failing source never aborts the run):
#    dpkg (Debian/Ubuntu)  rpm (RHEL/Fedora/SUSE)  apk (Alpine)  pacman (Arch)
#    snap  flatpak  brew / brew-cask (Homebrew)  macos-app (/Applications bundles)
#    pip  npm (global)  vscode (extensions)
#
#  Usage:
#    ./collect-inventory.sh                                  # collect + upload to http://localhost:5678
#    ./collect-inventory.sh --no-upload --out /tmp/inv.json  # only write the file
#    ./collect-inventory.sh --webhook-url http://n8n:5678/webhook/inventory/ingest --token <secret>
#    ./collect-inventory.sh --sources dpkg,snap,pip
#  Options: --webhook-url URL  --token SECRET (default: INVENTORY_WEBHOOK_TOKEN from ../.env)
#           --out FILE  --no-upload  --sources a,b,c  --quiet  -h|--help
#  Exit codes: 0 ok, 1 nothing collected, 2 upload failed (file is still written).
#  Requirements: bash 3.2+, coreutils, curl (upload only). No root needed.
# =====================================================================
set -u

COLLECTOR_VERSION="1.0.0"
SCHEMA_VERSION="1.0"
WEBHOOK_URL="http://localhost:5678/webhook/inventory/ingest"
TOKEN=""
OUT_FILE=""
NO_UPLOAD=0
QUIET=0
SOURCES=""

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() { sed -n '2,24p' "$0" | sed 's/^#  \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --webhook-url) WEBHOOK_URL="$2"; shift 2 ;;
    --token)       TOKEN="$2"; shift 2 ;;
    --out)         OUT_FILE="$2"; shift 2 ;;
    --no-upload)   NO_UPLOAD=1; shift ;;
    --sources)     SOURCES="$2"; shift 2 ;;
    --quiet)       QUIET=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

log()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# ---------------------------------------------------------------- helpers
now_ms() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  case "$ns" in
    *N*|"") echo $(( $(date +%s) * 1000 )) ;;
    *) echo $(( ns / 1000000 )) ;;
  esac
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
trim()  { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# JSON string literal (or null when empty); strips control characters
json_str() {
  local s="$1"
  if [ -z "$s" ]; then printf 'null'; return; fi
  s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/}
  printf '"%s"' "$s"
}
json_num()  { if [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi; }
json_bool() { if [ "$1" = "1" ] || [ "$1" = "true" ]; then printf 'true'; else printf 'false'; fi; }

uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then uuidgen | tr '[:upper:]' '[:lower:]'
  else od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'
  fi
}

PKG_TMP=$(mktemp "${TMPDIR:-/tmp}/swinv-pkgs.XXXXXX")
SRC_TMP=$(mktemp "${TMPDIR:-/tmp}/swinv-src.XXXXXX")
trap 'rm -f "$PKG_TMP" "$SRC_TMP"' EXIT

# Privacy / scope filter: regexes from exclude.txt + exclude.local.txt (next to this script), one per line,
# matched case-insensitively against "<name> | <publisher> | <install_location>". Matches are never collected.
EXCLUDE_RX=""
EXCLUDED=0
for f in "$SCRIPT_DIR/exclude.txt" "$SCRIPT_DIR/exclude.local.txt"; do
  [ -f "$f" ] || continue
  while IFS= read -r l || [ -n "$l" ]; do
    l=$(trim "${l%%$'\r'}"); case "$l" in ""|\#*) continue ;; esac
    EXCLUDE_RX="${EXCLUDE_RX:+$EXCLUDE_RX|}$l"
  done < "$f"
done

# add_pkg source source_key scope arch name version publisher install_date install_location size_kb is_system is_framework uninstall_string raw_json
add_pkg() {
  local src="$1" key="$2" scope="$3" arch="$4" name="$5" version="$6" publisher="$7" idate="$8" loc="$9"
  local size="${10}" issys="${11}" isfw="${12}" unins="${13}" raw="${14}"
  [ -z "$name" ] && return 1
  if [ -n "$EXCLUDE_RX" ] && printf '%s | %s | %s' "$name" "$publisher" "$loc" | grep -Eiq -- "$EXCLUDE_RX"; then EXCLUDED=$((EXCLUDED+1)); return 1; fi
  [ -z "$raw" ] && raw='{}'
  printf '%s\t{"source":%s,"source_key":%s,"scope":%s,"arch":%s,"name":%s,"version":%s,"publisher":%s,"install_date":%s,"install_location":%s,"size_kb":%s,"is_system_component":%s,"is_framework":%s,"uninstall_string":%s,"winget_id":null,"winget_source":null,"winget_available_version":null,"raw":%s}\n' \
    "$(lower "$src|$key")" "$(json_str "$src")" "$(json_str "$key")" "$(json_str "$scope")" "$(json_str "$arch")" \
    "$(json_str "$name")" "$(json_str "$version")" "$(json_str "$publisher")" "$(json_str "$idate")" "$(json_str "$loc")" \
    "$(json_num "$size")" "$(json_bool "$issys")" "$(json_bool "$isfw")" "$(json_str "$unins")" "$raw" >> "$PKG_TMP"
}

# record_source name ok count duration_ms error
record_source() {
  printf '{"name":%s,"ok":%s,"count":%s,"duration_ms":%s,"error":%s}\n' \
    "$(json_str "$1")" "$(json_bool "$2")" "$3" "$4" "$(json_str "$5")" >> "$SRC_TMP"
  if [ "$2" = "1" ]; then log "  [ok]   $(printf '%-11s %5s packages %7s ms' "$1" "$3" "$4")"
  else log "  [skip] $(printf '%-11s %s' "$1" "$5")"; fi
}

norm_arch() {
  case "$(lower "$1")" in
    x86_64|amd64) echo x64 ;; i386|i686|x86) echo x86 ;; aarch64|arm64) echo arm64 ;; armv7l|armhf|arm) echo arm ;;
    all|noarch|any|neutral|"") echo neutral ;; *) echo "$1" ;;
  esac
}

wants() { [ -z "$SOURCES" ] && return 0; case ",$SOURCES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- sources
collect_dpkg() {
  wants dpkg || return 0
  command -v dpkg-query >/dev/null 2>&1 || { record_source dpkg 0 0 0 "not installed"; return 0; }
  local t0 n=0 line pkg ver arch maint size status section email
  t0=$(now_ms)
  while IFS=$'\t' read -r pkg ver arch maint size status section; do
    case "$status" in *" installed") ;; *) continue ;; esac
    email=""; case "$maint" in *"<"*) email="${maint##*<}"; email="${email%>}"; maint="${maint%%<*}";; esac
    maint=$(trim "$maint")
    local issys=0
    case "$pkg" in lib*) issys=1 ;; esac
    case "$section" in libs|oldlibs|kernel|debug|*/libs|*/oldlibs) issys=1 ;; esac
    add_pkg dpkg "dpkg:$pkg:$arch" machine "$(norm_arch "$arch")" "$pkg" "$ver" "$maint" "" "" "$size" "$issys" 0 "" \
      "{\"section\":$(json_str "$section"),\"maintainer_email\":$(json_str "$email")}" && n=$((n+1))
  done < <(dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${Maintainer}\t${Installed-Size}\t${Status}\t${Section}\n' 2>/dev/null)
  record_source dpkg 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_rpm() {
  wants rpm || return 0
  command -v rpm >/dev/null 2>&1 || { record_source rpm 0 0 0 "not installed"; return 0; }
  command -v dpkg-query >/dev/null 2>&1 && { record_source rpm 0 0 0 "dpkg-based system"; return 0; }
  local t0 n=0 name ver arch vendor size itime group idate
  t0=$(now_ms)
  while IFS=$'\t' read -r name ver arch vendor size itime group; do
    [ "$vendor" = "(none)" ] && vendor=""
    idate=""; [ -n "$itime" ] && idate=$(date -d "@$itime" +%Y-%m-%d 2>/dev/null || date -r "$itime" +%Y-%m-%d 2>/dev/null)
    local issys=0; case "$name" in lib*|kernel*|glibc*|systemd*) issys=1 ;; esac
    add_pkg rpm "rpm:$name:$arch" machine "$(norm_arch "$arch")" "$name" "$ver" "$vendor" "$idate" "" "$(( ${size:-0} / 1024 ))" "$issys" 0 "" \
      "{\"group\":$(json_str "$group")}" && n=$((n+1))
  done < <(rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\t%{VENDOR}\t%{SIZE}\t%{INSTALLTIME}\t%{GROUP}\n' 2>/dev/null)
  record_source rpm 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_apk() {
  wants apk || return 0
  command -v apk >/dev/null 2>&1 || { record_source apk 0 0 0 "not installed"; return 0; }
  local t0 n=0 line nv arch origin name ver
  t0=$(now_ms)
  while read -r line; do
    # "name-1.2.3-r0 x86_64 {origin} (license) [installed]"
    nv=${line%% *}; arch=$(printf '%s' "$line" | awk '{print $2}'); origin=$(printf '%s' "$line" | sed -n 's/.*{\([^}]*\)}.*/\1/p')
    ver=$(printf '%s' "$nv" | sed -E 's/^.*-([^-]+-r[0-9]+)$/\1/'); name=${nv%-$ver}
    local issys=0; case "$name" in lib*|musl*|busybox*|alpine-*) issys=1 ;; esac
    add_pkg apk "apk:$name" machine "$(norm_arch "$arch")" "$name" "$ver" "Alpine Linux" "" "" "" "$issys" 0 "" "{\"origin\":$(json_str "$origin")}" && n=$((n+1))
  done < <(apk list -I 2>/dev/null)
  record_source apk 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_pacman() {
  wants pacman || return 0
  command -v pacman >/dev/null 2>&1 || { record_source pacman 0 0 0 "not installed"; return 0; }
  local t0 n=0 name ver
  t0=$(now_ms)
  while read -r name ver; do
    local issys=0; case "$name" in lib*|linux*|glibc*|systemd*) issys=1 ;; esac
    add_pkg pacman "pacman:$name" machine "$(norm_arch "$(uname -m)")" "$name" "$ver" "Arch Linux" "" "" "" "$issys" 0 "" "{}" && n=$((n+1))
  done < <(pacman -Q 2>/dev/null)
  record_source pacman 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_snap() {
  wants snap || return 0
  command -v snap >/dev/null 2>&1 || { record_source snap 0 0 0 "not installed"; return 0; }
  local t0 n=0 name ver rev tracking publisher notes out
  t0=$(now_ms)
  out=$(snap list --unicode=never --color=never 2>/dev/null) || { record_source snap 0 0 $(( $(now_ms) - t0 )) "snapd not running"; return 0; }
  while read -r name ver rev tracking publisher notes; do
    [ "$name" = "Name" ] && continue
    publisher=${publisher%\*\*}; publisher=${publisher%\*}
    local issys=0; case "$name" in core*|snapd|bare|gnome-*|gtk-common-themes|kf5-*|mesa-*) issys=1 ;; esac
    add_pkg snap "snap:$name" machine "$(norm_arch "$(uname -m)")" "$name" "$ver" "$publisher" "" "/snap/$name" "" "$issys" 0 "snap remove $name" \
      "{\"revision\":$(json_str "$rev"),\"tracking\":$(json_str "$tracking"),\"notes\":$(json_str "$notes")}" && n=$((n+1))
  done <<< "$out"
  record_source snap 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_flatpak() {
  wants flatpak || return 0
  command -v flatpak >/dev/null 2>&1 || { record_source flatpak 0 0 0 "not installed"; return 0; }
  local t0 n=0 app name ver origin inst
  t0=$(now_ms)
  while IFS=$'\t' read -r app name ver origin inst; do
    [ -z "$app" ] && continue
    local scope=machine; [ "$inst" = "user" ] && scope=user
    add_pkg flatpak "flatpak:$app" "$scope" "$(norm_arch "$(uname -m)")" "${name:-$app}" "$ver" "" "" "" "" 0 0 "flatpak uninstall $app" \
      "{\"application_id\":$(json_str "$app"),\"origin\":$(json_str "$origin")}" && n=$((n+1))
  done < <(flatpak list --app --columns=application,name,version,origin,installation 2>/dev/null)
  record_source flatpak 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_brew() {
  wants brew || return 0
  command -v brew >/dev/null 2>&1 || { record_source brew 0 0 0 "not installed"; return 0; }
  local t0 n=0 name vers prefix
  t0=$(now_ms); prefix=$(brew --prefix 2>/dev/null)
  while read -r name vers; do
    [ -z "$name" ] && continue
    add_pkg brew "brew:$name" user "$(norm_arch "$(uname -m)")" "$name" "${vers##* }" "Homebrew" "" "$prefix/opt/$name" "" 0 0 "brew uninstall $name" "{\"kind\":\"formula\",\"versions\":$(json_str "$vers")}" && n=$((n+1))
  done < <(brew list --formula --versions 2>/dev/null)
  record_source brew 1 "$n" $(( $(now_ms) - t0 )) ""
  wants brew-cask || return 0
  t0=$(now_ms); n=0
  while read -r name vers; do
    [ -z "$name" ] && continue
    add_pkg brew-cask "brew-cask:$name" user "$(norm_arch "$(uname -m)")" "$name" "${vers##* }" "" "" "" "" 0 0 "brew uninstall --cask $name" "{\"kind\":\"cask\"}" && n=$((n+1))
  done < <(brew list --cask --versions 2>/dev/null)
  record_source brew-cask 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_macos_apps() {
  wants macos-app || return 0
  [ "$(uname -s)" = "Darwin" ] || { record_source macos-app 0 0 0 "not macOS"; return 0; }
  local t0 n=0 app name ver bid dir scope
  t0=$(now_ms)
  for dir in /Applications /Applications/Utilities "$HOME/Applications" /System/Applications; do
    [ -d "$dir" ] || continue
    scope=machine; [ "$dir" = "$HOME/Applications" ] && scope=user
    for app in "$dir"/*.app; do
      [ -d "$app" ] || continue
      name=$(basename "$app" .app)
      ver=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
      bid=$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)
      local issys=0; case "$dir" in /System/Applications) issys=1 ;; esac
      add_pkg macos-app "macos-app:${bid:-$app}" "$scope" "$(norm_arch "$(uname -m)")" "$name" "$ver" "" "" "$app" "" "$issys" 0 "" "{\"bundle_id\":$(json_str "$bid")}" && n=$((n+1))
    done
  done
  record_source macos-app 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_pip() {
  wants pip || return 0
  local py="" t0 n=0 line name ver
  for c in python3 python pip3 pip; do command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }; done
  [ -z "$py" ] && { record_source pip 0 0 0 "not installed"; return 0; }
  t0=$(now_ms)
  case "$py" in python*) cmd="$py -m pip list --format=freeze" ;; *) cmd="$py list --format=freeze" ;; esac
  while read -r line; do
    case "$line" in *==*) name=${line%%==*}; ver=${line#*==} ;; *) continue ;; esac
    add_pkg pip "pip:$(lower "$name")" user "" "$name" "$ver" "" "" "" "" 0 0 "$py -m pip uninstall $name" "{}" && n=$((n+1))
  done < <($cmd 2>/dev/null)
  record_source pip 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_npm() {
  wants npm || return 0
  command -v npm >/dev/null 2>&1 || { record_source npm 0 0 0 "not installed"; return 0; }
  local t0 n=0 line spec name ver root
  t0=$(now_ms); root=$(npm root -g 2>/dev/null)
  while read -r line; do
    spec=${line##*:}; [ -z "$spec" ] && continue
    case "$spec" in *@*) name=${spec%@*}; ver=${spec##*@} ;; *) continue ;; esac
    [ -z "$name" ] && continue
    add_pkg npm "npm:$name" user "" "$name" "$ver" "" "" "$root/$name" "" 0 0 "npm uninstall -g $name" "{}" && n=$((n+1))
  done < <(npm ls -g --depth=0 --parseable --long 2>/dev/null | tail -n +2)
  record_source npm 1 "$n" $(( $(now_ms) - t0 )) ""
}

collect_vscode() {
  wants vscode || return 0
  local bin="" t0 n=0 line id ver
  for c in code code-insiders codium; do command -v "$c" >/dev/null 2>&1 && { bin="$c"; break; }; done
  [ -z "$bin" ] && { record_source vscode 0 0 0 "not installed"; return 0; }
  t0=$(now_ms)
  while read -r line; do
    id=${line%@*}; ver=${line##*@}; [ -z "$id" ] && continue
    add_pkg vscode "vscode:$(lower "$id")" user "" "${id#*.}" "$ver" "${id%%.*}" "" "" "" 0 0 "$bin --uninstall-extension $id" "{\"extension_id\":$(json_str "$id")}" && n=$((n+1))
  done < <($bin --list-extensions --show-versions 2>/dev/null)
  record_source vscode 1 "$n" $(( $(now_ms) - t0 )) ""
}

# ---------------------------------------------------------------- host
host_json() {
  local hn dom mid os_name os_ver os_build arch user manu model serial
  hn=$(hostname 2>/dev/null | cut -d. -f1); dom=$(hostname -d 2>/dev/null || true)
  if [ -r /etc/machine-id ]; then mid=$(cat /etc/machine-id)
  elif [ -r /var/lib/dbus/machine-id ]; then mid=$(cat /var/lib/dbus/machine-id)
  elif [ "$(uname -s)" = "Darwin" ]; then mid=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')
  fi
  [ -z "${mid:-}" ] && mid="host:$(lower "$hn")"
  if [ "$(uname -s)" = "Darwin" ]; then
    os_name="macOS $(sw_vers -productVersion 2>/dev/null)"; os_ver=$(sw_vers -productVersion 2>/dev/null); os_build=$(sw_vers -buildVersion 2>/dev/null)
    manu="Apple"; model=$(sysctl -n hw.model 2>/dev/null); serial=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/{print $4}')
  else
    os_name=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}"); os_ver=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")
    os_build=$(uname -r); manu=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null); model=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
  fi
  arch=$(uname -m); user=${USER:-$(id -un 2>/dev/null)}
  case "$(lower "${serial:-}")" in "default string"|"to be filled by o.e.m."|"system serial number"|none) serial="" ;; esac
  printf '{"hostname":%s,"domain":%s,"machine_id":%s,"os_name":%s,"os_version":%s,"os_build":%s,"os_arch":%s,"user":%s,"manufacturer":%s,"model":%s,"serial":%s}' \
    "$(json_str "$hn")" "$(json_str "$dom")" "$(json_str "$mid")" "$(json_str "$os_name")" "$(json_str "$os_ver")" "$(json_str "$os_build")" \
    "$(json_str "$arch")" "$(json_str "$user")" "$(json_str "$manu")" "$(json_str "$model")" "$(json_str "$serial")"
}

# ---------------------------------------------------------------- main
if [ -z "$TOKEN" ] && [ -f "$SCRIPT_DIR/../.env" ]; then
  TOKEN=$(grep -E '^INVENTORY_WEBHOOK_TOKEN=' "$SCRIPT_DIR/../.env" | head -1 | cut -d= -f2- | tr -d '\r')
fi
HOSTNAME_SHORT=$(hostname 2>/dev/null | cut -d. -f1)
[ -z "$OUT_FILE" ] && OUT_FILE="$SCRIPT_DIR/../samples/inventory-${HOSTNAME_SHORT}-$(date +%Y%m%d-%H%M%S).json"
RUN_ID=$(uuid)
T_START=$(now_ms)

log "collect-inventory.sh v$COLLECTOR_VERSION  host=$HOSTNAME_SHORT  os=$(uname -s)  user=${USER:-?}"
log "  run_id=$RUN_ID  sources=${SOURCES:-auto}"
collect_dpkg; collect_rpm; collect_apk; collect_pacman; collect_snap; collect_flatpak; collect_brew; collect_macos_apps; collect_pip; collect_npm; collect_vscode

TOTAL=$(wc -l < "$PKG_TMP" | tr -d ' ')
if [ "$TOTAL" -eq 0 ]; then warn "no packages collected"; exit 1; fi

mkdir -p "$(dirname "$OUT_FILE")"
{
  printf '{"schema_version":%s,"run_id":%s,"collected_at":%s,"collector":{"name":"collect-inventory.sh","version":%s},"host":%s,"sources":[' \
    "$(json_str "$SCHEMA_VERSION")" "$(json_str "$RUN_ID")" "$(json_str "$(date +%Y-%m-%dT%H:%M:%S%z)")" "$(json_str "$COLLECTOR_VERSION")" "$(host_json)"
  paste -sd, "$SRC_TMP"
  printf '],"packages":['
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -u "$PKG_TMP" | cut -f2- | paste -sd, -
  printf ']}\n'
} > "$OUT_FILE"

log ""
log "  packages: $TOTAL   output: $OUT_FILE ($(( $(wc -c < "$OUT_FILE") / 1024 )) KB)   runtime: $(( ($(now_ms) - T_START) / 1000 )) s"
[ "${SWINV_VERBOSE:-0}" = "1" ] && log "  filtered out by exclude lists: $EXCLUDED"

if [ "$NO_UPLOAD" -eq 1 ]; then log "  upload:   skipped (--no-upload)"; exit 0; fi
RESP=$(mktemp "${TMPDIR:-/tmp}/swinv-resp.XXXXXX")
if command -v curl >/dev/null 2>&1; then
  CODE=$(curl -sS -m 300 -o "$RESP" -w '%{http_code}' -X POST "$WEBHOOK_URL" \
          -H "Content-Type: application/json; charset=utf-8" -H "X-Inventory-Token: $TOKEN" --data-binary @"$OUT_FILE" 2>&1) || true
elif command -v python3 >/dev/null 2>&1; then
  # minimal images (python:*-slim) have python3 but no curl
  CODE=$(SWINV_URL="$WEBHOOK_URL" SWINV_TOKEN="$TOKEN" SWINV_FILE="$OUT_FILE" SWINV_RESP="$RESP" python3 - <<'PY'
import os, urllib.request, urllib.error
req = urllib.request.Request(os.environ['SWINV_URL'], data=open(os.environ['SWINV_FILE'], 'rb').read(), method='POST',
      headers={'Content-Type': 'application/json; charset=utf-8', 'X-Inventory-Token': os.environ['SWINV_TOKEN']})
try:
    r = urllib.request.urlopen(req, timeout=300); open(os.environ['SWINV_RESP'], 'wb').write(r.read()); print(r.status)
except urllib.error.HTTPError as e:
    open(os.environ['SWINV_RESP'], 'wb').write(e.read()); print(e.code)
except Exception as e:
    open(os.environ['SWINV_RESP'], 'w').write(str(e)); print('000')
PY
)
else
  warn "neither curl nor python3 found; file written, upload skipped"; rm -f "$RESP"; exit 2
fi
case "$CODE" in
  2*) log "  upload:   HTTP $CODE $(cat "$RESP")"; rm -f "$RESP"; exit 0 ;;
  *)  warn "upload failed: HTTP ${CODE:-?} $(cat "$RESP" 2>/dev/null | head -c 300)"; rm -f "$RESP"; exit 2 ;;
esac
