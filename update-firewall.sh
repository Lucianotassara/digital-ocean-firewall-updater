#!/usr/bin/env bash
# Updates a DigitalOcean firewall so the given TCP ports only accept the current public IP.
# Requires: bash, curl, jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAST_IP_FILE="$SCRIPT_DIR/lastIp.txt"

usage() {
  cat <<'EOF'
Usage: update-firewall.sh [options]

  -p, --ports PORTS  Comma separated list of ports (may be repeated). Ignored if PORTS is set in .env
  -c, --cidr         Save IP as CIDR like xxx.xxx.xxx.0/24
  -f, --force        Force firewall update
  -a, --add          Add the new IP to the previously saved ones instead of overwriting
  -r, --remove       Remove IP addresses on selected ports (leaves only 127.0.0.1)
  -i, --ip IP        Use this IP instead of auto-detecting it
  -h, --help         Show this help
EOF
}

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ---- .env (parsed, not sourced; real environment variables win) ----
load_env() {
  local file="$SCRIPT_DIR/.env" line key val
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key#export }"; key="${key//[[:space:]]/}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    [ -z "${!key+x}" ] && export "$key=$val"
  done < "$file"
  return 0
}

# ---- args ----
ports_arg=""; cidr=false; force=false; add=false; remove=false; manual_ip=""

while [ $# -gt 0 ]; do
  case "$1" in
    -p=*|--ports=*) ports_arg+="${ports_arg:+,}${1#*=}" ;;
    -p|--ports)     [ $# -ge 2 ] || { warn "Missing value for $1"; exit 1; }; ports_arg+="${ports_arg:+,}$2"; shift ;;
    -i=*|--ip=*)    manual_ip="${1#*=}" ;;
    -i|--ip)        [ $# -ge 2 ] || { warn "Missing value for $1"; exit 1; }; manual_ip="$2"; shift ;;
    -c|--cidr)      cidr=true ;;
    -f|--force)     force=true ;;
    -a|--add)       add=true ;;
    -r|--remove)    remove=true ;;
    -h|--help)      usage; exit 0 ;;
    *) warn "Unknown option: $1"; usage >&2; exit 1 ;;
  esac
  shift
done

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { warn "Missing dependency: $cmd (try: sudo apt install $cmd)"; exit 1; }
done

load_env
: "${PERSONAL_ACCESS_TOKEN:?PERSONAL_ACCESS_TOKEN is not set (.env)}"
: "${FIREWALL_ID:?FIREWALL_ID is not set (.env)}"

ports_src="${PORTS:-$ports_arg}"
if [ -z "$ports_src" ]; then
  log "You should specify at least one port. Run with --help option to see available options"
  exit 1
fi
ports_json="$(printf '%s' "$ports_src" | tr -d ' ' | jq -R 'split(",") | map(select(length > 0))')"

# ---- helpers ----
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
to_cidr() { local IFS=.; local -a o=($1); printf '%s.%s.%s.0/24' "${o[0]}" "${o[1]}" "${o[2]}"; }

get_public_ip() {
  local url text
  for url in "https://api4.ipify.org?format=text" "https://ipv4.icanhazip.com" \
             "https://checkip.amazonaws.com" "https://ipv4.my-ip.io/ip"; do
    if text="$(curl -fsS --max-time 8 "$url" 2>/dev/null)"; then
      text="$(printf '%s' "$text" | tr -d '[:space:]')"
      if is_ipv4 "$text"; then
        log "Getting IP from $url: $text" >&2
        printf '%s' "$text"; return 0
      fi
    fi
    warn "Failed to get IP from $url"
  done
  return 1
}

do_api() { # method [body]
  local method="$1" body="${2:-}" out code
  local args=(-sS -X "$method" -w $'\n%{http_code}'
              -H "Content-Type: application/json"
              -H "Authorization: Bearer $PERSONAL_ACCESS_TOKEN")
  [ -n "$body" ] && args+=(--data "$body")
  out="$(curl "${args[@]}" "https://api.digitalocean.com/v2/firewalls/$FIREWALL_ID")" || return 1
  code="${out##*$'\n'}"; API_BODY="${out%$'\n'*}"
  [[ "$code" =~ ^2 ]] || { warn "DigitalOcean API returned HTTP $code: $API_BODY"; return 1; }
}

# ---- main ----
log "**** $(date) ****"

if [ -n "$manual_ip" ]; then
  new_ip="$manual_ip"
  is_ipv4 "$new_ip" || { warn "Invalid IPv4 address: $new_ip"; exit 1; }
  log "Using manually specified IP: $new_ip"
else
  new_ip="$(get_public_ip)" || { warn "Could not retrieve public IP, aborting."; exit 1; }
fi

saved_ip=""
[ -f "$LAST_IP_FILE" ] && saved_ip="$(tr -d '[:space:]' < "$LAST_IP_FILE")"
log "Saved IP Address: $saved_ip"

if ! $force && [ "$saved_ip" = "$new_ip" ]; then
  log "No IP changes"; exit 0
fi

raw_ip="$new_ip"
if $cidr; then
  if [ -n "$saved_ip" ] && is_ipv4 "$saved_ip" && [ "$(to_cidr "$new_ip")" = "$(to_cidr "$saved_ip")" ]; then
    log "IP has changed but not for CIDR notation"; exit 0
  fi
  new_ip="$(to_cidr "$new_ip")"
fi
log "IP has changed, starting firewall update"

log "Getting the firewall from DO API"
do_api GET || exit 1
log "Showing my firewall -> $API_BODY"

updated="$(printf '%s' "$API_BODY" | jq -c \
  --argjson ports "$ports_json" --arg ip "$new_ip" \
  --argjson clean "$remove" --argjson overwrite "$($add && echo false || echo true)" '
  def fix: if .protocol == "icmp" then del(.ports)                        # ICMP must not specify ports
           elif (.ports == null or .ports == "" or .ports == "0") then .ports = "all"
           else . end;
  .firewall
  | del(.id, .created_at, .pending_changes, .status)
  | .inbound_rules |= map(
      if .protocol == "tcp" and (.ports as $p | $ports | index($p)) then
        .sources.addresses = (
          if $clean then ["127.0.0.1"]
          elif $overwrite then [$ip]
          else ((.sources.addresses // []) + [$ip]) end)
      else . end)
  | .inbound_rules |= map(fix)
  | .outbound_rules |= map(fix)')"

log "Showing updated firewall -> $updated"

do_api PUT "$updated" || exit 1
log "Placing PUT request to DigitalOcean API. RESPONSE: $API_BODY"

printf '%s' "$raw_ip" > "$LAST_IP_FILE"
log "$raw_ip > lastIp.txt"
