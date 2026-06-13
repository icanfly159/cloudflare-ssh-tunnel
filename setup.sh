#!/usr/bin/env bash
#
# Cloudflare SSH Tunnel - automated setup
#
# Exposes this machine's SSH over a Cloudflare Tunnel, either:
#   - Browser mode  : log in to SSH from a web browser (Cloudflare Access)
#   - Terminal mode : classic `ssh` client through the tunnel
#
# Secrets you enter are saved to ./tunnel.env (chmod 600, gitignored).
# Safe to re-run: existing tunnel / DNS record / Access app are reused.
#
set -euo pipefail

CF_API="https://api.cloudflare.com/client/v4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/tunnel.env"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

info() { echo "${CYAN}==>${RESET} $*"; }
ok()   { echo "${GREEN}  ✔${RESET} $*"; }
warn() { echo "${YELLOW}  !${RESET} $*"; }
die()  { echo "${RED}  ✘ $*${RESET}" >&2; exit 1; }
step() { echo; echo "${BOLD}${CYAN}── $* ──${RESET}"; }

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# ---------------------------------------------------------------- helpers ---

cf_api() { # cf_api METHOD PATH [JSON_BODY]
  local method=$1 path=$2 body=${3:-}
  if [[ -n $body ]]; then
    curl -sS -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$body"
  else
    curl -sS -X "$method" "$CF_API$path" \
      -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

require_success() { # require_success RESPONSE "error message"
  local resp=$1 msg=$2
  if [[ "$(jq -r '.success // false' <<<"$resp")" != "true" ]]; then
    die "$msg: $(jq -c '.errors // .' <<<"$resp")"
  fi
}

ask() { # ask VAR "Prompt text" [default] [secret]
  local var=$1 prompt=$2 default=${3:-} secret=${4:-}
  local value=""
  while [[ -z $value ]]; do
    if [[ -n $default ]]; then
      printf "%s [%s]: " "$prompt" "$default"
    else
      printf "%s: " "$prompt"
    fi
    if [[ $secret == "secret" ]]; then
      read -rs value; echo
    else
      read -r value
    fi
    [[ -z $value && -n $default ]] && value=$default
    [[ -z $value ]] && warn "This value is required."
  done
  printf -v "$var" '%s' "$value"
}

ask_hex32() { # ask_hex32 VAR "Prompt text"  (Cloudflare account/zone IDs)
  # NB: temp var must not collide with ask()'s locals (var/prompt/default/secret/value),
  # otherwise printf -v in ask() writes to its own local and the answer is lost.
  local hexvar=$1 hexprompt=$2 hexval=""
  while true; do
    ask hexval "$hexprompt"
    if [[ $hexval =~ ^[0-9a-f]{32}$ ]]; then break; fi
    warn "That doesn't look like a Cloudflare ID (32 hex characters). Try again."
    hexval=""
  done
  printf -v "$hexvar" '%s' "$hexval"
}

ask_yn() { # ask_yn "Prompt text"  -> returns 0 for yes
  local answer
  while true; do
    printf "%s [y/n]: " "$1"
    read -r answer
    case $answer in
      y|Y|yes) return 0 ;;
      n|N|no)  return 1 ;;
    esac
  done
}

# =================================================== STEP 1 - access mode ===

step "Step 1 / 5 · Access mode"
echo "  1) Browser  - log in to SSH from a web browser (Cloudflare Access, no client install)"
echo "  2) Terminal - classic ssh client through the tunnel (cloudflared on each client)"
MODE=""
while [[ -z $MODE ]]; do
  printf "Choose 1 or 2: "
  read -r choice
  case $choice in
    1) MODE="browser"  ;;
    2) MODE="terminal" ;;
  esac
done
ok "Mode: $MODE"

USE_ACCESS="no"
if [[ $MODE == "browser" ]]; then
  USE_ACCESS="yes"   # browser mode always needs an Access application + policy
elif ask_yn "Also protect the tunnel with a Cloudflare Access policy (login required)?"; then
  USE_ACCESS="yes"
fi

echo
echo "Run cloudflared on this server as:"
echo "  1) Native systemd service"
echo "  2) Docker container"
RUNTIME=""
while [[ -z $RUNTIME ]]; do
  printf "Choose 1 or 2: "
  read -r choice
  case $choice in
    1) RUNTIME="native" ;;
    2) RUNTIME="docker" ;;
  esac
done
ok "Runtime: $RUNTIME"

# ================================================ STEP 2 - prerequisites ===

step "Step 2 / 5 · Checking prerequisites"

APT_UPDATED="no"
apt_install() {
  if [[ $APT_UPDATED == "no" ]]; then $SUDO apt-get update -qq; APT_UPDATED="yes"; fi
  $SUDO apt-get install -y -qq "$@"
}

for tool in curl jq; do
  if command -v "$tool" >/dev/null; then
    ok "$tool installed"
  else
    info "Installing $tool..."
    apt_install "$tool"
    ok "$tool installed"
  fi
done

if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
  ok "SSH server running"
else
  info "Installing openssh-server..."
  apt_install openssh-server
  $SUDO systemctl enable --now ssh
  ok "SSH server installed and started"
fi

if [[ $RUNTIME == "native" ]]; then
  if command -v cloudflared >/dev/null; then
    ok "cloudflared installed ($(cloudflared --version 2>/dev/null | head -1))"
  else
    info "Installing cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
      -o /tmp/cloudflared.deb
    $SUDO dpkg -i /tmp/cloudflared.deb >/dev/null
    rm -f /tmp/cloudflared.deb
    ok "cloudflared installed"
  fi
else
  if command -v docker >/dev/null; then
    ok "Docker installed"
  else
    info "Installing Docker (get.docker.com)..."
    curl -fsSL https://get.docker.com | $SUDO sh
    ok "Docker installed"
  fi
fi

# ============================================= STEP 3 - tokens and IDs =====

step "Step 3 / 5 · Cloudflare credentials (one value at a time)"

SAVED_DOMAIN=""; SAVED_TUNNEL_NAME=""
if [[ -f $ENV_FILE ]]; then
  if ask_yn "Found saved credentials in tunnel.env - reuse token/account/zone?"; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    # Hostname and tunnel name are always re-asked (saved values become the
    # defaults) so repeated runs can build a second tunnel without conflicts.
    SAVED_DOMAIN=${CF_DOMAIN:-}; SAVED_TUNNEL_NAME=${CF_TUNNEL_NAME:-}
    CF_DOMAIN=""; CF_TUNNEL_NAME=""
  fi
fi

if [[ -z ${CF_API_TOKEN:-} ]]; then
  echo "Create an API token at https://dash.cloudflare.com/profile/api-tokens"
  echo "Needed permissions: Account > Cloudflare Tunnel:Edit, Zone > DNS:Edit"
  [[ $USE_ACCESS == "yes" ]] && echo "                    Account > Access: Apps and Policies:Edit"
  ask CF_API_TOKEN "1/5  API Token (input hidden)" "" secret
fi
[[ -z ${CF_ACCOUNT_ID:-} ]]  && ask_hex32 CF_ACCOUNT_ID "2/5  Account ID"
[[ -z ${CF_ZONE_ID:-} ]]     && ask_hex32 CF_ZONE_ID    "3/5  Zone ID"
[[ -z ${CF_DOMAIN:-} ]]      && ask CF_DOMAIN      "4/5  Full hostname (e.g. ssh.example.com)" "$SAVED_DOMAIN"
[[ -z ${CF_TUNNEL_NAME:-} ]] && ask CF_TUNNEL_NAME "5/5  Tunnel name" "${SAVED_TUNNEL_NAME:-my-vm-tunnel}"

ACCESS_EMAILS=${ACCESS_EMAILS:-}
if [[ $USE_ACCESS == "yes" && -z $ACCESS_EMAILS ]]; then
  ask ACCESS_EMAILS "Email address(es) allowed to log in (comma-separated)"
fi

# --- pre-flight credential & permission checks ------------------------------
# Probe every Cloudflare resource this script will touch with a harmless GET,
# BEFORE creating anything. A failure here is either a wrong ID or a token that
# is missing the permission for that resource. We stop immediately and say
# which, so a half-built tunnel / DNS record is never left behind.
preflight() { # preflight RESPONSE "label" "permission hint" "id hint"
  local resp=$1 label=$2 perm=$3 idhint=$4
  if [[ "$(jq -r '.success // false' <<<"$resp")" == "true" ]]; then
    ok "$label OK"
    return 0
  fi
  local code msg
  code=$(jq -r '.errors[0].code // 0' <<<"$resp")
  msg=$(jq -r '.errors[0].message // "unknown error"' <<<"$resp")
  echo
  warn "Pre-flight check failed: $label"
  # Authentication / authorization codes & wording -> missing token permission.
  # Anything else (not found, could not route, invalid) -> a wrong ID.
  if [[ $code == 9109 || $code == 10000 || $code == 9000 || $code == 9001 \
        || $msg == *[Aa]uthentication* || $msg == *[Uu]nauthorized* \
        || $msg == *[Pp]ermission* || $msg == *"not allowed"* ]]; then
    echo "  ${RED}Your API token is missing a permission (or this token does not"
    echo "  cover this account/zone).${RESET}"
    echo "  Add this permission: ${BOLD}$perm${RESET}"
    echo "  Edit the token at https://dash.cloudflare.com/profile/api-tokens"
  else
    echo "  ${RED}This looks like a wrong / mistyped ID.${RESET}"
    echo "  Double-check: ${BOLD}$idhint${RESET}"
  fi
  echo "  Cloudflare said: $msg (code $code)"
  die "Stopping now so nothing half-built is created. Fix the above and re-run."
}

info "Verifying credentials & permissions before building anything..."

# 0) Is the token string itself valid (not a typo / expired)?
VERIFY=$(cf_api GET "/user/tokens/verify")
if [[ "$(jq -r '.success // false' <<<"$VERIFY")" != "true" ]]; then
  echo
  warn "The API token itself was rejected by Cloudflare."
  echo "  Cloudflare said: $(jq -r '.errors[0].message // "invalid token"' <<<"$VERIFY")"
  echo "  Re-create the token at https://dash.cloudflare.com/profile/api-tokens"
  die "Bad or expired API token - fix it and re-run."
fi
ok "API token is valid"

# 1) Account ID correct + Cloudflare Tunnel permission (needed to build tunnel)
info "Checking Account ID + Cloudflare Tunnel permission..."
TUN_CHECK=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?per_page=1")
preflight "$TUN_CHECK" "Account ID + Cloudflare Tunnel permission" \
  "Account > Cloudflare Tunnel : Edit" \
  "Account ID '$CF_ACCOUNT_ID' (copy it from your Cloudflare dashboard URL)"

# 2) Zone ID correct (and token covers this zone)
info "Checking Zone ID..."
ZONE_RESP=$(cf_api GET "/zones/$CF_ZONE_ID")
preflight "$ZONE_RESP" "Zone ID" \
  "Zone > DNS : Edit (and the token must include this zone)" \
  "Zone ID '$CF_ZONE_ID' (Overview tab of your domain in Cloudflare)"
ok "Zone: $(jq -r '.result.name' <<<"$ZONE_RESP")"

# 3) Zone > DNS:Edit permission (needed to point the hostname at the tunnel)
info "Checking DNS permission..."
DNS_CHECK=$(cf_api GET "/zones/$CF_ZONE_ID/dns_records?per_page=1")
preflight "$DNS_CHECK" "Zone DNS permission" \
  "Zone > DNS : Edit" \
  "Zone ID '$CF_ZONE_ID'"

# 4) Access: Apps and Policies permission - only when an Access app is needed.
#    THIS is the common browser-mode trap: you picked browser (which requires an
#    Access application + policy) but the token was made without this permission.
if [[ $USE_ACCESS == "yes" ]]; then
  info "Checking Access (Apps and Policies) permission..."
  ACCESS_CHECK=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/apps?per_page=1")
  preflight "$ACCESS_CHECK" "Access Apps and Policies permission" \
    "Account > Access: Apps and Policies : Edit  (required for browser mode / Access)" \
    "Account ID '$CF_ACCOUNT_ID'"
fi

ok "All credential & permission checks passed"

# Resolve tunnel-name conflicts up front: on a repeated run you can either
# reuse the existing tunnel or pick a fresh name - never a silent collision.
CF_TUNNEL_ID=""
while true; do
  info "Checking tunnel name '$CF_TUNNEL_NAME'..."
  EXISTING=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=$CF_TUNNEL_NAME&is_deleted=false")
  require_success "$EXISTING" "Could not list tunnels"
  CF_TUNNEL_ID=$(jq -r '.result[0].id // empty' <<<"$EXISTING")
  if [[ -z $CF_TUNNEL_ID ]]; then
    ok "Name is free - a new tunnel will be created"
    break
  fi
  warn "A tunnel named '$CF_TUNNEL_NAME' already exists ($CF_TUNNEL_ID)"
  if ask_yn "Reuse that existing tunnel? (n = enter a different name)"; then
    ok "Existing tunnel will be reused"
    break
  fi
  ask CF_TUNNEL_NAME "New tunnel name"
done

umask 077
cat >"$ENV_FILE" <<EOF
# Cloudflare tunnel secrets - DO NOT COMMIT (this file is gitignored)
CF_API_TOKEN="$CF_API_TOKEN"
CF_ACCOUNT_ID="$CF_ACCOUNT_ID"
CF_ZONE_ID="$CF_ZONE_ID"
CF_DOMAIN="$CF_DOMAIN"
CF_TUNNEL_NAME="$CF_TUNNEL_NAME"
ACCESS_EMAILS="$ACCESS_EMAILS"
EOF
ok "Saved to tunnel.env (chmod 600, gitignored)"

# ========================================== STEP 4 - automatic build =======

step "Step 4 / 5 · Building the tunnel (automatic)"

if [[ -n $CF_TUNNEL_ID ]]; then
  ok "Reusing existing tunnel: $CF_TUNNEL_ID"
else
  info "Creating tunnel '$CF_TUNNEL_NAME'..."
  CREATE=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
    "{\"name\":\"$CF_TUNNEL_NAME\",\"config_src\":\"cloudflare\"}")
  require_success "$CREATE" "Tunnel creation failed"
  CF_TUNNEL_ID=$(jq -r '.result.id' <<<"$CREATE")
  ok "Tunnel created: $CF_TUNNEL_ID"
fi

info "DNS: pointing $CF_DOMAIN at the tunnel..."
DNS_BODY="{\"type\":\"CNAME\",\"name\":\"$CF_DOMAIN\",\"content\":\"$CF_TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}"
EXISTING_REC=$(cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$CF_DOMAIN")
REC_ID=$(jq -r '.result[0].id // empty' <<<"$EXISTING_REC")
if [[ -n $REC_ID ]]; then
  RESP=$(cf_api PUT "/zones/$CF_ZONE_ID/dns_records/$REC_ID" "$DNS_BODY")
  require_success "$RESP" "DNS update failed"
  ok "DNS record updated"
else
  RESP=$(cf_api POST "/zones/$CF_ZONE_ID/dns_records" "$DNS_BODY")
  require_success "$RESP" "DNS creation failed"
  ok "DNS record created"
fi

info "Ingress: routing $CF_DOMAIN -> ssh://localhost:22..."
RESP=$(cf_api PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/configurations" "{
  \"config\": {
    \"ingress\": [
      {\"hostname\": \"$CF_DOMAIN\", \"service\": \"ssh://localhost:22\"},
      {\"service\": \"http_status:404\"}
    ]
  }
}")
require_success "$RESP" "Ingress configuration failed"
ok "Ingress configured"

if [[ $USE_ACCESS == "yes" ]]; then
  # Browser mode uses app type "ssh" (browser-rendered terminal);
  # terminal mode uses "self_hosted" (cloudflared access handles login).
  APP_TYPE="self_hosted"
  [[ $MODE == "browser" ]] && APP_TYPE="ssh"

  info "Access: checking for existing application on $CF_DOMAIN..."
  APPS=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/apps")
  require_success "$APPS" "Could not list Access applications"
  APP_ID=$(jq -r --arg d "$CF_DOMAIN" '.result[]? | select(.domain == $d) | .id' <<<"$APPS" | head -1)

  if [[ -n $APP_ID ]]; then
    ok "Reusing existing Access application: $APP_ID"
  else
    info "Creating Access application ($APP_TYPE)..."
    APP_RESP=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/access/apps" "{
      \"name\": \"SSH - $CF_DOMAIN\",
      \"domain\": \"$CF_DOMAIN\",
      \"type\": \"$APP_TYPE\",
      \"session_duration\": \"24h\"
    }")
    require_success "$APP_RESP" "Access application creation failed"
    APP_ID=$(jq -r '.result.id' <<<"$APP_RESP")
    ok "Access application created: $APP_ID"
  fi

  POLICIES=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/apps/$APP_ID/policies")
  if [[ "$(jq -r '.result | length' <<<"$POLICIES" 2>/dev/null || echo 0)" -gt 0 ]]; then
    ok "Access policy already exists - keeping it"
  else
    info "Creating allow policy for: $ACCESS_EMAILS"
    INCLUDE_JSON=$(tr ',' '\n' <<<"$ACCESS_EMAILS" | sed 's/^ *//;s/ *$//' | grep -v '^$' \
      | jq -R '{email:{email:.}}' | jq -s '.')
    POLICY_RESP=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/access/apps/$APP_ID/policies" "{
      \"name\": \"Allow listed emails\",
      \"decision\": \"allow\",
      \"precedence\": 1,
      \"include\": $INCLUDE_JSON
    }")
    require_success "$POLICY_RESP" "Access policy creation failed"
    ok "Access policy created"
  fi
fi

info "Fetching tunnel run token..."
TOKEN_RESP=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/token")
require_success "$TOKEN_RESP" "Could not fetch tunnel token"
TUNNEL_TOKEN=$(jq -r '.result' <<<"$TOKEN_RESP")

if [[ $RUNTIME == "native" ]]; then
  if [[ -f /etc/systemd/system/cloudflared.service ]]; then
    warn "cloudflared service already installed - reinstalling with current token"
    $SUDO cloudflared service uninstall >/dev/null 2>&1 || true
  fi
  info "Installing cloudflared systemd service..."
  $SUDO cloudflared service install "$TUNNEL_TOKEN"
  ok "cloudflared service running (systemctl status cloudflared)"
else
  info "Starting cloudflared Docker container..."
  $SUDO docker rm -f cloudflared >/dev/null 2>&1 || true
  $SUDO docker run -d --name cloudflared --restart unless-stopped --network host \
    -e TUNNEL_TOKEN="$TUNNEL_TOKEN" \
    cloudflare/cloudflared:latest tunnel --no-autoupdate run >/dev/null
  ok "cloudflared container running (docker logs -f cloudflared)"
fi

# ========================================= STEP 5 - client-side reminder ===

step "Step 5 / 5 · What YOU still need to do (client side)"
echo
if [[ $MODE == "browser" ]]; then
  cat <<EOF
${BOLD}Browser mode - nothing to install on the client.${RESET}

  1. On THIS server, make sure the user you'll log in as can authenticate:
       - password login:  the user must have a password set, and
         'PasswordAuthentication yes' in /etc/ssh/sshd_config, OR
       - public key:      paste the client's public key into
         ~/.ssh/authorized_keys of that user
  2. Open ${BOLD}https://$CF_DOMAIN${RESET} in any browser
  3. Log in with one of the allowed emails: ${ACCESS_EMAILS}
  4. A terminal opens in the browser - enter the VM username (and key/password)
EOF
else
  cat <<EOF
${BOLD}Terminal mode - do this on each CLIENT machine:${RESET}

  1. Install cloudflared on the client:
       https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/download-warp/
       (or: brew install cloudflared / the same .deb as the server)

  2. Add this to the client's ~/.ssh/config:

       Host $CF_DOMAIN
         ProxyCommand cloudflared access ssh --hostname %h

  3. On THIS server, paste the client's PUBLIC key into
     ~/.ssh/authorized_keys of the user you'll log in as.

  4. Connect from the client:
       ssh <user>@$CF_DOMAIN
EOF
  if [[ $USE_ACCESS == "yes" ]]; then
    echo
    echo "  (Access policy is on: the first connection opens a browser to log in"
    echo "   with one of: ${ACCESS_EMAILS})"
  fi
fi
echo
ok "Done. Secrets are in tunnel.env - never commit that file."
