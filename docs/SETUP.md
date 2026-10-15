# ProxDeploy — Setup Guide

> **Most people should just run `./setup.sh`.** It does everything in this
> document interactively. It installs nginx and cloudflared, creates the
> Cloudflare Tunnel, verifies your Cloudflare token, looks up zone IDs from
> domain names, generates your keys, sets the dashboard password, validates
> the sudoers rule before installing it, routes your domains through the
> tunnel, creates the DNS records, and sets up start-on-boot. It backs
> up every file it replaces and is safe to re-run.
>
> This guide is for doing it by hand, or for understanding what the script did.

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

Install nginx, and cloudflared from Cloudflare's apt repository
(<https://pkg.cloudflare.com/>):

```bash
sudo apt install -y nginx
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared
```

Then create a **locally-managed** tunnel. ProxDeploy edits its config file,
so a tunnel created in the Cloudflare dashboard won't work:

```bash
cloudflared tunnel login                  # open the link it prints, pick any domain
cloudflared tunnel create proxdeploy      # note the UUID it prints
sudo mkdir -p /etc/cloudflared
sudo install -m 600 ~/.cloudflared/<UUID>.json /etc/cloudflared/
sudo tee /etc/cloudflared/config.yml >/dev/null <<EOF
tunnel: <UUID>
credentials-file: /etc/cloudflared/<UUID>.json

ingress:
  - service: http_status:404
EOF
sudo cloudflared --config /etc/cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
```

Step 6 fills in the ingress rules.

---

## Step 1 — Get the files

```bash
cd ~
git clone https://github.com/EmberGuild-Labs/proxdeploy.git
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

Install the tunnel helper the **+ Domain** button uses. It is the only thing
that edits `/etc/cloudflared/config.yml`, it accepts nothing but a domain name,
and it refuses to save a config `cloudflared` can't parse:

```bash
sudo install -m 0755 -o root -g root ~/proxdeploy/proxdeploy-ingress /usr/local/bin/proxdeploy-ingress
```

Add one line, built from **your** paths:

```
pi ALL=(ALL) NOPASSWD: /usr/sbin/nginx, /usr/bin/systemctl, /usr/bin/git, /usr/bin/chown, /usr/bin/rm, /usr/local/bin/proxdeploy-ingress
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

### Making sure it comes back after a power cut

`systemctl enable` above handles ProxDeploy itself, but your sites need all
three of these enabled — miss one and everything stays dark after a reboot:

```bash
sudo systemctl enable proxdeploy nginx cloudflared
systemctl is-enabled proxdeploy nginx cloudflared    # want 3x "enabled"
```

Every **dynamic site** you later deploy runs its own systemd unit, and those
need enabling too. Otherwise the dashboard returns after a reboot but the apps
behind it don't, and each one 502s:

```bash
sudo systemctl enable yoursite.service
```

Two things in the shipped unit file exist specifically for unattended recovery:

- **`StartLimitIntervalSec=0`** — systemd's default rate limiter gives up after
  5 restarts in 10 seconds and leaves the unit `failed`. After a power cut, when
  the app may lose several races against a network that isn't ready yet, that
  default is precisely the wrong behaviour. This disables it, so `Restart=always`
  really does mean always.
- **`After=network-online.target`** — the dashboard only binds localhost, so it
  doesn't strictly need the network to start; this is so the first *deploy*
  after a reboot has working DNS for the Cloudflare API.

Also check nothing is sitting broken:

```bash
systemctl list-units --state=failed
```

An enabled-but-failing unit is one reboot away from a problem you won't notice
until you go looking. A classic on a Pi that once had Apache installed:
`apache2.service` enabled at boot, silently losing the fight for port 80 against
nginx. If you see it, `sudo systemctl disable --now apache2`.

**Test it once, deliberately**, while you still remember how it was set up:

```bash
sudo reboot
# once it's back:
systemctl is-active proxdeploy nginx cloudflared
```

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

You also need DNS records for the dashboard hostname **and for the domain's
apex**. New sites CNAME to the apex (`blog.example.com → example.com`), so the
apex has to point at the tunnel or no site will resolve:

```bash
cloudflared tunnel route dns <tunnel-name> deploy.example.com
cloudflared tunnel route dns <tunnel-name> example.com
```

If the apex already serves a website somewhere else, leave it alone and accept
that subdomain sites follow it. Alternatively, deploy a landing page to the
apex through ProxDeploy, which repoints it.

---

## Step 7 — Set the dashboard password

Set it **before** the dashboard is reachable from the internet. Otherwise the
first person to open the login page gets to choose it:

```bash
cd ~/proxdeploy && ./setup.sh --password
```

It is hashed with bcrypt and written to `config.json`; the plaintext is never
stored. Use at least 12 characters, since anyone with this password can run
code on your machine. Run the same command any time to change it.

Then open `https://deploy.example.com` and sign in.

---

## Step 8 — Install the CLI (optional)

On your **laptop**, not the server:

```bash
mkdir -p ~/.local/bin
curl -o ~/.local/bin/proxdeploy \
  https://raw.githubusercontent.com/EmberGuild-Labs/proxdeploy/main/cli/proxdeploy
chmod +x ~/.local/bin/proxdeploy
proxdeploy setup
```

Make sure `~/.local/bin` is on your `PATH`.

`setup` asks for host, SSH user, SSH password, dashboard port, default domain, and the `API_KEY`
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

The easy way: click **+ Domain** in the dashboard, or run
`proxdeploy domain add example.org`. It finds the zone, routes `example.org`
and `*.example.org` through your tunnel with `proxdeploy-ingress`, and appends
the domain to `DOMAINS` in `.env` without a restart. Your Cloudflare token must
already cover the new zone. A token scoped to **All zones from an account** means
you never have to edit it again.

By hand:

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
