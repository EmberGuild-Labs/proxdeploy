# ProxDeploy

**A self-hosted deploy dashboard for a Raspberry Pi homelab.** Paste a GitHub
repo URL, pick a subdomain, click Deploy — ProxDeploy clones the repo, writes
the nginx config, creates the Cloudflare DNS record, restarts the Cloudflare
Tunnel, and brings the site online. No ports forwarded, no public IP exposed.

It runs happily on a Raspberry Pi 4 with 1 GB of RAM, and has been used in
production to host ~25 sites across two domains.

```
Browser / CLI
   └── ProxDeploy (Flask, localhost:2096)
         ├── git clone   →  /var/www/<site>/
         ├── nginx conf  →  /etc/nginx/sites-available/<site>
         ├── Cloudflare API  →  CNAME <site>.example.com
         └── systemctl restart cloudflared
```

---

## Table of contents

- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [The CLI](#the-cli)
- [Usage](#usage)
- [Configuration reference](#configuration-reference)
- [API reference](#api-reference)
- [Project structure](#project-structure)
- [Design notes and decisions](#design-notes-and-decisions)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [License](#license)

---

## What it does

| | |
|---|---|
| **One-click deploys** | Repo URL + subdomain → live HTTPS site |
| **Static and dynamic sites** | Static files served by nginx; give it a port and it reverse-proxies instead |
| **Multi-domain** | Deploy to any number of domains from one dashboard |
| **Landing pages** | Deploy to a domain's root (apex), not just subdomains |
| **Path extensions** | Mount a second repo at `site.example.com/blog/` |
| **Redirects** | A "site" that is just a 301 to somewhere else |
| **Convert without re-uploading** | Rename a site, move it to another domain, or turn it into a path extension — files never move |
| **Pause / resume** | Swap a site for a lightweight "paused" page and stop its process to free RAM |
| **Live logs** | Per-site log panel with an errors-and-warnings-only tab |
| **Resource stats** | Per-site disk usage, CPU, RAM, and uptime; plus whole-machine CPU/RAM |
| **Private repos** | Optional GitHub token, redacted from logs |
| **Public status feed** | Opt-in, unauthenticated JSON endpoint for a status page |
| **Survives reboots** | Runs as a systemd service |

## How it works

When you deploy a site, ProxDeploy:

1. Runs `git clone <repo>` into `/var/www/<key>/`
2. Sets ownership to `www-data`
3. Writes an nginx server block to `/etc/nginx/sites-available/<key>` and symlinks it into `sites-enabled/`
4. Runs `nginx -t && systemctl reload nginx` — and if nginx rejects the config, rolls back
5. Calls the Cloudflare API to create a proxied `CNAME`
6. Runs `systemctl restart cloudflared`
7. Records the site in `config.json`

All of that happens on a background thread, so the UI stays responsive. Watch
the Logs panel for progress.

**Nothing is ever exposed directly to the internet.** Flask binds to
`localhost:2096`. All inbound traffic arrives through a Cloudflare Tunnel,
which hands it to nginx. Your home IP address is never published.

---

## Requirements

- A Linux box — designed for and tested on **Raspberry Pi OS (Bookworm / Trixie)** on a Pi 4, but any Debian-family machine works
- **Python 3.9+**
- **nginx**, already installed and serving
- **cloudflared** with a configured tunnel
- A domain on **Cloudflare** (free plan is fine)
- A Cloudflare API token with **Edit zone DNS** on that domain
- `git`

---

## Installation

### Automatic (recommended)

```bash
cd ~
git clone https://github.com/<you>/proxdeploy.git
cd proxdeploy
./setup.sh
```

`setup.sh` asks a handful of questions and does the rest:

- **Checks prerequisites** — python, git, curl, nginx, cloudflared; offers to `apt install` what's missing
- **Verifies your Cloudflare token** against the API before going any further
- **Looks up your zone IDs automatically** — you type domain names, not hex strings
- **Auto-detects your tunnel UUID** from `cloudflared tunnel list`
- **Generates `SECRET_KEY` and `API_KEY`** for you and writes `.env` at mode `600`
- **Builds the sudoers rule** from `which`-resolved paths, validates it with `visudo -c`, and refuses to install it if it doesn't parse
- **Installs and starts the systemd service**, generated for your actual user and directory
- **Adds tunnel ingress rules** for the dashboard and a `*.yourdomain` wildcard, keeping the `http_status:404` catch-all last
- **Creates the dashboard's DNS record** via the Cloudflare API
- **Sets up start-on-boot** (see below)

Nothing is written to your system until an explicit confirmation prompt, every
file it replaces is backed up as `*.bak-<timestamp>`, and it's safe to re-run —
it detects an existing `.env` and won't clobber it without asking.

The only thing left afterwards is opening the dashboard and setting your
password.

### Manual

If you'd rather do it by hand, or the script hits something unusual on your
setup, **[docs/SETUP.md](docs/SETUP.md)** walks through every step individually.

> A wildcard ingress rule (`*.example.com`) means new subdomains never need a
> tunnel change again — only nginx and DNS, both of which ProxDeploy handles.

### Surviving reboots and power cuts

The installer offers to enable start-on-boot, which covers all three pieces —
losing any one of them leaves your sites dark:

| Unit | Why it matters |
|---|---|
| `proxdeploy` | The dashboard and API |
| `nginx` | Actually serves every site |
| `cloudflared` | The only route in from the internet |

On a re-run it also reads `config.json` and offers to enable the systemd units
belonging to your **deployed sites** — otherwise the dashboard returns after a
reboot but the apps behind it don't, and every dynamic site 502s. It warns about
any unit sitting in a `failed` state, since an enabled-but-failing unit is one
reboot away from silent breakage.

The service unit itself is written for unattended recovery:

- `Restart=always` with `RestartSec=5` — crashes come back on their own
- `StartLimitIntervalSec=0` — systemd's default gives up after 5 restarts in 10
  seconds and leaves the unit dead. After a power cut, when the app may lose
  several races against a not-yet-ready network, that default is exactly wrong.
- `After=network-online.target` — so the first deploy after boot has working DNS

Worth testing once, deliberately:

```bash
sudo reboot
# then, once it's back:
systemctl is-enabled proxdeploy nginx cloudflared   # 3x "enabled"
systemctl is-active  proxdeploy nginx cloudflared   # 3x "active"
```

---

## The CLI

`cli/proxdeploy` is an optional command-line client. It exists because
Cloudflare's bot protection blocks non-browser HTTP clients hitting the
dashboard's public hostname — so instead of going through Cloudflare, the CLI
SSHes into the box and curls `http://localhost:2096` from the inside.

Install it on your laptop (not the server):

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/proxdeploy \
  https://raw.githubusercontent.com/<you>/proxdeploy/main/cli/proxdeploy
chmod +x ~/.local/bin/proxdeploy
proxdeploy setup
```

`proxdeploy setup` asks for the host, SSH user, SSH password (leave blank to
use key-based auth — **recommended**), your default domain, and the `API_KEY`
you put in the server's `.env`. It writes them to `~/.proxdeploy` with mode
`600`.

```
proxdeploy status                              list all deployed sites
proxdeploy domains                             list domains available to deploy to
proxdeploy sysinfo                             CPU and RAM usage
proxdeploy deploy <repo_url> <site>            deploy a static site
proxdeploy deploy <repo_url> <site> <port>     deploy a dynamic (reverse-proxy) site
proxdeploy update  <site>                      git pull + nginx reload
proxdeploy restart <site>                      reload nginx (+ restart its systemd unit)
proxdeploy delete  <site>                      remove site, nginx config, DNS record
proxdeploy logs    <site> [--errors]           last 200 log lines
```

Deploying to a second domain — add `--domain`, and use `@` for the domain root:

```bash
proxdeploy deploy <repo> blog --domain example.org   # -> blog.example.org
proxdeploy deploy <repo> @    --domain example.org   # -> example.org itself
```

Password auth needs [`sshpass`](https://linux.die.net/man/1/sshpass) installed.
Key-based auth needs nothing extra and is the better choice.

---

## Usage

### Static vs dynamic sites

- **Static** (no port): nginx serves files straight from `/var/www/<key>/`.
  Downloadable file types (`.zip`, `.dmg`, `.AppImage`, `.pdf`, …) are served
  with `Content-Disposition: attachment` automatically. A `404.html` in the repo
  root is picked up as the custom error page if present.
- **Dynamic** (port given): nginx reverse-proxies to `127.0.0.1:<port>`. **Your
  app must manage its own process** — write a systemd unit for it, then set that
  unit name on the site card so ProxDeploy can start/stop/restart it alongside
  the site.

### Site names and keys

A site's **key** is its `config.json` entry, its nginx filename, and its log
filename, all at once:

| Domain | Key | Example |
|---|---|---|
| the default `DOMAIN` | bare name | `blog` |
| any other domain | full hostname | `blog.example.org` |
| root of a non-default domain | the domain itself | `example.org` |

Because default-domain sites keep bare names, adding a second domain to an
existing install requires no migration at all. As a bonus, a name can never
collide across two domains. `proxdeploy status` always prints the exact key to
use.

### Path extensions

Mount another repo (or another running app) under a path on an existing site:
`example.com/blog/`. Static extensions get an `alias` block; dynamic ones get
a `proxy_pass` with `X-Forwarded-Prefix` set, so a prefix-aware app (Flask with
`ProxyFix(app.wsgi_app, x_prefix=1)`) generates correct URLs for its own assets
and redirects.

### Pause / resume

Pausing stops the site's systemd unit and swaps its nginx config for a small
inline "Site paused" page. On a 1 GB Pi this is the difference between running
twenty services and running twenty-five. Resume restores the real config and
starts the process again. If nginx rejects either config, the change is rolled
back automatically.

### Converting sites

None of these re-clone or move a single file — they only rewrite nginx configs
and DNS records:

- **Rename / move domain** — `POST /api/convert/subdomain`. Brings the new
  server block up *before* retiring the old one, so there is no window where the
  site is down. Log history follows the rename.
- **Site → path extension** — `POST /api/convert/extension`. `blog.example.com`
  becomes `example.com/blog/`.
- **Path extension → site** — `POST /api/convert/detach`. The reverse.

---

## Configuration reference

Every setting lives in `.env`. See [`.env.example`](.env.example) for the fully
commented version.

| Variable | Required | Purpose |
|---|---|---|
| `SECRET_KEY` | **yes** | Signs Flask session cookies. Generate with `secrets.token_hex(32)` |
| `DOMAIN` | **yes** | The default domain. Sites here keep bare names — don't change it after sites exist |
| `DOMAINS` | **yes** | `domain:zone_id` pairs, comma-separated. One domain is fine |
| `CF_API_TOKEN` | **yes** | One Cloudflare token scoped to every zone in `DOMAINS` |
| `CF_ZONE_ID` | no | Legacy single-domain fallback; `DOMAINS` wins |
| `CF_TUNNEL_ID` | only for apex | Tunnel UUID. Needed only to deploy a domain root |
| `API_KEY` | no | Enables the CLI. Blank disables API-key auth entirely |
| `GITHUB_TOKEN` | no | Deploy/update private repos. Redacted from logs |
| `PUBLIC_STATUS` | no | Site keys allowed on the public status feed. Blank → endpoint 404s |

> `.env` is read by **systemd**, not a shell. No quotes, no spaces around `=`,
> no inline comments on a value line. This trips everyone up once.

---

## API reference

All endpoints accept either an `X-API-Key` header or a logged-in browser
session.

| Method | Path | Body / notes |
|---|---|---|
| `GET` | `/api/status` | All services and their metadata |
| `GET` | `/api/domains` | Configured domains and whether each is usable |
| `GET` | `/api/sysinfo` | Machine CPU % and RAM usage |
| `GET` | `/api/resources` | Per-site disk MB, CPU, RAM, uptime |
| `GET` | `/api/logs/<site>` | `{"all": [...], "errors": [...]}` |
| `POST` | `/api/deploy` | `{repo_url, subdomain, domain?, port?, project?}` |
| `POST` | `/api/update` | `{subdomain}` — git pull + reload |
| `POST` | `/api/restart` | `{subdomain}` — nginx reload + optional systemd restart |
| `POST` | `/api/delete` | `{subdomain}` |
| `POST` | `/api/pause` · `/api/resume` | `{subdomain}` |
| `POST` | `/api/edit` | `{subdomain, project?, service_name?}` |
| `POST` | `/api/ext/add` · `/ext/update` · `/ext/remove` | `{subdomain, path, repo_url?, port?}` |
| `POST` | `/api/redirect/add` · `/redirect/edit` | `{subdomain, target, preserve_path?, domain?}` |
| `POST` | `/api/convert/subdomain` · `/convert/extension` · `/convert/detach` | see [Converting sites](#converting-sites) |

**One endpoint needs no auth:**

| Method | Path | |
|---|---|---|
| `GET` | `/api/public/status` | Opt-in feed. Returns **404** unless `PUBLIC_STATUS` lists sites, and exposes only `name`, `url`, `status` — never repo URLs, ports, web roots, unit names, or record IDs |

---

## Project structure

```
proxdeploy/
├── app.py                  Flask backend — all deploy/update/delete/log logic
├── requirements.txt        Python dependencies (flask, bcrypt, requests)
├── proxdeploy.service      systemd unit
├── .env.example            Environment variable template — copy to .env
├── templates/
│   ├── index.html          Dashboard UI
│   └── login.html          Login / first-run password setup
├── cli/
│   └── proxdeploy          Optional command-line client (runs on your laptop)
├── docs/
│   ├── SETUP.md            Full step-by-step installation guide
│   └── SECURITY.md         Threat model and hardening notes
├── logs/                   Per-site log files      (created at runtime)
├── services/               Reserved                (created at runtime)
└── config.json             Service registry + password hash (created at runtime)
```

`config.json` and `logs/` are **runtime state**, not source. Both are
gitignored. Neither is recoverable from GitHub, so back them up — see
[Design notes](#design-notes-and-decisions).

---

## Design notes and decisions

Things that are the way they are for a reason, mostly learned the hard way.

**A single lock guards `config.json`.** Deploys and updates run on background
threads. An earlier version had each thread hold its own full copy of the config
and save it wholesale — services could vanish or get stuck in `deploying`
forever when two threads overlapped. Every read and write now goes through one
`RLock`, and `update_service()` reloads-modifies-saves as one unit. Saves are
atomic (`write to .tmp` → `os.replace`), so a crash mid-write can't leave a
truncated config.

**Stale statuses are resolved at startup.** If the process dies mid-deploy, a
site is left marked `deploying` with nothing to finish it. On boot,
`cleanup_stale_statuses()` re-derives the truth from what's actually in
`sites-enabled/`.

**Nginx changes roll back.** One bad server block makes `nginx -t` fail for
*every* site on the box — a single broken deploy would take everything down.
So every config write is followed by `nginx -t && systemctl reload nginx`, and
on failure the previous config is restored and reloaded. Conversions bring the
new server block up *before* retiring the old one.

**`os.path.lexists`, not `os.path.exists`.** A dangling symlink in
`sites-enabled/` fails `exists()` but still breaks `nginx -t`. Cleanup uses
`lexists` so broken links actually get removed.

**Deletion is path-constrained.** `rm -rf` only ever runs against a path
matching `^/var/www/[a-z0-9.\-]+$`. Anything else is refused and logged as an
error, because a `web_root` field is ultimately data and data can be wrong.

**The GitHub token never touches disk.** Private-repo auth is injected per
command via `git -c url.<token>@github.com.insteadOf=...`, so it is never
written into any repo's `.git/config`. Git errors that echo the tokenised URL
are scrubbed before they reach a log file.

**`absolute_redirect off`.** nginx listens on plain `:80` behind the tunnel, so
it builds directory redirects (`/foo` → `/foo/`) as `http://` and downgrades the
visitor's scheme. Relative redirects keep whatever scheme the browser used.

**Apex records point at the tunnel directly.** Subdomains CNAME to their apex,
but an apex can't CNAME to itself — so it points at
`<tunnel-id>.cfargotunnel.com`, which is legal because Cloudflare flattens apex
CNAMEs. That is the only thing `CF_TUNNEL_ID` is for. If a parked placeholder
record already occupies the hostname (very common on a freshly registered
domain), ProxDeploy takes it over with a `PUT` rather than failing the deploy.

**`DOMAINS` is not JSON.** It's parsed from `domain:zone,domain:zone` because
systemd's `EnvironmentFile=` does not handle quoting reliably.

### Known limitations

- **`config.json` is the single source of truth and lives on one SD card.**
  Code is recoverable from GitHub; `config.json`, `/etc/nginx/sites-available/`,
  `/etc/cloudflared/` and `.env` are not. Back them up.
- **Cloudflare caches static assets at the edge.** Shipping a changed
  `style.css` at the same URL can leave visitors with new HTML and an old
  stylesheet. Use a content hash in the filename. Diagnose with
  `curl -sI https://example.com/style.css | grep -iE 'cf-cache-status|age'`.
- **Dynamic sites manage their own processes.** ProxDeploy writes the proxy
  config and can start/stop a unit you name, but it does not create systemd
  units for you.
- **nginx configs are only rewritten on deploy, pause, resume, and convert** —
  not on update. `update` is `git pull` + reload. To force a regeneration after
  changing the config template, pause and resume the site.

---

## Troubleshooting

**`pip install` fails with "externally-managed-environment"**
You're not in the venv. `source venv/bin/activate` first — your prompt should
show `(venv)`.

**Service won't start**
`sudo journalctl -u proxdeploy -n 30 --no-pager`. Most common cause: the
`WorkingDirectory` or `ExecStart` path in `proxdeploy.service` doesn't match
where you actually put the files.

**"Permission denied" / "sudo: a password is required" in the logs**
The sudoers rule paths don't match your real binaries. Re-run
`which nginx systemctl git chown rm` and fix the file with
`sudo visudo -f /etc/sudoers.d/proxdeploy`.

**Deploy stuck on "Deploying…"**
Check the Logs panel. Usually: the repo is private and `GITHUB_TOKEN` isn't set,
an nginx syntax error, or `git` isn't installed.

**Nginx reload failed**
Open the logs and read the `nginx -t` output. Usually a leftover broken config
in `sites-enabled/`.

**Cloudflare DNS not created**
Check that `CF_API_TOKEN` has **Edit zone DNS** for that specific zone, and that
the zone ID in `DOMAINS` is right. The deploy still completes — add the record
by hand if needed.

**Site not reachable after a successful deploy**
The tunnel config doesn't cover the new hostname. Use a wildcard ingress rule
(`*.example.com`) so this stops happening.

**Deploying a domain root fails**
`CF_TUNNEL_ID` isn't set. An apex record needs it — see
[Design notes](#design-notes-and-decisions).

**CLI says "empty response from Pi" or "SSH error"**
SSH itself is failing. Test with `ssh <user>@<host>` directly. If you configured
a password, make sure `sshpass` is installed.

---

## Security

Read **[docs/SECURITY.md](docs/SECURITY.md)** before exposing this to the
internet. The headlines:

- Flask binds to `localhost` only — never directly reachable
- The dashboard sits behind the Cloudflare proxy; your IP is never exposed
- Password is bcrypt-hashed on first run and stored in `config.json`
- API keys are compared with `secrets.compare_digest` (constant-time)
- The sudoers rule is scoped to the specific commands ProxDeploy needs
- The public status endpoint is opt-in per site and 404s when unconfigured

**ProxDeploy runs `git clone` and `sudo rm -rf` on your behalf.** It is a tool
for an account you control, not a multi-tenant platform. Anyone with the
dashboard password or the API key can run code on your machine. Treat both like
root credentials.

## License

MIT — see [LICENSE](LICENSE).
