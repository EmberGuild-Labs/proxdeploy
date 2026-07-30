#!/usr/bin/env bash
#
# ProxDeploy installer — run this on the machine that will host your sites.
#
#     ./setup.sh
#
# Asks for your domains, Cloudflare token, and GitHub token, then does the rest:
# virtualenv, .env, sudoers rule, systemd service, tunnel ingress, and DNS for
# the dashboard itself.
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

case "${1:-}" in
  -h|--help)
    sed -n '3,12p' "$0" | sed 's/^# \?//'
    exit 0 ;;
esac

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

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

for c in nginx cloudflared; do
  if command -v "$c" >/dev/null; then
    ok "$c found at $(command -v "$c")"
  else
    warn "$c is NOT installed."
    printf '    %sProxDeploy manages nginx and cloudflared but does not install\n' "$DIM"
    printf '    them. Set up a working Cloudflare Tunnel first.%s\n' "$R"
    confirm "Continue anyway?" n || exit 1
  fi
done

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
    ZID="$(cf_api GET "/zones?name=$d" | json_get result 0 id)"
    if [ -z "$ZID" ]; then
      warn "No Cloudflare zone found for '$d' — is the domain on this account,"
      warn "and does the token's Zone Resources include it?"
      FAILED=1; continue
    fi
    ok "$d → zone ${ZID:0:8}…"
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

CF_TUNNEL_ID=""
if command -v cloudflared >/dev/null; then
  CF_TUNNEL_ID="$(cloudflared tunnel list 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1)"
fi
if [ -z "$CF_TUNNEL_ID" ]; then
  for f in /etc/cloudflared/config.yml "$HOME/.cloudflared/config.yml"; do
    [ -r "$f" ] || continue
    CF_TUNNEL_ID="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$f" | head -1)"
    [ -n "$CF_TUNNEL_ID" ] && break
  done
fi

if [ -n "$CF_TUNNEL_ID" ]; then
  ok "Detected tunnel $CF_TUNNEL_ID"
  confirm "Use this tunnel?" y || CF_TUNNEL_ID="$(ask 'Tunnel UUID (blank to skip)')"
else
  warn "Couldn't detect a tunnel automatically."
  info "Find it with: cloudflared tunnel list"
  CF_TUNNEL_ID="$(ask 'Tunnel UUID (blank to skip)')"
fi
[ -z "$CF_TUNNEL_ID" ] && warn "No tunnel ID — you won't be able to deploy a domain root (landing page)."

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
  Tunnel              ${CF_TUNNEL_ID:-(none)}
  Private repos       $([ -n "$GITHUB_TOKEN" ] && echo yes || echo no)
  Dashboard           https://$DASH_HOST  →  localhost:$DASH_PORT

  From here on, files are written to your system.
SUMMARY
confirm "Proceed?" y || { printf '\n  Aborted. Nothing was changed.\n\n'; exit 0; }

# --- 5a. virtualenv ---
step "Python environment"
if [ -d "$APP_DIR/venv" ]; then
  info "venv already exists — reusing it"
else
  python3 -m venv "$APP_DIR/venv" || die "Could not create the virtualenv."
  ok "Created venv/"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip >/dev/null 2>&1
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt" \
  || die "pip install failed. Run it by hand to see why:
  $APP_DIR/venv/bin/pip install -r requirements.txt"
ok "Installed flask, bcrypt, requests"

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
elif ! confirm "Add ingress rules for $DASH_HOST and *.$DOMAIN to $CF_CONF?" y; then
  info "Skipped. Add them yourself — see docs/SETUP.md, Step 6."
else
  backup "$CF_CONF"
  TMP_CONF="$(mktemp)"
  sudo cat "$CF_CONF" > "$TMP_CONF"

  DASH_HOST="$DASH_HOST" DASH_PORT="$DASH_PORT" DOMAIN="$DOMAIN" \
  python3 - "$TMP_CONF" <<'PY'
import os, re, sys
path = sys.argv[1]
lines = open(path).read().splitlines()
host, port, domain = os.environ["DASH_HOST"], os.environ["DASH_PORT"], os.environ["DOMAIN"]
text = "\n".join(lines)

want = [(host, f"http://localhost:{port}")]
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
    if cloudflared tunnel ingress validate --config "$TMP_CONF" >/dev/null 2>&1 \
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
step "DNS for the dashboard"
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

# ─── Done ─────────────────────────────────────────────────────────────────────
printf '\n%s┌────────────────────────────────────────┐\n' "$B$GRN"
printf '│   ProxDeploy is installed              │\n'
printf '└────────────────────────────────────────┘%s\n\n' "$R"

cat <<DONE
  ${B}1. Open the dashboard${R}
       https://$DASH_HOST
     On your first visit you will ${B}set the dashboard password${R}. Choose a
     strong one — anyone with it can run code on this machine.

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
