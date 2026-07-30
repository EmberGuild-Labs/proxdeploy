# ProxDeploy — Setup Guide

Step by step, start to finish. Do these in order and check each one worked
before moving on — a mistake in step 4 is much easier to find if steps 1–3 are
known good.

Throughout, replace `example.com` with your own domain and `pi` with your own
username if it differs.

---

## Step 0 — Check prerequisites

```bash
python3 --version && which git nginx cloudflared pip3
```

You want Python 3.9 or newer and a path printed for each tool. If `pip3` or the
venv module is missing:

```bash
sudo apt update && sudo apt install -y python3-pip python3-venv git
```

If **nginx** or **cloudflared** are missing, install and configure those first —
ProxDeploy manages them, it doesn't install them. You need a working Cloudflare
Tunnel before ProxDeploy is useful.

---

## Step 1 — Get the files

```bash
cd ~
git clone https://github.com/<you>/proxdeploy.git
cd proxdeploy
```

The service unit shipped here expects `/home/pi/proxdeploy`. If you put it
somewhere else, edit `WorkingDirectory`, `EnvironmentFile`, and `ExecStart` in
`proxdeploy.service` to match.

---

## Step 2 — Virtual environment

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Check: `ls venv/bin/` should show `python`, `pip`, and `activate`.

> If pip complains about an "externally-managed-environment", you skipped
> `source venv/bin/activate`. Your prompt should read `(venv)`.

---

## Step 3 — Configuration

```bash
cp .env.example .env
nano .env
```

Fill in, at minimum:

| Variable | Where to get it |
|---|---|
| `SECRET_KEY` | `python3 -c "import secrets; print(secrets.token_hex(32))"` |
| `DOMAIN` | Your main domain, e.g. `example.com` |
| `DOMAINS` | `example.com:<zone id>` — Cloudflare dashboard → your domain → **Overview** → right sidebar → **Zone ID** |
| `CF_API_TOKEN` | Cloudflare → My Profile → API Tokens → **Create Token** → **Edit zone DNS** template → Zone Resources: include your domain(s) |

Optional but recommended:

| Variable | Why |
|---|---|
| `API_KEY` | `python3 -c "import secrets; print(secrets.token_hex(32))"` — enables the CLI |
| `CF_TUNNEL_ID` | `cloudflared tunnel list` — needed only to deploy a domain root |
| `GITHUB_TOKEN` | Only if you'll deploy private repos |

Save in nano with `Ctrl+O`, `Enter`, then `Ctrl+X`.

Two rules that catch people out:

1. **This file is read by systemd, not a shell.** No quotes, no spaces around
   `=`, no trailing comments on a value line. `DOMAIN=example.com` — not
   `DOMAIN = "example.com"  # main`.
2. **`.env` is secret.** It's in `.gitignore`. Keep it that way.

Lock it down:

```bash
chmod 600 .env
```

You can leave the Cloudflare values blank for now — deploys will still work,
they just won't create DNS records until you fill them in and restart.

---

## Step 4 — Sudoers rule

ProxDeploy needs to run a few commands with `sudo` and no password prompt. It
would otherwise hang forever waiting for input it can't receive.

**Find your real binary paths first** — they differ between distributions, and
a wrong path here produces a confusing "sudo: a password is required" much
later:

```bash
which nginx systemctl git chown rm
```

Then open the file with `visudo`, which validates syntax before saving:

```bash
sudo visudo -f /etc/sudoers.d/proxdeploy
```

Add one line, built from **your** paths:

```
pi ALL=(ALL) NOPASSWD: /usr/sbin/nginx, /usr/bin/systemctl, /usr/bin/git, /usr/bin/chown, /usr/bin/rm
```

> **Always use `visudo`, never plain nano.** A syntax error in a sudoers file
> can lock you out of `sudo` entirely, and fixing that needs physical access to
> the machine.

Narrower is better if you're comfortable editing it later: restricting
`systemctl` to `reload nginx` and `restart cloudflared` works until you want
ProxDeploy to start and stop your sites' own units, at which point you'll need
the broader rule above.

Verify it took effect:

```bash
sudo -n nginx -t
```

It should print nginx's test result and **not** prompt for a password.

---

## Step 5 — Install the systemd service

```bash
sudo cp ~/proxdeploy/proxdeploy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable proxdeploy
sudo systemctl start proxdeploy
sudo systemctl status proxdeploy --no-pager
```

Look for `active (running)`. If it failed:

```bash
sudo journalctl -u proxdeploy -n 30 --no-pager
```

The usual cause is a path in `proxdeploy.service` not matching where the files
actually are.

---

## Step 6 — Expose it through the Cloudflare Tunnel

Find your tunnel config:

```bash
sudo cat /etc/cloudflared/config.yml
```

Add an ingress entry for the dashboard **above** the final `http_status:404`
line — that catch-all must always come last:

```yaml
ingress:
  - hostname: deploy.example.com
    service: http://localhost:2096

  # Strongly recommended: a wildcard so new sites never need a tunnel edit
  - hostname: "*.example.com"
    service: http://localhost:80
  - hostname: example.com
    service: http://localhost:80

  - service: http_status:404
```

The wildcard rule is what makes ProxDeploy hands-off. With it, deploying a new
subdomain only needs nginx and DNS — both of which ProxDeploy does itself.

Restart and check:

```bash
sudo systemctl restart cloudflared
sudo systemctl status cloudflared --no-pager
```

You also need a DNS record for the dashboard hostname itself. Either add a
proxied `CNAME deploy → example.com` in the Cloudflare dashboard, or run:

```bash
cloudflared tunnel route dns <tunnel-name> deploy.example.com
```

---

## Step 7 — First login

Open `https://deploy.example.com` in a browser.

On first visit you'll be asked to **set the dashboard password**. It is hashed
with bcrypt and written to `config.json` — the plaintext is never stored. Pick
something strong; anyone with this password can run code on your machine.

---

## Step 8 — Install the CLI (optional)

On your **laptop**, not the server:

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/proxdeploy \
  https://raw.githubusercontent.com/<you>/proxdeploy/main/cli/proxdeploy
chmod +x ~/.local/bin/proxdeploy
proxdeploy setup
```

Make sure `~/.local/bin` is on your `PATH`.

`setup` asks for host, SSH user, SSH password, default domain, and the `API_KEY`
from the server's `.env`, then writes `~/.proxdeploy` with mode `600`.

**Leave the SSH password blank and use key-based auth** if you can:

```bash
ssh-keygen -t ed25519            # if you don't have a key yet
ssh-copy-id <user>@<your-pi-host>
```

That's better than storing a password in a config file, and it removes the
`sshpass` dependency. Then disable password auth on the server entirely — see
[SECURITY.md](SECURITY.md).

Test it:

```bash
proxdeploy status
```

---

## Step 9 — Deploy something

From the dashboard, or:

```bash
proxdeploy deploy https://github.com/<you>/some-static-site test
proxdeploy logs test
```

Watch the log for `Deploy complete`. Then open `https://test.example.com`.

If it doesn't resolve immediately, give DNS a minute — and check the tunnel
ingress covers the hostname.

---

## Adding a second domain later

1. Add the domain to Cloudflare and note its Zone ID.
2. Edit the **existing** Cloudflare API token to include the new zone under
   Zone Resources — one token for all zones is simplest.
3. Append it to `DOMAINS` in `.env`:
   `DOMAINS=example.com:<zone1>,example.org:<zone2>`
4. Add tunnel ingress rules for `example.org` and `*.example.org`.
5. `sudo systemctl restart proxdeploy && sudo systemctl restart cloudflared`

**Do not change `DOMAIN`.** Existing sites are keyed by bare name on the default
domain; changing it would orphan every one of them. Sites on the new domain are
keyed by full hostname automatically, so nothing needs migrating.

---

## Backups

ProxDeploy's code is recoverable from GitHub. These are not:

```bash
tar czf ~/proxdeploy-backup-$(date +%F).tar.gz \
  ~/proxdeploy/config.json \
  ~/proxdeploy/.env \
  /etc/nginx/sites-available/ \
  /etc/cloudflared/
```

Copy that off the machine. An SD card that dies takes your entire service
registry with it, and rebuilding twenty sites by hand is a bad afternoon.
