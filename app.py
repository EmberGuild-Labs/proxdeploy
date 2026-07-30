import os
import re
import json
import secrets
import subprocess
import threading
import time
import requests
import bcrypt
from datetime import datetime
from pathlib import Path
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from functools import wraps
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)
# Prefix-aware: when nginx mounts the dashboard under a sub-path it sends
# X-Forwarded-Prefix, and url_for/redirects pick it up automatically.
app.wsgi_app = ProxyFix(app.wsgi_app, x_prefix=1, x_proto=1)
app.secret_key = os.environ.get("SECRET_KEY", "change-this-in-production-please")

# ── Config ────────────────────────────────────────────────────────────────────
CONFIG_FILE  = "config.json"
SERVICES_DIR = "services"
LOG_DIR      = "logs"
WWW_ROOT     = "/var/www"
NGINX_SITES  = "/etc/nginx/sites-available"
NGINX_ENABLED = "/etc/nginx/sites-enabled"

# ── Domains ───────────────────────────────────────────────────────────────────
# Multi-domain support. DOMAIN stays the *default* — every service deployed
# before multi-domain support has no "domain" field and is assumed to be on it.
DOMAIN = os.environ.get("DOMAIN", "example.com")

CF_API_TOKEN = os.environ.get("CF_API_TOKEN", "YOUR_CLOUDFLARE_API_TOKEN")
CF_ZONE_ID   = os.environ.get("CF_ZONE_ID",   "YOUR_CLOUDFLARE_ZONE_ID")
CF_API_BASE  = "https://api.cloudflare.com/client/v4"

# Tunnel UUID — needed only for apex records (an apex CNAME can't point at
# itself, so it goes straight to <uuid>.cfargotunnel.com). Subdomains keep
# CNAME-ing to their apex, which is the arrangement already proven in prod.
CF_TUNNEL_ID = os.environ.get("CF_TUNNEL_ID", "")

def _parse_domains():
    """DOMAINS="example.com:zoneid,example.org:zoneid" → {domain: zone_id}.

    Deliberately not JSON: this is read by systemd's EnvironmentFile=, which
    does not handle quoting reliably. Falls back to the single-domain
    DOMAIN/CF_ZONE_ID pair so an un-migrated .env keeps working."""
    raw = os.environ.get("DOMAINS", "").strip()
    out = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair or ":" not in pair:
            continue
        name, _, zone = pair.partition(":")
        name, zone = name.strip().lower(), zone.strip()
        if name and zone:
            out[name] = zone
    out.setdefault(DOMAIN, CF_ZONE_ID)
    return out

DOMAINS = _parse_domains()

def zone_for(domain):
    return DOMAINS.get((domain or "").lower())

def valid_domain(domain):
    return (domain or "").lower() in DOMAINS

def make_fqdn(subdomain, domain):
    """'' or '@' means the apex (the bare domain itself)."""
    sub = (subdomain or "").strip().strip(".").lower()
    if sub in ("", "@"):
        return domain
    return f"{sub}.{domain}"

def service_key(subdomain, domain):
    """The config.json key / nginx filename for a site.

    Sites on the default domain keep their bare name so nothing existing has
    to be migrated; everything else is keyed by full FQDN, which also means a
    name can never collide across two domains."""
    if (domain or "").lower() == DOMAIN:
        return (subdomain or "").strip().strip(".").lower()
    return make_fqdn(subdomain, domain)

def svc_domain(svc):
    return (svc or {}).get("domain") or DOMAIN

def svc_fqdn(key, svc=None):
    """Full hostname for a service. Legacy records have neither field, so fall
    back to the pre-multi-domain assumption: <key>.<default domain>."""
    svc = svc or {}
    if svc.get("fqdn"):
        return svc["fqdn"]
    return make_fqdn(svc.get("subdomain", key), svc_domain(svc))

API_KEY = os.environ.get("API_KEY", "")

# GitHub Personal Access Token — set in .env to deploy/update private repos.
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")

# Sites allowed to appear on the unauthenticated /api/public/status feed.
# Empty (the default) disables that endpoint entirely — the full service list
# is not public information, so this is opt-in per site rather than opt-out.
PUBLIC_STATUS = {
    s.strip().lower()
    for s in os.environ.get("PUBLIC_STATUS", "").split(",")
    if s.strip()
}

# Subdomains may be nested (api.site) — dots allowed between labels
SUBDOMAIN_RE = re.compile(r'^[a-z0-9\-]+(\.[a-z0-9\-]+)*$')
EXT_PATH_RE  = re.compile(r'^[a-z0-9\-]+$')
UNIT_RE      = re.compile(r'^[A-Za-z0-9@_.\-]+$')

# All reads/writes of config.json go through this lock so background deploy /
# update threads can't clobber each other's changes (previously each thread
# held a stale full copy of the config and saved it wholesale — services
# could vanish or get stuck).
config_lock = threading.RLock()

# ── Helpers ───────────────────────────────────────────────────────────────────
def load_config():
    with config_lock:
        if not os.path.exists(CONFIG_FILE):
            return {"password_hash": None, "services": {}}
        with open(CONFIG_FILE) as f:
            return json.load(f)

def save_config(cfg):
    # Atomic write: never leave a half-written config.json if we crash mid-save
    with config_lock:
        tmp = CONFIG_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(cfg, f, indent=2)
        os.replace(tmp, CONFIG_FILE)

def update_service(subdomain, **fields):
    """Reload config, apply changes to one service, save. Thread-safe."""
    with config_lock:
        cfg = load_config()
        svc = cfg.get("services", {}).get(subdomain)
        if svc is None:
            return None
        svc.update(fields)
        save_config(cfg)
        return svc

def log(name, line, level="INFO"):
    os.makedirs(LOG_DIR, exist_ok=True)
    if GITHUB_TOKEN:
        # Git errors can echo the tokenised URL — never let the token hit a log file
        line = line.replace(GITHUB_TOKEN, "***")
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    entry = f"[{ts}] [{level}] {line}\n"
    with open(f"{LOG_DIR}/{name}.log", "a") as f:
        f.write(entry)

def read_log(name):
    path = f"{LOG_DIR}/{name}.log"
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return f.readlines()[-200:]  # last 200 lines

def run_cmd(cmd, cwd=None, name=None):
    """Run a shell command, log output, return (success, output)."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, cwd=cwd, timeout=120
        )
        out = result.stdout + result.stderr
        if name:
            level = "INFO" if result.returncode == 0 else "ERROR"
            for line in out.splitlines():
                log(name, line, level)
        return result.returncode == 0, out
    except subprocess.TimeoutExpired:
        if name:
            log(name, "Command timed out", "ERROR")
        return False, "Command timed out"

def git_cmd(args):
    """Build a sudo git command. If GITHUB_TOKEN is set, transparently
    authenticate any https://github.com/ URL (works for clone AND pull,
    without ever storing the token in the repo's .git/config)."""
    if GITHUB_TOKEN:
        rewrite = (f"-c url.https://x-access-token:{GITHUB_TOKEN}@github.com/"
                   f".insteadOf=https://github.com/")
        return f"sudo git {rewrite} {args}"
    return f"sudo git {args}"

def valid_subdomain(sub):
    return bool(sub) and bool(SUBDOMAIN_RE.match(sub))

def valid_site_name(sub):
    """Like valid_subdomain, but '' / '@' are allowed — they mean the apex."""
    sub = (sub or "").strip().strip(".").lower()
    return sub in ("", "@") or bool(SUBDOMAIN_RE.match(sub))

def valid_ext_path(p):
    return bool(p) and bool(EXT_PATH_RE.match(p))

def valid_unit(unit):
    return bool(unit) and bool(UNIT_RE.match(unit))

def get_service_or_error(data):
    """Common lookup for POST routes: returns (subdomain, svc, error_response)."""
    subdomain = (data.get("subdomain") or "").strip().lower()
    if not valid_subdomain(subdomain):
        return None, None, jsonify({"ok": False, "error": "Invalid subdomain."})
    svc = load_config().get("services", {}).get(subdomain)
    if not svc:
        return None, None, jsonify({"ok": False, "error": "Service not found."})
    return subdomain, svc, None

# ── Cloudflare DNS ────────────────────────────────────────────────────────────
def cf_headers():
    return {
        "Authorization": f"Bearer {CF_API_TOKEN}",
        "Content-Type": "application/json"
    }

def cf_find_record(zone_id, name):
    """Return an existing record's id for this hostname, or None."""
    try:
        r = requests.get(f"{CF_API_BASE}/zones/{zone_id}/dns_records",
                         headers=cf_headers(), params={"name": name}, timeout=10)
        results = r.json().get("result") or []
        return results[0]["id"] if results else None
    except Exception:
        return None

def cf_add_dns(subdomain, domain=None):
    """Point a hostname at the tunnel.

    Subdomains CNAME to their apex; the apex itself CNAMEs to the tunnel
    directly (a record can't point at itself). Cloudflare's CNAME flattening
    makes an apex CNAME legal. Returns (ok, record_id_or_error)."""
    domain  = (domain or DOMAIN).lower()
    zone_id = zone_for(domain)
    if not zone_id:
        return False, f"No Cloudflare zone ID configured for {domain}."

    name    = make_fqdn(subdomain, domain)
    is_apex = (name == domain)
    if is_apex:
        if not CF_TUNNEL_ID:
            return False, ("CF_TUNNEL_ID is not set — an apex record must point "
                           "at <tunnel-id>.cfargotunnel.com. Add it to .env.")
        content = f"{CF_TUNNEL_ID}.cfargotunnel.com"
    else:
        content = domain

    url  = f"{CF_API_BASE}/zones/{zone_id}/dns_records"
    data = {"type": "CNAME", "name": name, "content": content,
            "proxied": True, "ttl": 1}
    try:
        r = requests.post(url, headers=cf_headers(), json=data, timeout=10)
        resp = r.json()
        if resp.get("success"):
            return True, resp["result"]["id"]

        # A parked/placeholder record already on this hostname (very common at
        # the apex of a freshly-registered domain) — take it over rather than
        # making the deploy fail.
        existing = cf_find_record(zone_id, name)
        if existing:
            r2 = requests.put(f"{url}/{existing}", headers=cf_headers(),
                              json=data, timeout=10)
            if r2.json().get("success"):
                return True, existing
        return False, resp.get("errors", "Unknown error")
    except Exception as e:
        return False, str(e)

def cf_delete_dns(record_id, domain=None):
    zone_id = zone_for(domain or DOMAIN)
    if not zone_id:
        return False
    url = f"{CF_API_BASE}/zones/{zone_id}/dns_records/{record_id}"
    try:
        r = requests.delete(url, headers=cf_headers(), timeout=10)
        return r.json().get("success", False)
    except:
        return False

# ── Nginx config generator ────────────────────────────────────────────────────
def ext_web_root(subdomain, path):
    return f"{WWW_ROOT}/{subdomain}--{path}"

def _ext_location_blocks(extensions):
    """location blocks for path extensions (site.example.com/<path>)."""
    parts = []
    for path, ext in sorted((extensions or {}).items()):
        parts.append(f"""
    location = /{path} {{ return 301 /{path}/; }}""")
        if ext.get("port"):
            # X-Forwarded-Prefix lets prefix-aware apps (Flask ProxyFix with
            # x_prefix=1) generate correct /path/... URLs for assets/redirects
            parts.append(f"""
    location /{path}/ {{
        proxy_pass http://127.0.0.1:{ext["port"]}/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Prefix /{path};
    }}""")
        else:
            parts.append(f"""
    location /{path}/ {{
        alias {ext["web_root"]}/;
        index index.html index.htm;
        try_files $uri $uri/ =404;
    }}""")
    return "".join(parts)

def write_nginx_config(key, fqdn, web_root, port=None, extensions=None):
    """
    Static sites: serve from web_root.
    Dynamic sites (port set): reverse-proxy to localhost:port.
    Extensions get their own location blocks (longest prefix wins in nginx,
    so /blog/ takes priority over the site's / handler either way).

    `key` names the config file, `fqdn` is the hostname served — they differ
    for any site that isn't on the default domain.
    """
    ext_blocks = _ext_location_blocks(extensions)
    if port:
        block = f"""server {{
    listen 80;
    server_name {fqdn};
{ext_blocks}

    location / {{
        proxy_pass http://127.0.0.1:{port};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }}
}}
"""
    else:
        block = f"""server {{
    listen 80;
    server_name {fqdn};

    root {web_root};
    index index.html index.htm;

    # nginx listens on plain :80 behind the tunnel, so it builds directory
    # redirects (/foo -> /foo/) as http://, downgrading the visitor's scheme.
    # Relative redirects keep whatever scheme the browser already used.
    absolute_redirect off;

    # Opt-in custom error page: a site that ships a /404.html gets it, and one
    # that doesn't falls through to nginx's built-in 404 exactly as before.
    error_page 404 /404.html;
    location = /404.html {{ internal; }}
{ext_blocks}

    location / {{
        try_files $uri $uri/ =404;
    }}

    # Allow file downloads
    location ~* \\.(zip|tar\\.gz|gz|dmg|exe|AppImage|deb|rpm|apk|pdf)$ {{
        add_header Content-Disposition "attachment";
    }}
}}
"""
    cfg_path = f"{NGINX_SITES}/{key}"
    with open(cfg_path, "w") as f:
        f.write(block)
    # Enable it (lexists so a dangling symlink is detected too)
    link = f"{NGINX_ENABLED}/{key}"
    if not os.path.lexists(link):
        os.symlink(cfg_path, link)
    return cfg_path

def write_redirect_config(key, fqdn, target, preserve_path=False):
    """A redirect 'site' is just a server block that 301s elsewhere."""
    suffix = "$request_uri" if preserve_path else ""
    block = f"""server {{
    listen 80;
    server_name {fqdn};

    return 301 {target}{suffix};
}}
"""
    cfg_path = f"{NGINX_SITES}/{key}"
    with open(cfg_path, "w") as f:
        f.write(block)
    link = f"{NGINX_ENABLED}/{key}"
    if not os.path.lexists(link):
        os.symlink(cfg_path, link)
    return cfg_path

def normalize_redirect_target(target):
    """Returns (ok, normalized_or_error). Keeps nginx config injection out."""
    target = (target or "").strip()
    if not target:
        return False, "Give a target URL."
    if not re.match(r'^https?://', target):
        target = "https://" + target
    # No whitespace, quotes, or nginx config syntax allowed in the URL
    if re.search(r'[\s;{}"\'\\$]', target):
        return False, "Target URL contains invalid characters."
    return True, target

def write_site_config(key, svc):
    """Regenerate a site's full nginx config from its stored metadata."""
    fqdn = svc_fqdn(key, svc)
    if svc.get("redirect_to"):
        return write_redirect_config(key, fqdn, svc["redirect_to"], svc.get("preserve_path"))
    return write_nginx_config(
        key,
        fqdn,
        svc.get("web_root", f"{WWW_ROOT}/{key}"),
        port=int(svc["port"]) if svc.get("port") else None,
        extensions=svc.get("extensions") or {},
    )

PAUSED_HTML = (
    "<!doctype html><html><head><meta charset=utf-8>"
    "<meta name=viewport content=\"width=device-width,initial-scale=1\">"
    "<title>Site paused</title>"
    "<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;"
    "background:#0b0e14;color:#e2e8f0;font-family:system-ui,sans-serif;text-align:center}"
    "h1{font-size:26px;margin:0 0 10px}p{color:#64748b;margin:0}"
    ".dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:#eab308;margin-right:8px}"
    "</style></head><body><div><h1><span class=dot></span>Site paused</h1>"
    "<p>This site is temporarily paused to save resources. Check back soon.</p></div></body></html>"
)

def write_paused_config(key, fqdn):
    """Swap the site's nginx config for a lightweight 'paused' page."""
    block = f"""server {{
    listen 80;
    server_name {fqdn};

    location / {{
        default_type text/html;
        return 503 '{PAUSED_HTML}';
    }}
}}
"""
    cfg_path = f"{NGINX_SITES}/{key}"
    with open(cfg_path, "w") as f:
        f.write(block)
    link = f"{NGINX_ENABLED}/{key}"
    if not os.path.lexists(link):
        os.symlink(cfg_path, link)

def remove_nginx_config(subdomain):
    # lexists (not exists) so dangling symlinks in sites-enabled are removed
    # too — a leftover broken symlink makes nginx -t fail for every site.
    for path in [f"{NGINX_ENABLED}/{subdomain}", f"{NGINX_SITES}/{subdomain}"]:
        if os.path.lexists(path):
            os.remove(path)

def reload_nginx(name):
    ok, out = run_cmd("sudo nginx -t && sudo systemctl reload nginx", name=name)
    return ok, out

def restart_cf_tunnel(name):
    ok, out = run_cmd("sudo systemctl restart cloudflared", name=name)
    return ok, out

def systemctl_unit(action, unit, name):
    """start/stop/restart a site's own systemd service."""
    if not valid_unit(unit):
        log(name, f"Invalid systemd unit name: {unit!r}", "ERROR")
        return False
    if not unit.endswith(".service"):
        unit += ".service"
    ok, _ = run_cmd(f"sudo systemctl {action} {unit}", name=name)
    log(name, f"systemctl {action} {unit} {'succeeded' if ok else 'FAILED'}",
        "INFO" if ok else "ERROR")
    return ok

# ── Startup cleanup ───────────────────────────────────────────────────────────
def cleanup_stale_statuses():
    """If the app restarted mid-deploy/update, statuses stay stuck forever.
    Resolve them from what's actually on disk."""
    with config_lock:
        cfg = load_config()
        changed = False
        for name, svc in cfg.get("services", {}).items():
            if svc.get("status") in ("deploying", "updating"):
                enabled = os.path.lexists(f"{NGINX_ENABLED}/{name}")
                svc["status"] = "online" if enabled else "error"
                changed = True
        if changed:
            save_config(cfg)

# ── Auth ──────────────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        # API key auth: constant-time comparison prevents timing attacks
        incoming = request.headers.get("X-API-Key", "")
        if API_KEY and incoming and secrets.compare_digest(incoming, API_KEY):
            return f(*args, **kwargs)
        # Session auth (browser dashboard — unchanged)
        if session.get("logged_in"):
            return f(*args, **kwargs)
        # Return JSON for /api/* so callers get a parseable error
        if request.path.startswith("/api/"):
            return jsonify({"ok": False, "error": "Unauthorized"}), 401
        return redirect(url_for("login"))
    return decorated

# ── Routes ────────────────────────────────────────────────────────────────────
@app.route("/")
@login_required
def index():
    cfg = load_config()
    services = cfg.get("services", {})
    # Legacy records predate the domain/fqdn fields — fill them in for the
    # template so the UI never has to guess a hostname.
    fqdns = {key: svc_fqdn(key, svc) for key, svc in services.items()}
    return render_template(
        "index.html",
        services=services,
        domain=DOMAIN,
        domains=sorted(DOMAINS),
        fqdns=fqdns,
    )

@app.route("/login", methods=["GET", "POST"])
def login():
    cfg = load_config()
    error = None

    if request.method == "POST":
        pw = request.form.get("password", "").encode()
        stored = cfg.get("password_hash")

        if not stored:
            # First-time setup: set the password
            hashed = bcrypt.hashpw(pw, bcrypt.gensalt()).decode()
            cfg["password_hash"] = hashed
            save_config(cfg)
            session["logged_in"] = True
            return redirect(url_for("index"))

        if bcrypt.checkpw(pw, stored.encode()):
            session["logged_in"] = True
            return redirect(url_for("index"))
        else:
            error = "Incorrect password."

    first_time = not cfg.get("password_hash")
    return render_template("login.html", error=error, first_time=first_time)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

# ── Deploy ────────────────────────────────────────────────────────────────────
@app.route("/api/deploy", methods=["POST"])
@login_required
def deploy():
    data = request.json
    repo_url  = data.get("repo_url", "").strip()
    subdomain = data.get("subdomain", "").strip().strip(".").lower()
    domain    = (data.get("domain") or DOMAIN).strip().lower()
    port      = data.get("port")  # optional, for dynamic apps
    project   = (data.get("project") or "").strip()

    if not repo_url:
        return jsonify({"ok": False, "error": "Repo URL is required."})

    if not valid_domain(domain):
        return jsonify({"ok": False, "error": f"Unknown domain '{domain}'. Configured: {', '.join(sorted(DOMAINS))}."})

    if not valid_site_name(subdomain):
        return jsonify({"ok": False, "error": "Subdomain can only contain lowercase letters, numbers, hyphens, and dots (for nested subdomains like api.mysite). Leave it empty for the domain root."})

    key  = service_key(subdomain, domain)
    fqdn = make_fqdn(subdomain, domain)

    cfg = load_config()
    if key in cfg.get("services", {}):
        return jsonify({"ok": False, "error": f"'{fqdn}' is already deployed. Use Update instead."})

    def do_deploy():
        web_root = f"{WWW_ROOT}/{key}"
        log(key, f"Starting deploy of {repo_url} → {fqdn}")

        # Clone repo (git_cmd adds GitHub auth for private repos if configured)
        ok, out = run_cmd(git_cmd(f"clone {repo_url} {web_root}"), name=key)
        if not ok:
            log(key, "Git clone failed — aborting.", "ERROR")
            update_service(key, status="error")
            return

        # Set permissions
        run_cmd(f"sudo chown -R www-data:www-data {web_root}", name=key)

        # Write Nginx config
        try:
            write_nginx_config(key, fqdn, web_root, port=int(port) if port else None)
            log(key, "Nginx config written.")
        except Exception as e:
            log(key, f"Failed to write Nginx config: {e}", "ERROR")
            update_service(key, status="error")
            return

        # Reload Nginx
        ok, _ = reload_nginx(key)
        if not ok:
            log(key, "Nginx reload failed.", "ERROR")
            update_service(key, status="error")
            return
        log(key, "Nginx reloaded.")

        # Cloudflare DNS
        ok, result = cf_add_dns(subdomain, domain)
        if ok:
            update_service(key, cf_record_id=result)
            log(key, f"Cloudflare DNS record created (ID: {result}).")
        else:
            log(key, f"Cloudflare DNS failed: {result} — add manually if needed.", "WARN")

        # Restart Cloudflare tunnel
        ok, _ = restart_cf_tunnel(key)
        log(key, "Cloudflare tunnel restarted." if ok else "Tunnel restart failed — may need manual restart.", "INFO" if ok else "WARN")

        update_service(key, status="online", deployed_at=datetime.now().isoformat())
        log(key, f"Deploy complete → https://{fqdn}")

    # Register service immediately so logs are trackable
    with config_lock:
        cfg = load_config()
        if "services" not in cfg:
            cfg["services"] = {}
        cfg["services"][key] = {
            "repo_url": repo_url,
            "subdomain": subdomain,
            "domain": domain,
            "fqdn": fqdn,
            "web_root": f"{WWW_ROOT}/{key}",
            "port": port,
            "project": project,
            "service_name": "",
            "extensions": {},
            "status": "deploying",
            "cf_record_id": None,
            "deployed_at": None
        }
        save_config(cfg)

    thread = threading.Thread(target=do_deploy, daemon=True)
    thread.start()

    return jsonify({"ok": True, "message": f"Deploying {fqdn} — check logs for progress."})

# ── Update ────────────────────────────────────────────────────────────────────
@app.route("/api/update", methods=["POST"])
@login_required
def update():
    subdomain, svc, err = get_service_or_error(request.json)
    if err:
        return err
    if svc.get("redirect_to"):
        return jsonify({"ok": False, "error": "Redirects have no repo to update — edit the redirect instead."})

    def do_update():
        web_root = svc["web_root"]
        log(subdomain, f"Starting update for {svc_fqdn(subdomain, svc)}")
        update_service(subdomain, status="updating")

        ok, out = run_cmd(git_cmd("pull"), cwd=web_root, name=subdomain)
        if not ok:
            log(subdomain, "git pull failed.", "ERROR")
            update_service(subdomain, status="error")
            return

        run_cmd(f"sudo chown -R www-data:www-data {web_root}", name=subdomain)
        ok, _ = reload_nginx(subdomain)
        log(subdomain, "Nginx reloaded." if ok else "Nginx reload failed.", "INFO" if ok else "ERROR")

        update_service(subdomain, status="online", updated_at=datetime.now().isoformat())
        log(subdomain, "Update complete.")

    thread = threading.Thread(target=do_update, daemon=True)
    thread.start()
    return jsonify({"ok": True, "message": f"Updating {subdomain} — check logs."})

# ── Delete ────────────────────────────────────────────────────────────────────
@app.route("/api/delete", methods=["POST"])
@login_required
def delete():
    subdomain, svc, err = get_service_or_error(request.json)
    if err:
        return err

    web_root  = svc.get("web_root", f"{WWW_ROOT}/{subdomain}")
    record_id = svc.get("cf_record_id")
    unit      = svc.get("service_name") or ""

    log(subdomain, f"Removing {svc_fqdn(subdomain, svc)}")

    # Stop the site's own systemd service so its process doesn't linger
    if unit:
        systemctl_unit("stop", unit, subdomain)

    # Remove files — only ever inside /var/www/<subdomain> (redirects have none)
    if svc.get("redirect_to"):
        pass
    elif re.match(rf'^{WWW_ROOT}/[a-z0-9.\-]+$', web_root):
        run_cmd(f"sudo rm -rf {web_root}", name=subdomain)
    else:
        log(subdomain, f"Refusing to delete suspicious path: {web_root}", "ERROR")

    # Remove any path-extension folders too (and stop their app services)
    for path, ext in (svc.get("extensions") or {}).items():
        if ext.get("service_name"):
            systemctl_unit("stop", ext["service_name"], subdomain)
        root = ext.get("web_root", "")
        if root != web_root and re.match(rf'^{WWW_ROOT}/[a-z0-9.\-]+(--[a-z0-9\-]+)?$', root):
            run_cmd(f"sudo rm -rf {root}", name=subdomain)

    # Remove Nginx config + symlink, then verify nginx is still happy
    remove_nginx_config(subdomain)
    ok, out = reload_nginx(subdomain)
    if not ok:
        log(subdomain, "Nginx reload failed after removal — other sites may be affected! Check config.", "ERROR")

    # Remove Cloudflare DNS
    if record_id:
        if cf_delete_dns(record_id, svc_domain(svc)):
            log(subdomain, "Cloudflare DNS record removed.")
        else:
            log(subdomain, "Failed to remove Cloudflare DNS record — delete it manually.", "WARN")

    with config_lock:
        cfg = load_config()
        cfg.get("services", {}).pop(subdomain, None)
        save_config(cfg)

    if not ok:
        return jsonify({"ok": False, "error": f"{subdomain} removed, but the Nginx reload failed — check its logs."})
    return jsonify({"ok": True, "message": f"{subdomain} removed."})

# ── Pause / Resume ────────────────────────────────────────────────────────────
@app.route("/api/pause", methods=["POST"])
@login_required
def pause():
    subdomain, svc, err = get_service_or_error(request.json)
    if err:
        return err
    if svc.get("status") == "paused":
        return jsonify({"ok": False, "error": f"{subdomain} is already paused."})

    log(subdomain, f"Pausing {svc_fqdn(subdomain, svc)}")

    # Stop the app process first (frees RAM/CPU) — extensions' apps too
    unit = svc.get("service_name") or ""
    if unit:
        systemctl_unit("stop", unit, subdomain)
    for ext in (svc.get("extensions") or {}).values():
        if ext.get("service_name"):
            systemctl_unit("stop", ext["service_name"], subdomain)

    # Swap nginx config for the 'paused' page
    try:
        write_paused_config(subdomain, svc_fqdn(subdomain, svc))
    except Exception as e:
        log(subdomain, f"Failed to write paused config: {e}", "ERROR")
        return jsonify({"ok": False, "error": "Could not write paused Nginx config — check logs."})

    ok, _ = reload_nginx(subdomain)
    if not ok:
        # Roll back so the site isn't left half-broken
        log(subdomain, "Nginx rejected paused config — rolling back.", "ERROR")
        try:
            write_site_config(subdomain, svc)
            reload_nginx(subdomain)
            if unit:
                systemctl_unit("start", unit, subdomain)
        except Exception as e:
            log(subdomain, f"Rollback failed: {e}", "ERROR")
        return jsonify({"ok": False, "error": "Nginx reload failed — pause rolled back."})

    update_service(subdomain, status="paused", paused_at=datetime.now().isoformat())
    log(subdomain, "Site paused — visitors now see the paused page.")
    return jsonify({"ok": True, "message": f"{subdomain} paused."})

@app.route("/api/resume", methods=["POST"])
@login_required
def resume():
    subdomain, svc, err = get_service_or_error(request.json)
    if err:
        return err
    if svc.get("status") != "paused":
        return jsonify({"ok": False, "error": f"{subdomain} is not paused."})

    log(subdomain, f"Resuming {svc_fqdn(subdomain, svc)}")

    # Restore the real nginx config (including any path extensions)
    try:
        write_site_config(subdomain, svc)
    except Exception as e:
        log(subdomain, f"Failed to restore Nginx config: {e}", "ERROR")
        return jsonify({"ok": False, "error": "Could not restore Nginx config — check logs."})

    # Start the app process back up — extensions' apps too
    unit = svc.get("service_name") or ""
    unit_ok = True
    if unit:
        unit_ok = systemctl_unit("start", unit, subdomain)
    for ext in (svc.get("extensions") or {}).values():
        if ext.get("service_name"):
            systemctl_unit("start", ext["service_name"], subdomain)

    ok, _ = reload_nginx(subdomain)
    if not ok:
        log(subdomain, "Nginx reload failed on resume.", "ERROR")
        return jsonify({"ok": False, "error": "Nginx reload failed — check logs."})

    update_service(subdomain, status="online", paused_at=None)
    log(subdomain, "Site resumed.")
    if not unit_ok:
        return jsonify({"ok": True, "message": f"{subdomain} resumed, but its app service failed to start — check logs."})
    return jsonify({"ok": True, "message": f"{subdomain} resumed."})

# ── Edit metadata (project group / systemd service name) ─────────────────────
@app.route("/api/edit", methods=["POST"])
@login_required
def edit():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err

    fields = {}
    if "project" in data:
        fields["project"] = (data.get("project") or "").strip()[:60]
    if "service_name" in data:
        unit = (data.get("service_name") or "").strip()
        if unit and not valid_unit(unit):
            return jsonify({"ok": False, "error": "Invalid systemd service name."})
        fields["service_name"] = unit
    if not fields:
        return jsonify({"ok": False, "error": "Nothing to update."})

    update_service(subdomain, **fields)
    return jsonify({"ok": True, "message": f"{subdomain} updated."})

# ── Path extensions (site.example.com/<path>) ────────────────────────────────
def regen_config_with_rollback(subdomain, svc):
    """Rewrite a site's nginx config; if nginx rejects it, restore the old one.
    Returns True on success."""
    cfg_path = f"{NGINX_SITES}/{subdomain}"
    old = None
    if os.path.exists(cfg_path):
        with open(cfg_path) as f:
            old = f.read()
    write_site_config(subdomain, svc)
    ok, _ = reload_nginx(subdomain)
    if not ok and old is not None:
        log(subdomain, "Nginx rejected new config — rolling back.", "ERROR")
        with open(cfg_path, "w") as f:
            f.write(old)
        reload_nginx(subdomain)
    return ok

@app.route("/api/ext/add", methods=["POST"])
@login_required
def ext_add():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err
    if svc.get("status") == "paused":
        return jsonify({"ok": False, "error": "Resume the site before editing its extensions."})

    path     = (data.get("path") or "").strip().strip("/").lower()
    repo_url = (data.get("repo_url") or "").strip()
    port     = data.get("port")
    if not valid_ext_path(path):
        return jsonify({"ok": False, "error": "Path can only contain lowercase letters, numbers, and hyphens."})
    if not repo_url and not port:
        return jsonify({"ok": False, "error": "Give a repo URL (static) and/or a port (dynamic)."})
    if path in (svc.get("extensions") or {}):
        return jsonify({"ok": False, "error": f"/{path} already exists on {subdomain}."})

    root = ext_web_root(subdomain, path)
    ext = {"path": path, "repo_url": repo_url, "port": port,
           "web_root": root, "status": "deploying",
           "added_at": datetime.now().isoformat()}

    def do_add():
        log(subdomain, f"Adding extension /{path} → {svc_fqdn(subdomain, svc)}/{path}")
        if repo_url:
            ok, _ = run_cmd(git_cmd(f"clone {repo_url} {root}"), name=subdomain)
            if not ok:
                log(subdomain, f"Git clone for /{path} failed — aborting.", "ERROR")
                with config_lock:
                    cfg = load_config()
                    cfg["services"][subdomain]["extensions"][path]["status"] = "error"
                    save_config(cfg)
                return
            run_cmd(f"sudo chown -R www-data:www-data {root}", name=subdomain)

        with config_lock:
            cfg = load_config()
            cur = cfg["services"].get(subdomain)
            if not cur:
                return
            ok = regen_config_with_rollback(subdomain, cur)
            cur["extensions"][path]["status"] = "online" if ok else "error"
            save_config(cfg)
        log(subdomain, f"Extension /{path} is live." if ok else f"Extension /{path} failed — nginx rejected the config.",
            "INFO" if ok else "ERROR")

    with config_lock:
        cfg = load_config()
        cfg["services"][subdomain].setdefault("extensions", {})[path] = ext
        save_config(cfg)

    threading.Thread(target=do_add, daemon=True).start()
    return jsonify({"ok": True, "message": f"Adding /{path} to {svc_fqdn(subdomain, svc)} — check logs."})

@app.route("/api/ext/update", methods=["POST"])
@login_required
def ext_update():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err
    path = (data.get("path") or "").strip().strip("/").lower()
    ext = (svc.get("extensions") or {}).get(path)
    if not ext:
        return jsonify({"ok": False, "error": "Extension not found."})
    if not ext.get("repo_url"):
        return jsonify({"ok": False, "error": "This extension has no repo to pull."})

    def do_update():
        log(subdomain, f"Updating extension /{path}")
        ok, _ = run_cmd(git_cmd("pull"), cwd=ext["web_root"], name=subdomain)
        if ok:
            run_cmd(f"sudo chown -R www-data:www-data {ext['web_root']}", name=subdomain)
        log(subdomain, f"Extension /{path} updated." if ok else f"git pull for /{path} failed.",
            "INFO" if ok else "ERROR")

    threading.Thread(target=do_update, daemon=True).start()
    return jsonify({"ok": True, "message": f"Updating /{path} — check logs."})

@app.route("/api/ext/remove", methods=["POST"])
@login_required
def ext_remove():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err
    if svc.get("status") == "paused":
        return jsonify({"ok": False, "error": "Resume the site before editing its extensions."})
    path = (data.get("path") or "").strip().strip("/").lower()
    ext = (svc.get("extensions") or {}).get(path)
    if not ext:
        return jsonify({"ok": False, "error": "Extension not found."})

    log(subdomain, f"Removing extension /{path}")
    if ext.get("service_name"):
        systemctl_unit("stop", ext["service_name"], subdomain)
    root = ext.get("web_root", "")
    if re.match(rf'^{WWW_ROOT}/[a-z0-9.\-]+(--[a-z0-9\-]+)?$', root):
        run_cmd(f"sudo rm -rf {root}", name=subdomain)

    with config_lock:
        cfg = load_config()
        cur = cfg["services"].get(subdomain)
        if not cur:
            return jsonify({"ok": False, "error": "Service not found."})
        cur.get("extensions", {}).pop(path, None)
        ok = regen_config_with_rollback(subdomain, cur)
        save_config(cfg)

    if not ok:
        return jsonify({"ok": False, "error": f"/{path} removed from config, but the Nginx reload failed — check logs."})
    log(subdomain, f"Extension /{path} removed.")
    return jsonify({"ok": True, "message": f"/{path} removed from {svc_fqdn(subdomain, svc)}."})

# ── Redirects ─────────────────────────────────────────────────────────────────
@app.route("/api/redirect/add", methods=["POST"])
@login_required
def redirect_add():
    data = request.json
    subdomain = (data.get("subdomain") or "").strip().strip(".").lower()
    domain    = (data.get("domain") or DOMAIN).strip().lower()
    project   = (data.get("project") or "").strip()
    preserve  = bool(data.get("preserve_path"))

    if not valid_domain(domain):
        return jsonify({"ok": False, "error": f"Unknown domain '{domain}'."})
    if not valid_site_name(subdomain):
        return jsonify({"ok": False, "error": "Invalid subdomain."})
    ok, target = normalize_redirect_target(data.get("target"))
    if not ok:
        return jsonify({"ok": False, "error": target})

    key  = service_key(subdomain, domain)
    fqdn = make_fqdn(subdomain, domain)

    with config_lock:
        cfg = load_config()
        if key in cfg.get("services", {}):
            return jsonify({"ok": False, "error": f"'{fqdn}' already exists."})

        svc = {
            "repo_url": "",
            "subdomain": subdomain,
            "domain": domain,
            "fqdn": fqdn,
            "web_root": "",
            "port": None,
            "project": project,
            "service_name": "",
            "extensions": {},
            "redirect_to": target,
            "preserve_path": preserve,
            "status": "online",
            "cf_record_id": None,
            "deployed_at": datetime.now().isoformat(),
        }
        log(key, f"Adding redirect {fqdn} → {target}")
        write_site_config(key, svc)
        nginx_ok, _ = reload_nginx(key)
        if not nginx_ok:
            remove_nginx_config(key)
            reload_nginx(key)
            return jsonify({"ok": False, "error": "Nginx rejected the redirect config — nothing was added."})

        cfg.setdefault("services", {})[key] = svc
        save_config(cfg)

    dns_ok, result = cf_add_dns(subdomain, domain)
    if dns_ok:
        update_service(key, cf_record_id=result)
        log(key, "DNS record created.")
    else:
        log(key, f"DNS failed: {result} — add manually if needed.", "WARN")

    log(key, f"Redirect live → {fqdn} → {target}")
    return jsonify({"ok": True, "message": f"{fqdn} now redirects to {target}"})

@app.route("/api/redirect/edit", methods=["POST"])
@login_required
def redirect_edit():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err
    if not svc.get("redirect_to"):
        return jsonify({"ok": False, "error": "That site is not a redirect."})
    ok, target = normalize_redirect_target(data.get("target"))
    if not ok:
        return jsonify({"ok": False, "error": target})
    preserve = bool(data.get("preserve_path"))

    with config_lock:
        cfg = load_config()
        cur = cfg.get("services", {}).get(subdomain)
        if not cur:
            return jsonify({"ok": False, "error": "Service not found."})
        cur["redirect_to"] = target
        cur["preserve_path"] = preserve
        if not regen_config_with_rollback(subdomain, cur):
            return jsonify({"ok": False, "error": "Nginx rejected the new redirect — nothing changed."})
        save_config(cfg)

    log(subdomain, f"Redirect updated → {target}")
    return jsonify({"ok": True, "message": f"{svc_fqdn(subdomain, svc)} now redirects to {target}"})

# ── Convert a site (no re-upload: files stay put, only nginx/DNS change) ─────
@app.route("/api/convert/extension", methods=["POST"])
@login_required
def convert_to_extension():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err
    parent_name = (data.get("parent") or "").strip().lower()
    path = (data.get("path") or "").strip().strip("/").lower()

    if not valid_ext_path(path):
        return jsonify({"ok": False, "error": "Path can only contain lowercase letters, numbers, and hyphens."})
    if parent_name == subdomain:
        return jsonify({"ok": False, "error": "A site can't become an extension of itself."})
    if svc.get("extensions"):
        return jsonify({"ok": False, "error": "Remove this site's own extensions first."})
    if svc.get("redirect_to"):
        return jsonify({"ok": False, "error": "Redirects can't become extensions — remove it and add a new one instead."})
    if svc.get("status") == "paused":
        return jsonify({"ok": False, "error": "Resume this site before converting it."})

    with config_lock:
        cfg = load_config()
        cur    = cfg.get("services", {}).get(subdomain)
        parent = cfg.get("services", {}).get(parent_name)
        if not cur:
            return jsonify({"ok": False, "error": "Service not found."})
        if not parent:
            return jsonify({"ok": False, "error": "Parent site not found."})
        if parent.get("status") == "paused":
            return jsonify({"ok": False, "error": "Resume the parent site before converting."})
        if path in (parent.get("extensions") or {}):
            return jsonify({"ok": False, "error": f"/{path} already exists on {parent_name}."})

        # Reuse the existing files/port/service — nothing is moved or re-cloned
        parent.setdefault("extensions", {})[path] = {
            "path": path,
            "repo_url": cur.get("repo_url", ""),
            "port": cur.get("port"),
            "web_root": cur.get("web_root", f"{WWW_ROOT}/{subdomain}"),
            "service_name": cur.get("service_name", ""),
            "status": "online",
            "added_at": datetime.now().isoformat(),
        }
        old_fqdn    = svc_fqdn(subdomain, cur)
        parent_fqdn = svc_fqdn(parent_name, parent)
        log(parent_name, f"Converting site {old_fqdn} into extension /{path}")
        if not regen_config_with_rollback(parent_name, parent):
            return jsonify({"ok": False, "error": "Nginx rejected the parent's new config — conversion aborted, nothing changed."})

        # Retire the old standalone server block
        remove_nginx_config(subdomain)
        reload_nginx(subdomain)

        record_id  = cur.get("cf_record_id")
        old_domain = svc_domain(cur)
        del cfg["services"][subdomain]
        save_config(cfg)

    if record_id:
        if cf_delete_dns(record_id, old_domain):
            log(parent_name, f"Old DNS record for {old_fqdn} removed.")
        else:
            log(parent_name, f"Could not remove old DNS record for {old_fqdn} — delete it manually.", "WARN")

    log(parent_name, f"Conversion complete → https://{parent_fqdn}/{path}/")
    return jsonify({"ok": True, "message": f"{old_fqdn} is now {parent_fqdn}/{path}/"})

@app.route("/api/convert/detach", methods=["POST"])
@login_required
def detach_extension():
    """Revert: turn a path extension back into its own standalone site."""
    data = request.json
    subdomain, svc, err = get_service_or_error(data)   # subdomain = the parent
    if err:
        return err
    path = (data.get("path") or "").strip().strip("/").lower()
    new  = (data.get("new_subdomain") or "").strip().strip(".").lower()

    if not valid_subdomain(new):
        return jsonify({"ok": False, "error": "Invalid new subdomain name."})
    if svc.get("status") == "paused":
        return jsonify({"ok": False, "error": "Resume the site before detaching an extension."})

    with config_lock:
        cfg = load_config()
        parent = cfg.get("services", {}).get(subdomain)
        ext = (parent or {}).get("extensions", {}).get(path)
        if not ext:
            return jsonify({"ok": False, "error": "Extension not found."})
        # A detached extension stays on whichever domain its parent is on
        new_domain = svc_domain(parent)
        new_key    = service_key(new, new_domain)
        new_fqdn   = make_fqdn(new, new_domain)
        if new_key in cfg["services"]:
            return jsonify({"ok": False, "error": f"'{new_fqdn}' already exists."})

        log(subdomain, f"Detaching /{path} → standalone site {new_fqdn} (files stay in place)")
        new_svc = {
            "repo_url": ext.get("repo_url", ""),
            "subdomain": new,
            "domain": new_domain,
            "fqdn": new_fqdn,
            "web_root": ext.get("web_root", ext_web_root(subdomain, path)),
            "port": ext.get("port"),
            "project": parent.get("project", ""),
            "service_name": ext.get("service_name", ""),
            "extensions": {},
            "status": "online",
            "cf_record_id": None,
            "deployed_at": ext.get("added_at") or datetime.now().isoformat(),
        }

        # Bring the standalone server block up first
        write_site_config(new_key, new_svc)
        ok, _ = reload_nginx(subdomain)
        if not ok:
            remove_nginx_config(new_key)
            reload_nginx(subdomain)
            return jsonify({"ok": False, "error": "Nginx rejected the new site config — detach aborted, nothing changed."})

        # Then drop the extension from the parent
        parent["extensions"].pop(path, None)
        if not regen_config_with_rollback(subdomain, parent):
            remove_nginx_config(new_key)
            reload_nginx(subdomain)
            return jsonify({"ok": False, "error": "Nginx rejected the parent's config — detach aborted, nothing changed."})

        cfg["services"][new_key] = new_svc
        save_config(cfg)

    ok, result = cf_add_dns(new, new_domain)
    if ok:
        update_service(new_key, cf_record_id=result)
        log(new_key, f"DNS record for {new_fqdn} created.")
    else:
        log(new_key, f"DNS for {new_fqdn} failed: {result} — add manually if needed.", "WARN")

    log(new_key, f"Detach complete → https://{new_fqdn}")
    return jsonify({"ok": True, "message": f"/{path} is now its own site: {new_fqdn}"})

@app.route("/api/convert/subdomain", methods=["POST"])
@login_required
def convert_to_subdomain():
    data = request.json
    subdomain, svc, err = get_service_or_error(data)
    if err:
        return err
    new = (data.get("new_subdomain") or "").strip().strip(".").lower()
    # Omitting "domain" keeps the site where it is; passing another configured
    # domain moves it across (files stay put — only nginx + DNS change).
    new_domain = (data.get("domain") or svc_domain(svc)).strip().lower()

    if not valid_domain(new_domain):
        return jsonify({"ok": False, "error": f"Unknown domain '{new_domain}'."})
    if not valid_site_name(new):
        return jsonify({"ok": False, "error": "Invalid new subdomain name."})
    if svc.get("status") == "paused":
        return jsonify({"ok": False, "error": "Resume this site before converting it."})

    old_domain = svc_domain(svc)
    old_fqdn   = svc_fqdn(subdomain, svc)
    new_key    = service_key(new, new_domain)
    new_fqdn   = make_fqdn(new, new_domain)

    if new_key == subdomain:
        return jsonify({"ok": False, "error": "That's already this site's name."})

    with config_lock:
        cfg = load_config()
        cur = cfg.get("services", {}).get(subdomain)
        if not cur:
            return jsonify({"ok": False, "error": "Service not found."})
        if new_key in cfg["services"]:
            return jsonify({"ok": False, "error": f"'{new_fqdn}' already exists."})

        log(subdomain, f"Renaming {old_fqdn} → {new_fqdn} (files stay in place)")
        cur["subdomain"] = new
        cur["domain"]    = new_domain
        cur["fqdn"]      = new_fqdn

        # Bring the new server block up first; only then retire the old one
        write_site_config(new_key, cur)
        ok, _ = reload_nginx(subdomain)
        if not ok:
            remove_nginx_config(new_key)
            reload_nginx(subdomain)
            return jsonify({"ok": False, "error": "Nginx rejected the new config — conversion aborted, nothing changed."})

        remove_nginx_config(subdomain)
        reload_nginx(subdomain)

        old_record = cur.get("cf_record_id")
        cfg["services"][new_key] = cur
        del cfg["services"][subdomain]
        save_config(cfg)

    # Carry the log history over to the new name
    try:
        if os.path.exists(f"{LOG_DIR}/{subdomain}.log") and not os.path.exists(f"{LOG_DIR}/{new_key}.log"):
            os.rename(f"{LOG_DIR}/{subdomain}.log", f"{LOG_DIR}/{new_key}.log")
    except OSError:
        pass

    # DNS: add the new record, then drop the old one
    ok, result = cf_add_dns(new, new_domain)
    if ok:
        update_service(new_key, cf_record_id=result)
        log(new_key, f"DNS record for {new_fqdn} created.")
    else:
        update_service(new_key, cf_record_id=None)
        log(new_key, f"DNS for {new_fqdn} failed: {result} — add manually if needed.", "WARN")
    if old_record:
        if cf_delete_dns(old_record, old_domain):
            log(new_key, f"Old DNS record for {old_fqdn} removed.")
        else:
            log(new_key, f"Could not remove old DNS record for {old_fqdn} — delete it manually.", "WARN")

    log(new_key, f"Conversion complete → https://{new_fqdn}")
    return jsonify({"ok": True, "message": f"{old_fqdn} is now {new_fqdn}"})

# ── Logs ──────────────────────────────────────────────────────────────────────
@app.route("/api/logs/<subdomain>")
@login_required
def logs(subdomain):
    if not valid_subdomain(subdomain):
        return jsonify({"all": [], "errors": []})
    lines = read_log(subdomain)
    errors = [l for l in lines if "[ERROR]" in l or "[WARN]" in l]
    return jsonify({"all": lines, "errors": errors})

@app.route("/api/status")
@login_required
def status():
    cfg = load_config()
    services = cfg.get("services", {})
    # Surface the resolved hostname on every service so API clients (the CLI,
    # the dashboard) never have to reimplement the legacy-record fallback.
    for key, svc in services.items():
        svc.setdefault("domain", svc_domain(svc))
        svc["fqdn"] = svc_fqdn(key, svc)
    return jsonify(services)

@app.route("/api/public/status")
def public_status():
    """Unauthenticated status feed for a public status page.

    Deliberately narrow: only allowlisted sites, and only name/url/status —
    never repo URLs, ports, web roots, systemd unit names or record IDs.
    Returns 404 when the allowlist is empty so it can't be probed for the
    full service list."""
    if not PUBLIC_STATUS:
        return jsonify({"error": "Not found"}), 404

    cfg = load_config()
    sites = []
    for key, svc in sorted(cfg.get("services", {}).items()):
        if key.lower() not in PUBLIC_STATUS:
            continue
        status = svc.get("status", "unknown")
        sites.append({
            "name":   key,
            "url":    f"https://{svc_fqdn(key, svc)}",
            # Collapse internal states to something meaningful to a visitor
            "status": status if status in ("online", "paused") else "offline",
        })

    resp = jsonify({
        "checked_at": datetime.now().isoformat(timespec="seconds"),
        "online":     sum(1 for s in sites if s["status"] == "online"),
        "total":      len(sites),
        "sites":      sites,
    })
    # Read-only public data — allow the static site on another origin to read it
    resp.headers["Access-Control-Allow-Origin"] = "*"
    resp.headers["Cache-Control"] = "public, max-age=30"
    return resp

@app.route("/api/domains")
@login_required
def domains():
    """Which domains this ProxDeploy can deploy to, and whether each is usable."""
    return jsonify({
        "default": DOMAIN,
        "domains": [
            {"name": name,
             "zone_id": bool(zone_for(name)),
             "apex_ready": bool(CF_TUNNEL_ID)}
            for name in sorted(DOMAINS)
        ],
    })

# ── Per-site resources ────────────────────────────────────────────────────────
_disk_cache = {}  # web_root -> (timestamp, mb)

def disk_usage_mb(web_root):
    if not web_root or not os.path.isdir(web_root):
        return None
    now = time.time()
    cached = _disk_cache.get(web_root)
    if cached and now - cached[0] < 120:
        return cached[1]
    try:
        out = subprocess.run(["du", "-sm", web_root], capture_output=True,
                             text=True, timeout=20)
        mb = int(out.stdout.split()[0]) if out.returncode == 0 else None
    except Exception:
        mb = None
    _disk_cache[web_root] = (now, mb)
    return mb

def unit_stats(unit):
    """CPU %, RSS MB and uptime for a site's systemd service (no sudo needed)."""
    if not valid_unit(unit):
        return None
    if not unit.endswith(".service"):
        unit += ".service"
    try:
        out = subprocess.run(
            ["systemctl", "show", unit, "-p", "MainPID,ActiveState,ActiveEnterTimestampMonotonic"],
            capture_output=True, text=True, timeout=10)
        props = dict(l.split("=", 1) for l in out.stdout.splitlines() if "=" in l)
        active = props.get("ActiveState") == "active"
        pid = int(props.get("MainPID", "0") or 0)
        stats = {"active": active, "cpu": None, "ram_mb": None, "uptime_s": None}
        if active:
            mono = int(props.get("ActiveEnterTimestampMonotonic", "0") or 0)
            if mono:
                with open("/proc/uptime") as f:
                    up_now = float(f.read().split()[0])
                stats["uptime_s"] = max(0, int(up_now - mono / 1_000_000))
        if active and pid > 0:
            ps = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)],
                                capture_output=True, text=True, timeout=10)
            if ps.returncode == 0 and ps.stdout.strip():
                cpu, rss = ps.stdout.split()
                stats["cpu"] = float(cpu)
                stats["ram_mb"] = round(int(rss) / 1024, 1)
        return stats
    except Exception:
        return None

@app.route("/api/resources")
@login_required
def resources():
    cfg = load_config()
    out = {}
    for name, svc in cfg.get("services", {}).items():
        info = {
            "disk_mb": disk_usage_mb(svc.get("web_root")),
            "cpu": None, "ram_mb": None, "uptime_s": None, "unit_active": None,
        }
        unit = svc.get("service_name") or ""
        if unit:
            st = unit_stats(unit)
            if st:
                info.update({
                    "cpu": st["cpu"], "ram_mb": st["ram_mb"],
                    "uptime_s": st["uptime_s"], "unit_active": st["active"],
                })
        out[name] = info
    return jsonify(out)

# ── System info ───────────────────────────────────────────────────────────────
@app.route("/api/sysinfo")
@login_required
def sysinfo():
    def read_stat():
        with open("/proc/stat") as f:
            fields = f.readline().split()
        idle  = int(fields[4]) + int(fields[5])
        total = sum(int(x) for x in fields[1:])
        return idle, total

    idle1, total1 = read_stat()
    time.sleep(0.25)
    idle2, total2 = read_stat()
    delta_total = total2 - total1
    cpu_pct = round(100 * (1 - (idle2 - idle1) / delta_total), 1) if delta_total else 0.0

    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":", 1)
            mem[k.strip()] = int(v.split()[0])
    ram_total = mem["MemTotal"] // 1024
    ram_avail = mem["MemAvailable"] // 1024
    ram_used  = ram_total - ram_avail
    ram_pct   = round(100 * ram_used / ram_total, 1) if ram_total else 0.0

    return jsonify({
        "cpu_percent":  cpu_pct,
        "ram_used_mb":  ram_used,
        "ram_total_mb": ram_total,
        "ram_percent":  ram_pct,
    })

# ── Restart ───────────────────────────────────────────────────────────────────
@app.route("/api/restart", methods=["POST"])
@login_required
def restart_service():
    subdomain, svc, err = get_service_or_error(request.json)
    if err:
        return err

    log(subdomain, "Manual restart requested.")

    # If a systemd service name is registered, restart it first
    svc_name = svc.get("service_name", "")
    if svc_name:
        if not systemctl_unit("restart", svc_name, subdomain):
            return jsonify({"ok": False, "error": f"Failed to restart '{svc_name}' — check logs."})

    ok, _ = reload_nginx(subdomain)
    if not ok:
        log(subdomain, "Nginx reload failed.", "ERROR")
        return jsonify({"ok": False, "error": "Nginx reload failed — check logs."})

    log(subdomain, "Restart complete.")
    return jsonify({"ok": True, "message": f"{subdomain} restarted."})

if __name__ == "__main__":
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(SERVICES_DIR, exist_ok=True)
    cleanup_stale_statuses()
    app.run(host="0.0.0.0", port=2096, debug=False)
