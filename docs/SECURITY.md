# ProxDeploy — Security Notes

Read this before putting ProxDeploy on the internet.

---

## The threat model, stated plainly

**ProxDeploy is a remote code execution tool. That is its entire job.**

It clones arbitrary git repositories onto your machine, writes files into
`/etc/nginx/`, runs `sudo rm -rf`, and starts and stops systemd units. Anyone
who can authenticate to it can do all of that.

That means:

- The dashboard password and the `API_KEY` are **root-equivalent credentials**
  on that machine. Treat them exactly as seriously.
- ProxDeploy is designed for **one operator managing their own hardware**. It is
  not multi-tenant, has no roles or permissions, and no audit trail beyond its
  log files. Do not hand out the password.
- Deploying a repo runs that repo's code if the site is dynamic. Only deploy
  repositories you trust.

Everything below is about keeping *unauthorized* people out. None of it changes
what an authorized user can do.

---

## What the design already does for you

**Flask never faces the internet.** The app binds `localhost:2096`. All inbound
traffic arrives through the Cloudflare Tunnel and is handed to nginx. There is
no open port on your router, and your home IP address is never published in
DNS — every record is a proxied CNAME.

**Passwords are bcrypt-hashed.** Set by `setup.sh` before the dashboard is exposed (change it with `./setup.sh --password`), stored in `config.json`. The
plaintext is never written anywhere.

**API keys are compared in constant time.** `secrets.compare_digest`, not `==`,
so response timing doesn't leak the key a character at a time.

**Unauthenticated requests to `/api/*` get JSON 401s**, not an HTML redirect —
so scripts fail loudly instead of parsing a login page as data.

**The GitHub token never lands on disk.** Private-repo auth is injected per
command with `git -c url.<token>@github.com.insteadOf=…`, so it is never
persisted into any cloned repo's `.git/config`. Git errors that echo the
tokenised URL are scrubbed before they reach a log file.

**Deletion is path-constrained.** `sudo rm -rf` only ever runs against a path
matching `^/var/www/[a-z0-9.\-]+$`. Anything else is refused and logged as an
error. `config.json` is data, and data can be corrupted or wrong.

**Input is validated against allowlists, not blocklists.** Subdomains, path
extensions, and systemd unit names must each match a strict regex before being
interpolated into a shell command or an nginx config. Redirect targets are
rejected if they contain whitespace, quotes, backslashes, `$`, `;`, `{`, or `}`
— the characters that would let someone break out of the generated `return 301`
line and inject nginx directives.

**Nginx changes roll back.** Every config write is followed by
`nginx -t && systemctl reload nginx`. On failure the previous config is restored
and reloaded. This is a security property as much as a reliability one: one bad
server block makes `nginx -t` fail for *every* site on the box, so a failed
deploy could otherwise take down everything, including the dashboard.

---

## What you must do yourself

### 1. Use a strong dashboard password

There is no rate limiting on the login form. A weak password is brute-forceable.
If you want a second layer, put **Cloudflare Access** in front of the dashboard
hostname — it's free for small teams and gives you real SSO before a request
ever reaches your machine. This is the single highest-value hardening step
available and it takes about five minutes.

### 2. Scope the sudoers rule

The rule in [SETUP.md](SETUP.md) grants passwordless `sudo` for a specific list
of binaries. Do not shortcut it to `NOPASSWD: ALL`.

Be aware of what the listed commands still allow: `NOPASSWD` on `/usr/bin/rm`,
`/usr/bin/chown`, and an unrestricted `/usr/bin/systemctl` is a meaningful grant
on its own. Anyone who gets code execution as the `pi` user has an easy path to
root through it. That is an accepted trade-off for a single-operator homelab —
it is *not* appropriate on a shared machine. If several people have accounts on
this box, ProxDeploy is the wrong tool.

### 3. Prefer SSH keys over passwords

The CLI supports an SSH password stored in `~/.proxdeploy` (mode `600`) because
it's the path of least resistance. Keys are better:

```bash
ssh-keygen -t ed25519
ssh-copy-id user@host
```

Then leave the password blank during `proxdeploy setup`, and turn password auth
off on the server:

```
# /etc/ssh/sshd_config
PasswordAuthentication no
PubkeyAuthentication yes
```

```bash
sudo systemctl restart ssh
```

**Confirm your key works in a second terminal before you disconnect the first
one.** Locking yourself out of a headless machine means going to find a monitor
and a keyboard.

### 4. Keep `.env` out of git and off other machines

`.gitignore` covers `.env`, `config.json`, and `logs/`. Verify before your first
push:

```bash
git status --porcelain --ignored | grep -E '\.env|config\.json'
```

Both should be listed as ignored (`!!`), never as staged. `chmod 600 .env`.

If a token ever does get committed: **rotate it first**, then worry about
rewriting history. A token in a public repo's history is compromised the moment
it's pushed — GitHub's scanners are not the only ones watching.

### 5. Leave `PUBLIC_STATUS` empty unless you need it

`GET /api/public/status` is the only endpoint with no authentication. It is
deliberately narrow:

- **Returns 404 when `PUBLIC_STATUS` is empty** — the default. It can't be
  probed for your service list unless you opt in.
- Opt-in **per site**, not per install.
- Returns only `name`, `url`, and `status`. Never repo URLs, ports, web roots,
  systemd unit names, or Cloudflare record IDs.
- Sends `Access-Control-Allow-Origin: *` so a static status page on another
  origin can read it, and a 30-second cache header.

Internal states (`deploying`, `updating`, `error`) are collapsed to `offline`
before they're published, so the feed doesn't narrate your outages in detail.

### 6. Set a real `SECRET_KEY`

`app.py` falls back to a hardcoded default if `SECRET_KEY` is unset. That
default is in this public repository, and anyone with it can forge a session
cookie and get in without a password. Generate your own:

```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

### 7. Keep it patched

```bash
cd ~/proxdeploy
source venv/bin/activate
pip install --upgrade -r requirements.txt
sudo systemctl restart proxdeploy
```

And the OS: `sudo apt update && sudo apt upgrade`.

---

## If you build tools that fetch user-supplied URLs

This isn't about ProxDeploy itself, but it's the mistake most likely to bite
anyone hosting small web tools on a homelab, so it's worth stating.

A service that takes a URL from a stranger and fetches it **from inside your
network** is a Server-Side Request Forgery vector. Someone can point it at
`http://127.0.0.1:2096/` — your ProxDeploy login page — or at
`http://192.168.1.1/`, and use your machine as a probe to map a network they
should not be able to see. Cloud metadata endpoints like `169.254.169.254` are
the same class of target.

Three bypasses defeat the naive fix, and all three are worth knowing:

1. **Redirects.** Validating only the submitted URL is useless: a public URL that
   `302`s to `127.0.0.1` sails through. Worse, `requests` with
   `allow_redirects=True` follows hops *internally* and never consults your
   guard. Set `allow_redirects=False` and drive the loop yourself, checking
   every hop.
2. **DNS.** Matching the hostname *string* is useless when the attacker owns the
   domain. `localtest.me` is a real public domain whose A record points at
   `127.0.0.1`. You must **resolve** the name and validate the resulting IPs.
3. **Raw sockets.** A tool that dials `host:port` directly rather than fetching a
   URL needs the same check before `socket.create_connection`. Connection timing
   alone reveals which ports are open.

Validate resolved addresses with Python's `ipaddress` module and reject private,
loopback, link-local, reserved, multicast, and unspecified ranges — v4 **and**
v6 — plus non-`http(s)` schemes and `.local` / `.internal` / `.lan` hostnames.
Test with `localtest.me`, not just `127.0.0.1`: that's the case that proves
you're resolving rather than string-matching.

A resolve-then-connect check still leaves a theoretical DNS-rebinding window.
Closing it fully means pinning the socket to the vetted IP.

---

## Hardening units for sites you deploy

For any dynamic site that handles untrusted input, this is a good baseline
systemd unit:

```ini
[Service]
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
MemoryMax=180M
```

The memory cap matters more than it looks on a 1 GB machine — it stops one
runaway service from taking every other service down with it.

---

## Reporting a vulnerability

Open a GitHub issue for anything low-risk. For something genuinely sensitive,
use GitHub's private vulnerability reporting on this repository rather than a
public issue.
