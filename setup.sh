#!/usr/bin/env bash
#
# ProxDeploy installer — run this on the machine that will host your sites.
#
#     ./setup.sh
#
# Asks for your domains, Cloudflare token, GitHub token and a dashboard
# password, then does the rest: virtualenv, .env, sudoers rule, systemd
# service, tunnel ingress, and DNS for the dashboard itself.
#
#     ./setup.sh --password    change the dashboard password later
#
# Safe to re-run. Everything it touches is backed up first, and it never
# overwrites an existing config without asking.

set -uo pipefail

# ─── Output helpers ───────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
else
  B=""; DIM=""; R=""; RED=""; GRN=""; YLW=""; CYN=""
fi

STEP_N=0
step() { STEP_N=$((STEP_N+1)); printf '\n%s━━ Step %d — %s%s\n' "$B$CYN" "$STEP_N" "$1" "$R"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
info() { printf '  %s·%s %s\n' "$DIM" "$R" "$1"; }
warn() { printf '  %s!%s %s\n' "$YLW" "$R" "$1"; }
die()  { printf '\n%s✗ %s%s\n\n' "$RED$B" "$1" "$R" >&2; exit 1; }

ask() { # ask <prompt> <default> -> stdout
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -r -p "  $prompt [$default]: " reply </dev/tty
    printf '%s' "${reply:-$default}"
  else
    read -r -p "  $prompt: " reply </dev/tty
    printf '%s' "$reply"
  fi
}

ask_secret() { # ask_secret <prompt> -> stdout (input hidden)
  local reply
  read -r -s -p "  $1: " reply </dev/tty
  printf '\n' >&2
  printf '%s' "$reply"
}

confirm() { # confirm <prompt> <default y|n>
  local prompt="$1" default="${2:-n}" reply hint="y/N"
  [ "$default" = "y" ] && hint="Y/n"
  read -r -p "  $prompt [$hint] " reply </dev/tty
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

backup() { # backup <path> — copies to <path>.bak-<timestamp> if it exists
  [ -e "$1" ] || return 0
  local dest="$1.bak-$(date +%Y%m%d%H%M%S)"
  if [ -w "$(dirname "$1")" ]; then cp -a "$1" "$dest"; else sudo cp -a "$1" "$dest"; fi
  info "Backed up $(basename "$1") → $(basename "$dest")"
}

# Parse one field out of a Cloudflare API response without needing jq.
json_get() { python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
for k in sys.argv[1:]:
    if d is None: sys.exit(1)
    d = d[int(k)] if isinstance(d, list) else d.get(k)
print("" if d is None else d)' "$@" 2>/dev/null; }

cf_api() { # cf_api <method> <path> [body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" --data "$body" 2>/dev/null
  else
    curl -sS -X "$method" "https://api.cloudflare.com/client/v4$path" \
      -H "Authorization: Bearer $CF_API_TOKEN" 2>/dev/null
  fi
}

install_requirements() {
  "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1
  "$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt" \
    || die "pip install failed. Run it by hand to see why:
  $APP_DIR/venv/bin/pip install -r requirements.txt"
}

# Sets the dashboard password now, at install time. Left unset, the first
# person to load the login page would get to choose it — and the dashboard is
# on the public internet as soon as the tunnel routes it.
set_password() {
  local pw pw2 have
  have="$("$APP_DIR/venv/bin/python" -c '
import json
try: print("yes" if json.load(open("config.json")).get("password_hash") else "")
except Exception: print("")' 2>/dev/null)"
  if [ -n "$have" ] && ! confirm "A dashboard password is already set. Change it?" n; then
    info "Kept the existing password"; return 0
  fi
  printf '  Anyone with this password can run code on this machine, so make it\n'
  printf '  long. At least 12 characters.\n\n'
  while :; do
    pw="$(ask_secret 'New dashboard password')"
    [ ${#pw} -lt 12 ] && { warn "Too short — use at least 12 characters."; continue; }
    pw2="$(ask_secret 'Type it again')"
    [ "$pw" = "$pw2" ] && break
    warn "Those didn't match. Try again."
  done
  # Password goes in on stdin, never argv, so it can't show up in `ps`.
  printf '%s' "$pw" | "$APP_DIR/venv/bin/python" -c '
import bcrypt, json, os, sys
pw = sys.stdin.buffer.read()
try: cfg = json.load(open("config.json"))
except FileNotFoundError: cfg = {"password_hash": None, "services": {}}
cfg["password_hash"] = bcrypt.hashpw(pw, bcrypt.gensalt()).decode()
old = os.umask(0o077)
with open("config.json.tmp", "w") as f: json.dump(cfg, f, indent=2)
os.umask(old)
os.replace("config.json.tmp", "config.json")' || die "Could not write the password to config.json."
  unset pw pw2
  ok "Password saved (bcrypt hash in config.json)"
}

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

case "${1:-}" in
  -h|--help)
    sed -n '3,15p' "$0" | sed 's/^# \?//'
    exit 0 ;;
  --password)
    [ -x "$APP_DIR/venv/bin/python" ] || die "No venv yet — run ./setup.sh first."
    step "Change dashboard password"
    set_password
    info "Takes effect immediately; no restart needed."
    exit 0 ;;
esac

printf '\n%s┌────────────────────────────────────────┐\n' "$B$CYN"
printf '│   ProxDeploy — installer               │\n'
printf '└────────────────────────────────────────┘%s\n' "$R"
printf '\n  Installing from: %s%s%s\n' "$DIM" "$APP_DIR" "$R"
printf '  %sYou can press Ctrl-C at any point before Step 5; nothing is\n' "$DIM"
printf '  written to your system until then.%s\n' "$R"

# ─── Step 1: prerequisites ────────────────────────────────────────────────────
step "Checking prerequisites"

[ "$(id -u)" -eq 0 ] && die "Don't run this as root or with sudo. Run it as the user
  that should own the service — it will call sudo itself when it needs to."

[ -f "$APP_DIR/app.py" ] || die "app.py not found. Run this script from inside the
  ProxDeploy directory."

MISSING=()
for c in python3 git curl; do command -v "$c" >/dev/null || MISSING+=("$c"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  warn "Missing: ${MISSING[*]}"
  if confirm "Install them now with apt?" y; then
    sudo apt update && sudo apt install -y "${MISSING[@]}" || die "Install failed."
  else
    die "Cannot continue without: ${MISSING[*]}"
  fi
fi

python3 - <<'PY' || die "Python 3.9 or newer is required."
import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)
PY
ok "python3 $(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])')"

if ! python3 -c "import venv" 2>/dev/null; then
  warn "python3-venv is missing."
  confirm "Install it now?" y && sudo apt install -y python3-venv || die "Need python3-venv."
fi
ok "venv module available"

if command -v nginx >/dev/null || [ -x /usr/sbin/nginx ]; then
  ok "nginx found"
else
  warn "nginx is not installed. It serves every site you deploy."
  if confirm "Install nginx now with apt?" y; then
    sudo apt update && sudo apt install -y nginx || die "Installing nginx failed."
    ok "nginx installed"
  else
    die "ProxDeploy needs nginx."
  fi
fi

if command -v cloudflared >/dev/null; then
  ok "cloudflared found at $(command -v cloudflared)"
else
  warn "cloudflared is not installed. It's the Cloudflare Tunnel that carries"
  warn "traffic from the internet to this machine, so no ports get opened."
  if confirm "Install cloudflared now from Cloudflare's apt repository?" y; then
    # Cloudflare's documented install: https://pkg.cloudflare.com/
    # "any" covers every Debian-based release, Bookworm and Trixie included.
    sudo mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
      || die "Couldn't download Cloudflare's signing key."
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
    sudo apt update && sudo apt install -y cloudflared || die "Installing cloudflared failed."
    ok "cloudflared installed"
  else
    die "ProxDeploy needs cloudflared."
  fi
fi

# ─── Step 2: Cloudflare ───────────────────────────────────────────────────────
step "Cloudflare"

printf '  You need an API token with %sEdit zone DNS%s on every domain you want\n' "$B" "$R"
printf '  to deploy to.\n\n'
printf '    %sCloudflare dashboard → My Profile → API Tokens → Create Token\n' "$DIM"
printf '    → "Edit zone DNS" template → Zone Resources: include your domains%s\n\n' "$R"

CF_API_TOKEN=""
while [ -z "$CF_API_TOKEN" ]; do
  CF_API_TOKEN="$(ask_secret 'Cloudflare API token')"
  [ -z "$CF_API_TOKEN" ] && { warn "Token is required."; continue; }
  info "Verifying…"
  if [ "$(cf_api GET /user/tokens/verify | json_get success)" = "True" ]; then
    ok "Token is valid and active"
  else
    warn "Cloudflare rejected that token. Check it and try again."
    CF_API_TOKEN=""
  fi
done

# ─── Step 3: domains ──────────────────────────────────────────────────────────
step "Domains"

printf '  List every domain ProxDeploy should be able to deploy to, separated by\n'
printf '  commas. The %sfirst one is the default%s — sites there keep short names\n' "$B" "$R"
printf '  ("blog"); sites on the others are named by full hostname\n'
printf '  ("blog.example.org").\n\n'

DOMAIN=""; DOMAINS_PAIRS=""
while [ -z "$DOMAIN" ]; do
  RAW="$(ask 'Domains (e.g. example.com,example.org)')"
  [ -z "$RAW" ] && { warn "At least one domain is required."; continue; }

  DOMAIN=""; DOMAINS_PAIRS=""; FAILED=0
  IFS=',' read -r -a DLIST <<< "$RAW"
  for d in "${DLIST[@]}"; do
    d="$(echo "$d" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -z "$d" ] && continue
    info "Looking up zone for ${d}…"
    ZRESP="$(cf_api GET "/zones?name=$d")"
    ZID="$(echo "$ZRESP" | json_get result 0 id)"
    if [ -z "$ZID" ]; then
      warn "No Cloudflare zone found for '$d'. Either the domain hasn't been added"
      warn "to Cloudflare yet (dashboard → Add a domain), or the token's Zone"
      warn "Resources don't include it."
      FAILED=1; continue
    fi
    ok "$d → zone ${ZID:0:8}…"
    # A zone stays "pending" until the registrar points at Cloudflare's
    # nameservers. Nothing here can do that step, but it can say exactly what
    # to type, and the rest of setup works fine in the meantime.
    if [ "$(echo "$ZRESP" | json_get result 0 status)" != "active" ]; then
      NS1="$(echo "$ZRESP" | json_get result 0 name_servers 0)"
      NS2="$(echo "$ZRESP" | json_get result 0 name_servers 1)"
      warn "$d isn't active on Cloudflare yet. At your registrar, set its"
      warn "nameservers to:  ${NS1:-?}  and  ${NS2:-?}"
      info "Setup can finish now; sites on $d go live once that propagates."
    fi
    [ -z "$DOMAIN" ] && DOMAIN="$d"
    DOMAINS_PAIRS="${DOMAINS_PAIRS:+$DOMAINS_PAIRS,}$d:$ZID"
  done

  if [ -z "$DOMAIN" ]; then
    warn "No usable domains. Try again."
  elif [ "$FAILED" -eq 1 ]; then
    confirm "Some domains failed. Continue with just the ones that worked?" y || DOMAIN=""
  fi
done
info "Default domain: ${B}${DOMAIN}${R}"

# ─── Step 4: tunnel, GitHub, dashboard hostname ───────────────────────────────
step "Tunnel and options"

# ProxDeploy needs a *locally-managed* tunnel: one whose routes live in
# /etc/cloudflared/config.yml, because that file is what it edits to connect
# domains. A tunnel created in the Cloudflare dashboard keeps its routes in the
# cloud instead, and runs from a token with no config file at all.
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
CF_TUNNEL_ID=""; TUNNEL_MODE="existing"; TUNNEL_NAME=""; REMOTE_MANAGED=0
for f in /etc/cloudflared/config.yml "$HOME/.cloudflared/config.yml"; do
  sudo test -r "$f" 2>/dev/null || continue
  CF_TUNNEL_ID="$(sudo grep -E '^\s*tunnel:' "$f" | grep -oE "$UUID_RE" | head -1)"
  [ -n "$CF_TUNNEL_ID" ] && break
done
systemctl cat cloudflared 2>/dev/null | grep -q -- '--token' && REMOTE_MANAGED=1

if [ -n "$CF_TUNNEL_ID" ]; then
  ok "Found tunnel $CF_TUNNEL_ID in $f"
  confirm "Use this tunnel?" y || CF_TUNNEL_ID="$(ask 'Tunnel UUID (blank to skip)')"
elif [ "$REMOTE_MANAGED" -eq 1 ]; then
  warn "cloudflared is running a tunnel managed from the Cloudflare dashboard."
  warn "ProxDeploy can't add routes to that kind of tunnel. Without them, new"
  warn "sites return 404 until you add each hostname by hand in the dashboard."
  printf '\n    %sSetup can create a locally-managed tunnel and switch cloudflared\n' "$DIM"
  printf '    over to it. Anything the old tunnel served stops being served by this\n'
  printf '    machine, so only do this if the Pi has nothing else on that tunnel.%s\n\n' "$R"
  if confirm "Replace it with a new locally-managed tunnel?" n; then
    TUNNEL_MODE="create"
  else
    CF_TUNNEL_ID="$(ask 'Tunnel UUID to record anyway (blank to skip)')"
  fi
else
  info "No tunnel on this machine yet. Setup will create one."
  TUNNEL_MODE="create"
fi

if [ "$TUNNEL_MODE" = "create" ]; then
  TUNNEL_NAME="$(ask 'Name for the new tunnel' "proxdeploy-$(hostname -s)")"
  [ -f "$HOME/.cloudflared/cert.pem" ] \
    || info "You'll be shown a Cloudflare link to open in a browser, on any device."
elif [ -z "$CF_TUNNEL_ID" ]; then
  warn "No tunnel ID — you won't be able to deploy a domain root (landing page)."
fi

printf '\n'
GITHUB_TOKEN=""
if confirm "Will you deploy PRIVATE GitHub repos?" n; then
  printf '    %sNeeds a token with `repo` scope (classic) or Contents:read\n' "$DIM"
  printf '    (fine-grained). It is redacted from ProxDeploy log files.%s\n' "$R"
  GITHUB_TOKEN="$(ask_secret 'GitHub token')"
  [ -n "$GITHUB_TOKEN" ] && ok "GitHub token stored"
fi

printf '\n'
DASH_HOST="$(ask 'Hostname for the dashboard itself' "deploy.$DOMAIN")"
DASH_PORT="$(ask 'Local port for ProxDeploy' '2096')"

# ─── Step 5: write everything ─────────────────────────────────────────────────
step "Ready to install"

RUN_USER="$(id -un)"
cat <<SUMMARY

  Install directory   $APP_DIR
  Service user        $RUN_USER
  Default domain      $DOMAIN
  All domains         $(echo "$DOMAINS_PAIRS" | sed 's/:[0-9a-f]*//g')
  Tunnel              $([ "$TUNNEL_MODE" = create ] && echo "create new: $TUNNEL_NAME" || echo "${CF_TUNNEL_ID:-(none)}")
  Private repos       $([ -n "$GITHUB_TOKEN" ] && echo yes || echo no)
  Dashboard           https://$DASH_HOST  →  localhost:$DASH_PORT

  From here on, files are written to your system.
SUMMARY
confirm "Proceed?" y || { printf '\n  Aborted. Nothing was changed.\n\n'; exit 0; }

# --- 5-0. Cloudflare Tunnel ---
if [ "$TUNNEL_MODE" = "create" ]; then
  step "Cloudflare Tunnel"

  # 1. Authorise this machine. One browser click; writes ~/.cloudflared/cert.pem.
  if [ -f "$HOME/.cloudflared/cert.pem" ]; then
    ok "Already authorised with Cloudflare (~/.cloudflared/cert.pem)"
  else
    printf '  Open the link below in a browser on any device, sign in to Cloudflare,\n'
    printf '  and pick %sany one%s of your domains. That only authorises this machine\n' "$B" "$R"
    printf '  to create tunnels; the tunnel works for every domain on the account.\n\n'
    cloudflared tunnel login </dev/tty || die "Cloudflare login didn't finish. Re-run ./setup.sh to try again."
    [ -f "$HOME/.cloudflared/cert.pem" ] || die "Login finished but ~/.cloudflared/cert.pem is missing."
    ok "Authorised"
  fi

  # 2. Create the tunnel, or reuse one with the same name from an earlier run.
  CF_TUNNEL_ID="$(cloudflared tunnel list --name "$TUNNEL_NAME" --output json 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)[0]["id"])
except Exception: pass')"
  if [ -n "$CF_TUNNEL_ID" ]; then
    [ -f "$HOME/.cloudflared/$CF_TUNNEL_ID.json" ] || die "A tunnel named '$TUNNEL_NAME' already exists, but its credentials
  file isn't on this machine. Re-run and pick another name, or delete it with:
    cloudflared tunnel delete $TUNNEL_NAME"
    ok "Reusing tunnel $TUNNEL_NAME ($CF_TUNNEL_ID)"
  else
    OUT="$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)" || die "Creating the tunnel failed:
$OUT"
    CF_TUNNEL_ID="$(echo "$OUT" | grep -oE "$UUID_RE" | tail -1)"
    [ -n "$CF_TUNNEL_ID" ] || die "Couldn't read the new tunnel's ID from:
$OUT"
    ok "Created tunnel $TUNNEL_NAME ($CF_TUNNEL_ID)"
  fi

  # 3. Config + credentials under /etc/cloudflared, where the service and
  #    proxdeploy-ingress both look. The ingress list starts as just the
  #    catch-all; the "Tunnel ingress" step below fills it in.
  sudo mkdir -p /etc/cloudflared
  sudo install -m 0600 -o root -g root "$HOME/.cloudflared/$CF_TUNNEL_ID.json" \
    "/etc/cloudflared/$CF_TUNNEL_ID.json" || die "Couldn't copy the tunnel credentials."
  backup /etc/cloudflared/config.yml
  printf 'tunnel: %s\ncredentials-file: /etc/cloudflared/%s.json\n\ningress:\n  - service: http_status:404\n' \
    "$CF_TUNNEL_ID" "$CF_TUNNEL_ID" | sudo tee /etc/cloudflared/config.yml >/dev/null
  sudo chmod 644 /etc/cloudflared/config.yml
  ok "Wrote /etc/cloudflared/config.yml"

  # 4. Run it as a service, replacing a dashboard-managed one if that's there.
  if [ "$REMOTE_MANAGED" -eq 1 ]; then
    sudo cloudflared service uninstall >/dev/null 2>&1
    info "Removed the dashboard-managed cloudflared service"
  fi
  if systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared.service; then
    info "cloudflared.service already installed"
  else
    sudo cloudflared --config /etc/cloudflared/config.yml service install >/dev/null 2>&1 \
      || die "cloudflared service install failed. Try by hand:
  sudo cloudflared --config /etc/cloudflared/config.yml service install"
  fi
  sudo systemctl enable cloudflared >/dev/null 2>&1
  sudo systemctl restart cloudflared && sleep 2
  systemctl is-active --quiet cloudflared \
    && ok "cloudflared is running tunnel $TUNNEL_NAME" \
    || warn "cloudflared isn't active yet — check: systemctl status cloudflared"
fi

# --- 5a. virtualenv ---
step "Python environment"
if [ -d "$APP_DIR/venv" ]; then
  info "venv already exists — reusing it"
else
  python3 -m venv "$APP_DIR/venv" || die "Could not create the virtualenv."
  ok "Created venv/"
fi
install_requirements
ok "Installed flask, bcrypt, requests"

# --- 5a-bis. dashboard password ---
step "Dashboard password"
set_password

# --- 5b. .env ---
step "Writing .env"
SECRET_KEY="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
API_KEY="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"

WRITE_ENV=1
if [ -f "$APP_DIR/.env" ]; then
  warn "A .env already exists."
  if confirm "Overwrite it? (a backup is kept)" n; then
    backup "$APP_DIR/.env"
    # Keep the old keys so existing sessions and CLI configs keep working
    OLD_SECRET="$(grep -E '^SECRET_KEY=' "$APP_DIR/.env" | cut -d= -f2-)"
    OLD_API="$(grep -E '^API_KEY=' "$APP_DIR/.env" | cut -d= -f2-)"
    [ -n "${OLD_SECRET:-}" ] && { SECRET_KEY="$OLD_SECRET"; info "Kept existing SECRET_KEY"; }
    [ -n "${OLD_API:-}" ]    && { API_KEY="$OLD_API";       info "Kept existing API_KEY"; }
  else
    WRITE_ENV=0
    API_KEY="$(grep -E '^API_KEY=' "$APP_DIR/.env" | cut -d= -f2-)"
    info "Left the existing .env untouched"
  fi
fi

if [ "$WRITE_ENV" -eq 1 ]; then
  umask 077
  cat > "$APP_DIR/.env" <<ENV
# Generated by setup.sh on $(date -Iseconds)
# systemd reads this file directly: no quotes, no spaces around '=',
# no inline comments on a value line.

SECRET_KEY=$SECRET_KEY

DOMAIN=$DOMAIN
DOMAINS=$DOMAINS_PAIRS
CF_API_TOKEN=$CF_API_TOKEN
CF_ZONE_ID=
CF_TUNNEL_ID=$CF_TUNNEL_ID

PORT=$DASH_PORT

API_KEY=$API_KEY
GITHUB_TOKEN=$GITHUB_TOKEN

PUBLIC_STATUS=
ENV
  chmod 600 "$APP_DIR/.env"
  ok "Wrote .env (mode 600) with freshly generated keys"
fi

# --- 5c. sudoers ---
step "Sudoers rule"
info "ProxDeploy needs passwordless sudo for a few specific commands."

PATHS=()
for bin in nginx systemctl git chown rm; do
  p="$(command -v "$bin" 2>/dev/null)"
  [ -z "$p" ] && p="$(sudo -n which "$bin" 2>/dev/null)"
  [ -z "$p" ] && [ -x "/usr/sbin/$bin" ] && p="/usr/sbin/$bin"
  if [ -n "$p" ]; then PATHS+=("$p"); info "$bin → $p"; else warn "Could not resolve '$bin'"; fi
done
[ ${#PATHS[@]} -eq 0 ] && die "Could not resolve any binary paths."

# The "+ Domain" button edits /etc/cloudflared/config.yml through this root
# helper, so the app never gets sudo on the tunnel config itself.
HELPER=/usr/local/bin/proxdeploy-ingress
backup "$HELPER"
sudo install -m 0755 -o root -g root "$APP_DIR/proxdeploy-ingress" "$HELPER" \
  && { PATHS+=("$HELPER"); ok "Installed $HELPER"; } \
  || warn "Could not install $HELPER — the + Domain button won't be able to route new domains."

SUDO_LINE="$RUN_USER ALL=(ALL) NOPASSWD: $(IFS=,; echo "${PATHS[*]}")"
TMP_SUDO="$(mktemp)"
printf '%s\n' "$SUDO_LINE" > "$TMP_SUDO"

if sudo visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
  backup /etc/sudoers.d/proxdeploy
  sudo install -m 0440 -o root -g root "$TMP_SUDO" /etc/sudoers.d/proxdeploy
  ok "Installed /etc/sudoers.d/proxdeploy"
  if sudo -n true 2>/dev/null; then ok "Passwordless sudo confirmed"; else warn "Rule installed, but sudo still prompts — check it manually."; fi
else
  rm -f "$TMP_SUDO"
  die "Generated sudoers line failed validation — refusing to install it.
  Add this by hand with: sudo visudo -f /etc/sudoers.d/proxdeploy
    $SUDO_LINE"
fi
rm -f "$TMP_SUDO"

# --- 5d. systemd ---
step "systemd service"
UNIT="$(mktemp)"
cat > "$UNIT" <<UNITEOF
[Unit]
Description=ProxDeploy — Homelab Deploy Dashboard
# Cloudflare API calls need DNS up. The dashboard itself only binds localhost,
# so this is about the first deploy after a reboot, not about starting at all.
After=network-online.target
Wants=network-online.target
# Never stop retrying. The default rate limiter gives up after 5 restarts in
# 10s and leaves the unit dead — exactly the wrong behaviour after a power cut,
# when the app may lose several races against the network before settling.
StartLimitIntervalSec=0

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/venv/bin/python app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

backup /etc/systemd/system/proxdeploy.service
sudo install -m 0644 -o root -g root "$UNIT" /etc/systemd/system/proxdeploy.service
rm -f "$UNIT"
sudo systemctl daemon-reload
ok "Installed /etc/systemd/system/proxdeploy.service"
sudo systemctl restart proxdeploy
sleep 2

if systemctl is-active --quiet proxdeploy; then
  ok "proxdeploy.service is active"
else
  warn "Service did not start. Recent log:"
  sudo journalctl -u proxdeploy -n 20 --no-pager | sed 's/^/    /'
  die "Fix the error above, then re-run: sudo systemctl restart proxdeploy"
fi

if curl -sS -o /dev/null -m 5 "http://localhost:$DASH_PORT/login"; then
  ok "Responding on localhost:$DASH_PORT"
else
  warn "Not responding on localhost:$DASH_PORT yet — give it a moment."
fi

# --- 5d-bis. boot persistence ---
step "Start on boot"
printf '  After a power cut or reboot, three things must come back on their own\n'
printf '  or your sites stay dark: %sProxDeploy%s, %snginx%s (serves them), and\n' "$B" "$R" "$B" "$R"
printf '  %scloudflared%s (the only route in from the internet).\n\n' "$B" "$R"

if confirm "Enable automatic start on boot?" y; then
  BOOT_UNITS=(proxdeploy)
  command -v nginx >/dev/null       && BOOT_UNITS+=(nginx)
  command -v cloudflared >/dev/null && BOOT_UNITS+=(cloudflared)

  for u in "${BOOT_UNITS[@]}"; do
    systemctl list-unit-files "$u.service" 2>/dev/null | grep -q "$u.service" || {
      warn "$u.service not found — skipping"; continue; }
    if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "enabled" ]; then
      ok "$u — already enabled at boot"
    elif sudo systemctl enable "$u" >/dev/null 2>&1; then
      ok "$u — enabled at boot"
    else
      warn "Could not enable $u. Do it by hand: sudo systemctl enable $u"
    fi
  done

  # Re-runs on an existing install: sites with their own units need enabling too,
  # otherwise the dashboard comes back after a reboot but the apps behind it
  # don't, and every dynamic site 502s.
  if [ -f "$APP_DIR/config.json" ]; then
    SITE_UNITS="$(python3 -c '
import json
try: cfg = json.load(open("config.json"))
except Exception: raise SystemExit
seen = set()
for svc in cfg.get("services", {}).values():
    for u in [svc.get("service_name")] + [e.get("service_name") for e in (svc.get("extensions") or {}).values()]:
        if u and u not in seen:
            seen.add(u); print(u if u.endswith(".service") else u + ".service")' 2>/dev/null)"

    if [ -n "$SITE_UNITS" ]; then
      COUNT="$(echo "$SITE_UNITS" | wc -l | tr -d ' ')"
      printf '\n'
      info "Found $COUNT systemd unit(s) belonging to deployed sites."
      if confirm "Enable those at boot too?" y; then
        while read -r u; do
          [ -z "$u" ] && continue
          if [ "$(systemctl is-enabled "$u" 2>/dev/null)" = "enabled" ]; then
            ok "$u — already enabled"
          elif sudo systemctl enable "$u" >/dev/null 2>&1; then
            ok "$u — enabled at boot"
          else
            warn "$u — could not enable (does the unit exist?)"
          fi
        done <<< "$SITE_UNITS"
      fi
    fi
  fi

  # A unit that's enabled but permanently failed is a reboot away from silence.
  FAILED="$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')"
  if [ -n "$FAILED" ]; then
    printf '\n'
    warn "These units are currently in a FAILED state:"
    echo "$FAILED" | sed 's/^/      /'
    info "If any is enabled at boot it will keep failing after every reboot."
    info "Inspect with: systemctl status <unit>"
  fi

  printf '\n'
  ok "Boot persistence configured"
  info "Verify any time with: systemctl is-enabled proxdeploy nginx cloudflared"
else
  warn "Automatic start is OFF. After a reboot, start it yourself with:"
  info "sudo systemctl start proxdeploy"
fi

# --- 5e. tunnel ingress ---
step "Cloudflare Tunnel ingress"
CF_CONF=""
for f in /etc/cloudflared/config.yml "$HOME/.cloudflared/config.yml"; do
  sudo test -r "$f" 2>/dev/null && { CF_CONF="$f"; break; }
done

if [ -z "$CF_CONF" ]; then
  warn "No cloudflared config.yml found — add the ingress rules by hand."
  printf '    %sSee docs/SETUP.md, Step 6.%s\n' "$DIM" "$R"
elif ! confirm "Route $DASH_HOST and each domain (apex + wildcard) through $CF_CONF?" y; then
  info "Skipped. Add them yourself — see docs/SETUP.md, Step 6."
else
  backup "$CF_CONF"
  TMP_CONF="$(mktemp)"
  sudo cat "$CF_CONF" > "$TMP_CONF"

  DASH_HOST="$DASH_HOST" DASH_PORT="$DASH_PORT" DOMAIN_LIST="$(echo "$DOMAINS_PAIRS" | sed 's/:[0-9a-f]*//g')" \
  python3 - "$TMP_CONF" <<'PY'
import os, re, sys
path = sys.argv[1]
lines = open(path).read().splitlines()
host, port = os.environ["DASH_HOST"], os.environ["DASH_PORT"]
domains = [d for d in os.environ["DOMAIN_LIST"].split(",") if d]
text = "\n".join(lines)

want = [(host, f"http://localhost:{port}")]
for domain in domains:
    for h in (f"*.{domain}", domain):
        want.append((h, "http://localhost:80"))

# Only add hostnames that aren't already routed somewhere.
new = [(h, s) for h, s in want if not re.search(r'hostname:\s*"?' + re.escape(h) + r'"?\s*$', text, re.M)]
if not new:
    print("SKIP: every hostname is already in the ingress list")
    sys.exit(0)

# The catch-all must stay last, so insert immediately above it.
idx = next((i for i, l in enumerate(lines) if "http_status:404" in l), None)
if idx is None:
    print("ERROR: no 'service: http_status:404' catch-all found — not editing")
    sys.exit(2)

# Match the catch-all's own indentation so the inserted block lines up.
m = re.match(r'^(\s*)-', lines[idx])
indent = m.group(1) if m else "  "
block = []
for h, s in new:
    quoted = f'"{h}"' if "*" in h else h
    block.append(f"{indent}- hostname: {quoted}")
    block.append(f"{indent}  service: {s}")

open(path, "w").write("\n".join(lines[:idx] + block + lines[idx:]) + "\n")
print("ADDED: " + ", ".join(h for h, _ in new))
PY
  RC=$?

  if [ $RC -eq 0 ]; then
    if cloudflared tunnel --config "$TMP_CONF" ingress validate >/dev/null 2>&1 \
       || ! command -v cloudflared >/dev/null; then
      sudo install -m 0644 "$TMP_CONF" "$CF_CONF"
      ok "Updated $CF_CONF"
      if confirm "Restart cloudflared now to apply it?" y; then
        sudo systemctl restart cloudflared && sleep 2
        systemctl is-active --quiet cloudflared \
          && ok "cloudflared restarted and active" \
          || warn "cloudflared is not active — check: systemctl status cloudflared"
      else
        warn "Not applied yet. Run: sudo systemctl restart cloudflared"
      fi
    else
      warn "cloudflared rejected the edited config — leaving your original in place."
      info "Add the rules by hand; see docs/SETUP.md, Step 6."
    fi
  elif [ $RC -eq 2 ]; then
    warn "Couldn't find the http_status:404 catch-all — not touching your config."
  fi
  rm -f "$TMP_CONF"
fi

# --- 5f. dashboard DNS ---
step "DNS records"
ZONE_ID="$(echo "$DOMAINS_PAIRS" | tr ',' '\n' | grep "^$DOMAIN:" | cut -d: -f2)"
CONTENT="$DOMAIN"
[ -n "$CF_TUNNEL_ID" ] && CONTENT="$CF_TUNNEL_ID.cfargotunnel.com"

EXISTING="$(cf_api GET "/zones/$ZONE_ID/dns_records?name=$DASH_HOST" | json_get result 0 id)"
if [ -n "$EXISTING" ]; then
  ok "A DNS record for $DASH_HOST already exists — leaving it alone"
else
  BODY="{\"type\":\"CNAME\",\"name\":\"$DASH_HOST\",\"content\":\"$CONTENT\",\"proxied\":true,\"ttl\":1}"
  if [ "$(cf_api POST "/zones/$ZONE_ID/dns_records" "$BODY" | json_get success)" = "True" ]; then
    ok "Created CNAME $DASH_HOST → $CONTENT (proxied)"
  else
    warn "Could not create the DNS record — add it by hand:"
    info "CNAME  $DASH_HOST  →  $CONTENT  (proxied)"
  fi
fi

# Each domain's apex has to reach the tunnel too: a new site's record is a
# CNAME to its apex (blog.example.com → example.com), so it goes wherever the
# apex goes. On a fresh domain the apex has no record and every site would
# fail to resolve. An apex that already points somewhere else (an existing
# website) is left alone, with a warning, since taking it over would take that
# website down.
if [ -n "$CF_TUNNEL_ID" ]; then
  TUNNEL_HOST="$CF_TUNNEL_ID.cfargotunnel.com"
  IFS=',' read -r -a PAIRS <<< "$DOMAINS_PAIRS"
  for pair in "${PAIRS[@]}"; do
    d="${pair%%:*}"; z="${pair#*:}"
    RESP="$(cf_api GET "/zones/$z/dns_records?name=$d")"
    RTYPE="$(echo "$RESP" | json_get result 0 type)"
    RCONT="$(echo "$RESP" | json_get result 0 content)"
    if [ -z "$RTYPE" ]; then
      BODY="{\"type\":\"CNAME\",\"name\":\"$d\",\"content\":\"$TUNNEL_HOST\",\"proxied\":true,\"ttl\":1}"
      if [ "$(cf_api POST "/zones/$z/dns_records" "$BODY" | json_get success)" = "True" ]; then
        ok "Created CNAME $d → tunnel (proxied)"
      else
        warn "Could not create the apex record for $d — add it by hand:"
        info "CNAME  $d  →  $TUNNEL_HOST  (proxied)"
      fi
    elif [ "$RCONT" = "$TUNNEL_HOST" ]; then
      ok "$d already points at this tunnel"
    else
      warn "$d already has a $RTYPE record ($RCONT), so it was left alone."
      warn "Sites on $d follow the apex, so they won't reach this machine until"
      warn "the apex points at the tunnel. Deploying a landing page to $d in"
      warn "ProxDeploy does that, or change the record to: CNAME → $TUNNEL_HOST"
    fi
  done
else
  warn "No tunnel ID, so the domains' apex records weren't checked."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
printf '\n%s┌────────────────────────────────────────┐\n' "$B$GRN"
printf '│   ProxDeploy is installed              │\n'
printf '└────────────────────────────────────────┘%s\n\n' "$R"

cat <<DONE
  ${B}1. Open the dashboard${R}
       https://$DASH_HOST
     Sign in with the password you just chose. Change it any time with:
       ./setup.sh --password

  ${B}2. Install the CLI on your laptop${R} (optional)
       mkdir -p ~/.local/bin
       scp $RUN_USER@$(hostname):$APP_DIR/cli/proxdeploy ~/.local/bin/proxdeploy
       chmod +x ~/.local/bin/proxdeploy
       proxdeploy setup

     Your API key is:
       ${DIM}$API_KEY${R}

  ${B}3. Deploy something${R}
       proxdeploy deploy https://github.com/you/a-static-site test

  ${B}4. Test that it survives a reboot${R} (worth doing once, now)
       sudo reboot
     Then, once it is back:
       systemctl is-enabled proxdeploy nginx cloudflared   ${DIM}# 3x "enabled"${R}
       systemctl is-active  proxdeploy nginx cloudflared   ${DIM}# 3x "active"${R}

  ${DIM}Config:   $APP_DIR/.env  (mode 600 — keep it out of git)
  Logs:     sudo journalctl -u proxdeploy -f
  Restart:  sudo systemctl restart proxdeploy
  Backups:  every file this script replaced is saved as *.bak-<timestamp>${R}

  ${YLW}Recommended:${R} put Cloudflare Access in front of $DASH_HOST for a
  second authentication layer. See docs/SECURITY.md.

DONE
