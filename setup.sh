#!/usr/bin/env bash
#
# Cloudflare SSH Tunnel - automated setup
#
# Exposes this machine's SSH over a Cloudflare Tunnel, either:
#   - Browser mode  : log in to SSH from a web browser (Cloudflare Access)
#   - Terminal mode : classic `ssh` client through the tunnel
#
# Non-secret settings (account/zone IDs, hostname, tunnel name, allowed emails)
# are saved to ./tunnel.env (chmod 600, gitignored) so re-runs are quick.
# The API TOKEN is deliberately NEVER written to disk - you re-enter it each run.
# Safe to re-run: existing tunnel / DNS record / Access app are reused.
#
set -euo pipefail

CF_API="https://api.cloudflare.com/client/v4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/tunnel.env"

# cloudflared install is PINNED (not "latest") so a run is reproducible and an
# upstream release can't change what you install underneath you.
# Bump this from https://github.com/cloudflare/cloudflared/releases when you want
# a newer version.
CLOUDFLARED_VERSION="2024.12.2"
# Optional integrity check: paste the sha256 of the .deb for YOUR architecture
# (see the releases page) to have the script verify the download before install.
# Leave empty to skip. NB: the checksum is per-architecture.
CLOUDFLARED_SHA256=""

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
echo "  1) Browser  ${GREEN}(MORE SECURE - recommended)${RESET}"
echo "               Login (One-Time PIN) is REQUIRED before SSH is reachable."
echo "               Gives you BOTH: open your hostname in a browser, AND -"
echo "               if you install cloudflared on the client - the normal"
echo "               'ssh user@host' terminal too."
echo "  2) Terminal ${YELLOW}(LESS SECURE)${RESET}"
echo "               Classic 'ssh user@host' only, and ONLY works if you set up"
echo "               cloudflared on each client machine first."
echo "               No browser terminal, and NO login required - the SSH port"
echo "               is reachable by anyone through the tunnel."
echo "               (If you want login required, choose option 1 instead.)"
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

# Tell the user up front exactly what this mode gives them.
if [[ $MODE == "browser" ]]; then
  echo "   ${GREEN}You get: browser access${RESET} (open your hostname in any browser),"
  echo "   ${GREEN}AND terminal access${RESET} too IF you configure cloudflared on the client"
  echo "   (the exact client steps are printed at the end, in Step 5)."
else
  echo "   You get: terminal access only ('ssh user@host' via cloudflared on the client)."
  echo "   No browser terminal in this mode."
fi

USE_ACCESS="no"
if [[ $MODE == "browser" ]]; then
  USE_ACCESS="yes"   # browser mode always needs an Access application + policy
fi
# Terminal mode intentionally has NO login/Access policy and is never asked
# about it. If you want login required, use option 1 (Browser), which always
# enforces One-Time PIN login.

# ================================================ STEP 2 - prerequisites ===

step "Step 2 / 5 · Checking prerequisites"

# This script auto-installs packages with apt-get, so it only works on Debian/
# Ubuntu. Fail loudly and early elsewhere instead of erroring deep inside Step 2.
if ! command -v apt-get >/dev/null; then
  die "This installer needs apt-get (Debian/Ubuntu). On a different distro, install
  curl, jq, openssh-server and cloudflared manually, then re-run."
fi

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

if command -v cloudflared >/dev/null; then
  ok "cloudflared installed ($(cloudflared --version 2>/dev/null | head -1))"
else
  # Map this machine's CPU to the matching cloudflared .deb. The old script
  # hardcoded amd64, which silently installed the wrong/no package on ARM boxes
  # (Raspberry Pi, ARM cloud VMs, etc.).
  case "$(uname -m)" in
    x86_64|amd64)        CF_ARCH="amd64" ;;
    aarch64|arm64)       CF_ARCH="arm64" ;;
    armv7l|armv6l|armhf) CF_ARCH="arm"   ;;
    i386|i686)           CF_ARCH="386"   ;;
    *) die "Unsupported CPU architecture '$(uname -m)'. Install cloudflared manually
  from https://github.com/cloudflare/cloudflared/releases and re-run." ;;
  esac
  CF_DEB_URL="https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$CF_ARCH.deb"
  info "Installing cloudflared $CLOUDFLARED_VERSION ($CF_ARCH)..."
  curl -fsSL "$CF_DEB_URL" -o /tmp/cloudflared.deb \
    || die "Download failed: $CF_DEB_URL
  Check that version '$CLOUDFLARED_VERSION' exists for '$CF_ARCH' on the releases page."
  if [[ -n $CLOUDFLARED_SHA256 ]]; then
    info "Verifying download checksum..."
    echo "$CLOUDFLARED_SHA256  /tmp/cloudflared.deb" | sha256sum -c - \
      || { rm -f /tmp/cloudflared.deb; die "Checksum mismatch - refusing to install a tampered or wrong-arch file."; }
    ok "Checksum verified"
  fi
  $SUDO dpkg -i /tmp/cloudflared.deb >/dev/null
  rm -f /tmp/cloudflared.deb
  ok "cloudflared $CLOUDFLARED_VERSION installed"
fi

# ============================================= STEP 3 - tokens and IDs =====

step "Step 3 / 5 · Cloudflare credentials (one value at a time)"

SAVED_DOMAIN=""; SAVED_TUNNEL_NAME=""
if [[ -f $ENV_FILE ]]; then
  if ask_yn "Found saved settings in tunnel.env - reuse account/zone/domain? (the API token is always re-entered)"; then
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
  echo "This token needs the following permissions:"
  echo "  - Account > Cloudflare Tunnel : Edit"
  echo "  - Zone > DNS : Edit"
  [[ $USE_ACCESS == "yes" ]] && echo "  - Account > Access: Apps and Policies : Edit  (required for browser mode / Access)"
  [[ $USE_ACCESS == "yes" ]] && echo "  - Account > Access: Organizations, Identity Providers, and Groups : Read  (to require One-Time PIN login)"
  ask CF_API_TOKEN "1/5  API Token (input hidden)" "" secret
fi
[[ -z ${CF_ACCOUNT_ID:-} ]]  && ask_hex32 CF_ACCOUNT_ID "2/5  Account ID"
[[ -z ${CF_ZONE_ID:-} ]]     && ask_hex32 CF_ZONE_ID    "3/5  Zone ID"
[[ -z ${CF_DOMAIN:-} ]]      && ask CF_DOMAIN      "4/5  Full hostname (e.g. ssh.example.com)" "$SAVED_DOMAIN"
[[ -z ${CF_TUNNEL_NAME:-} ]] && ask CF_TUNNEL_NAME "5/5  Tunnel name" "${SAVED_TUNNEL_NAME:-my-vm-tunnel}"

ACCESS_EMAILS=${ACCESS_EMAILS:-}
if [[ $USE_ACCESS == "yes" && -z $ACCESS_EMAILS ]]; then
  echo "These emails are allowed to log in. They sign in with a One-Time PIN -"
  echo "a 6-digit code Cloudflare emails them - so NO Google/Gmail account is needed."
  echo "(The 'One-time PIN' login method must be enabled in your Cloudflare"
  echo " Zero Trust dashboard: Settings > Authentication. It is on by default.)"
  # Add emails one at a time: after each one we ask whether to add another.
  # Answer 'n' to finish the list and move on. Stored comma-separated, which is
  # what every downstream step already expects.
  while true; do
    ask one_email "Email address allowed to log in"
    ACCESS_EMAILS="${ACCESS_EMAILS:+$ACCESS_EMAILS,}$one_email"
    ask_yn "Add another email that can log in?" || break
  done
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

  # The policy must REQUIRE the "One-time PIN" login method. That method is an
  # identity provider on the account; we look up its id here so the policy can
  # reference it. Reading identity providers needs its own token permission.
  info "Checking Access (Identity Providers) permission + locating One-Time PIN..."
  IDP_RESP=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/identity_providers")
  preflight "$IDP_RESP" "Access Identity Providers permission" \
    "Account > Access: Organizations, Identity Providers, and Groups : Read" \
    "Account ID '$CF_ACCOUNT_ID'"
  OTP_IDP_ID=$(jq -r '.result[]? | select(.type == "onetimepin") | .id' <<<"$IDP_RESP" | head -1)
  if [[ -z $OTP_IDP_ID ]]; then
    echo
    warn "The 'One-time PIN' login method is not enabled on this account."
    echo "  Enable it in the Zero Trust dashboard:"
    echo "    Settings > Authentication > Login methods > add 'One-time PIN'."
    die "One-Time PIN must be enabled so the policy can require it. Enable it and re-run."
  fi
  ok "One-Time PIN login method found ($OTP_IDP_ID)"
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

# The API token is intentionally NOT saved here - never written to disk - so a
# leaked/backed-up/committed tunnel.env can't hand an attacker your token.
# umask 077 makes a NEWLY created file 0600; the explicit chmod below also
# tightens an EXISTING tunnel.env (umask does not change perms on a file that
# already exists - `cat >` only truncates it), so these settings stay owner-only.
umask 077
cat >"$ENV_FILE" <<EOF
# Cloudflare tunnel settings (gitignored). NOTE: the API token is NOT stored
# here on purpose - you re-enter it on each run.
CF_ACCOUNT_ID="$CF_ACCOUNT_ID"
CF_ZONE_ID="$CF_ZONE_ID"
CF_DOMAIN="$CF_DOMAIN"
CF_TUNNEL_NAME="$CF_TUNNEL_NAME"
ACCESS_EMAILS="$ACCESS_EMAILS"
EOF
chmod 600 "$ENV_FILE"
ok "Settings saved to tunnel.env (chmod 600, owner-only, gitignored; no token inside)"

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

  # --- 1. Reusable Access policy (created first, then attached to the app) ---
  # A reusable policy holds:
  #   include = the allowed emails        -> match ANY one of them
  #   require = the One-Time PIN method    -> must ALWAYS hold
  # Putting the login method in REQUIRE is the fix for "terminal just gets
  # approved": it forces EVERY login - terminal and browser alike - through the
  # emailed 6-digit PIN, instead of silently reusing some other session.
  #
  # We match an existing policy by its allowed-email SET (not just its name), so a
  # different VM with a different list of emails never reuses the wrong policy. If
  # no policy has exactly this email set, we create a NEW one under a free name
  # (one-time-pin, then one-time-pin(1), (2), ...) so existing policies are never
  # overwritten.
  INCLUDE_JSON=$(tr ',' '\n' <<<"$ACCESS_EMAILS" | sed 's/^ *//;s/ *$//' | grep -v '^$' \
    | jq -R '{email:{email:.}}' | jq -s '.')
  REQUIRE_JSON="[{\"login_method\":{\"id\":\"$OTP_IDP_ID\"}}]"
  # Normalized (trimmed, de-duped) list of just the email strings we want to allow.
  DESIRED_EMAILS=$(tr ',' '\n' <<<"$ACCESS_EMAILS" | sed 's/^ *//;s/ *$//' | grep -v '^$' \
    | jq -R '.' | jq -s 'unique')

  info "Access: looking for an existing policy whose allowed emails match exactly..."
  POL_LIST=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/policies")
  require_success "$POL_LIST" "Could not list reusable Access policies"
  # Reuse only if a policy's include-email set == our set AND it requires OTP.
  POLICY_ID=$(jq -r --argjson want "$DESIRED_EMAILS" --arg otp "$OTP_IDP_ID" '
    .result[]?
    | select(([.include[]?.email.email] | unique) == ($want | unique))
    | select([.require[]?.login_method.id] | index($otp))
    | .id' <<<"$POL_LIST" | head -1)

  if [[ -n $POLICY_ID ]]; then
    POLICY_NAME=$(jq -r --arg id "$POLICY_ID" '.result[]? | select(.id == $id) | .name' <<<"$POL_LIST" | head -1)
    warn "A policy with exactly these allowed emails already exists ('$POLICY_NAME', $POLICY_ID)."
    ok "Reusing it - NOT creating a duplicate policy."
    echo "  (To change who can log in, edit this policy in the Zero Trust"
    echo "   dashboard > Access > Policies, then re-run - that avoids duplicates.)"
  else
    # Pick a name not already taken, so we never clobber a different policy.
    EXISTING_NAMES=$(jq -r '.result[]?.name' <<<"$POL_LIST")
    POLICY_NAME="one-time-pin"; n=1
    while grep -qxF "$POLICY_NAME" <<<"$EXISTING_NAMES"; do
      POLICY_NAME="one-time-pin($n)"; n=$((n+1))
    done
    info "Creating reusable policy '$POLICY_NAME' (One-Time PIN required for: $ACCESS_EMAILS)"
    POLICY_RESP=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/access/policies" "{
      \"name\": \"$POLICY_NAME\",
      \"decision\": \"allow\",
      \"include\": $INCLUDE_JSON,
      \"require\": $REQUIRE_JSON
    }")
    require_success "$POLICY_RESP" "Reusable policy creation failed"
    POLICY_ID=$(jq -r '.result.id' <<<"$POLICY_RESP")
    ok "Reusable policy created: $POLICY_ID"
  fi

  # --- 2. Access application (created or reused), with the policy attached ---
  info "Access: checking for existing application on $CF_DOMAIN..."
  APPS=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/apps")
  require_success "$APPS" "Could not list Access applications"
  APP_ID=$(jq -r --arg d "$CF_DOMAIN" '.result[]? | select(.domain == $d) | .id' <<<"$APPS" | head -1)

  if [[ -n $APP_ID ]]; then
    warn "An Access application for $CF_DOMAIN already exists ($APP_ID)."
    ok "Reusing it - NOT creating a duplicate application."
    # Make sure our '$POLICY_NAME' policy is attached to the reused app.
    ATTACHED=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/access/apps/$APP_ID/policies")
    require_success "$ATTACHED" "Could not read the application's policies"
    HAS_POLICY=$(jq -r --arg id "$POLICY_ID" '.result[]? | select(.id == $id) | .id' <<<"$ATTACHED" | head -1)
    if [[ -n $HAS_POLICY ]]; then
      ok "Policy '$POLICY_NAME' is already attached to this application."
    else
      info "Attaching policy '$POLICY_NAME' to the existing application..."
      # Keep whatever policies are already attached, then add ours (no clobber).
      POLICIES_JSON=$(jq -c --arg id "$POLICY_ID" '[.result[]?.id] + [$id] | unique' <<<"$ATTACHED")
      ATTACH_RESP=$(cf_api PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$APP_ID" "{
        \"name\": \"SSH - $CF_DOMAIN\",
        \"domain\": \"$CF_DOMAIN\",
        \"type\": \"$APP_TYPE\",
        \"session_duration\": \"24h\",
        \"policies\": $POLICIES_JSON
      }")
      require_success "$ATTACH_RESP" "Could not attach policy to existing application"
      ok "Policy attached to application."
    fi
  else
    info "Creating Access application ($APP_TYPE) with policy '$POLICY_NAME'..."
    APP_RESP=$(cf_api POST "/accounts/$CF_ACCOUNT_ID/access/apps" "{
      \"name\": \"SSH - $CF_DOMAIN\",
      \"domain\": \"$CF_DOMAIN\",
      \"type\": \"$APP_TYPE\",
      \"session_duration\": \"24h\",
      \"policies\": [{\"id\": \"$POLICY_ID\", \"precedence\": 1}]
    }")
    require_success "$APP_RESP" "Access application creation failed"
    APP_ID=$(jq -r '.result.id' <<<"$APP_RESP")
    ok "Access application created: $APP_ID (policy attached)"
  fi
fi

info "Fetching tunnel run token..."
TOKEN_RESP=$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$CF_TUNNEL_ID/token")
require_success "$TOKEN_RESP" "Could not fetch tunnel token"
TUNNEL_TOKEN=$(jq -r '.result' <<<"$TOKEN_RESP")

if [[ -f /etc/systemd/system/cloudflared.service ]]; then
  warn "cloudflared service already installed - reinstalling with current token"
  $SUDO cloudflared service uninstall >/dev/null 2>&1 || true
fi
info "Installing cloudflared systemd service..."
$SUDO cloudflared service install "$TUNNEL_TOKEN"
ok "cloudflared service running (systemctl status cloudflared)"

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

${BOLD}Want terminal access too? (optional)${RESET}
The browser works with zero setup. To ALSO use 'ssh user@host', you MUST first
do this configuration on EACH client machine - terminal will NOT work without it:

  a. ${BOLD}Required:${RESET} install cloudflared on the client:
       https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp/download-warp/
       (or: brew install cloudflared / the same .deb as the server)
  b. ${BOLD}Required:${RESET} add this block to the client's ~/.ssh/config:

       Host $CF_DOMAIN
         ProxyCommand cloudflared access ssh --hostname %h
         UserKnownHostsFile /dev/null
         StrictHostKeyChecking accept-new

     ${YELLOW}! Heads up:${RESET} the last two lines turn OFF SSH host-key checking for
       this host - no host key is saved or compared, so SSH will NOT warn you if
       the server's identity ever changes. That is intentional here (Cloudflare
       Access is the trust layer), but if you'd rather verify host keys the normal
       way, delete those two lines.
  c. Then connect:  ssh <user>@$CF_DOMAIN
       (first connection opens a browser to log in with one of: ${ACCESS_EMAILS})
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
         UserKnownHostsFile /dev/null
         StrictHostKeyChecking accept-new

     ${YELLOW}! Heads up:${RESET} the last two lines turn OFF SSH host-key checking for
       this host - no host key is saved or compared, so SSH will NOT warn you if
       the server's identity ever changes. That is intentional for tunnelled SSH,
       but if you'd rather verify host keys the normal way, delete those two lines.

  3. On THIS server, paste the client's PUBLIC key into
     ~/.ssh/authorized_keys of the user you'll log in as.

  4. Connect from the client:
       ssh <user>@$CF_DOMAIN
EOF
  if [[ $USE_ACCESS == "yes" ]]; then
    echo
    echo "  (Access policy is on: the first connection opens a browser and now"
    echo "   REQUIRES a One-Time PIN - a 6-digit code Cloudflare emails to one of:"
    echo "   ${ACCESS_EMAILS}. Terminal logins are prompted for the PIN too.)"
  fi
fi
echo
ok "Done. Settings are in tunnel.env (no token inside) - it's gitignored either way."
