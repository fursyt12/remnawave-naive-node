# remnawave-naive-node

Compatibility

This fork is fully compatible with:

[remnawave-subscription-page-naive-olcrtc](https://github.com/fursyt12/remnawave-subscription-page-naive-olcrtc)

Two containers on one bridge network:

- **caddy** — custom-built Caddy (stock image doesn't have `forward_proxy`, it's
  built from `github.com/klzgrad/forwardproxy@naive` via xcaddy). Terminates TLS,
  serves the naive proxy + decoy page, auto-issues/renews the cert.
- **sync** — alpine container looping your `sync-naive.sh` every `SYNC_INTERVAL`
  seconds. Pulls users from Remnawave, manages passwords, writes the Caddy
  basic_auth file, scp's the links file out, and reloads Caddy.

## Why no `systemctl reload caddy` anymore

There's no systemd in a container, and the sync script lives in a *different*
container than Caddy anyway, so it can't reach `caddy validate`/`systemctl`
directly. Instead the Caddyfile turns on `admin 0.0.0.0:2019` (only reachable
inside `naive-net`, never published to the host), and the sync script POSTs
the Caddyfile to `http://caddy:2019/load` — this re-adapts the config,
re-reads the imported `naive-users.caddy` off disk, validates it, and applies
it atomically. If the config is broken, the POST fails loudly and the script
exits (`set -e`) instead of silently breaking prod.

## Automatic TLS

Nothing special to configure beyond what's already there — Caddy issues certs
automatically for any domain in a site block, as long as:
- `TLS_DOMAIN` actually resolves to this host,
- ports **80** (ACME HTTP-01) and **443** are reachable from the internet,
- the `caddy_data` volume persists across restarts (it does — named volume),
- `TLS_EMAIL` is set (used for Let's Encrypt account/expiry notices).

## First run

```bash
cp .env.example .env        # fill in RW_TOKEN, SSH_KEY_PATH, etc.
mkdir -p secrets
cp /path/to/id_ed25519 secrets/          # or point SSH_KEY_PATH at it directly
docker compose up -d --build
docker compose logs -f sync              # watch the first sync pass
```

`caddy_config/naive-users.caddy` ships as an empty placeholder so Caddy's
`import` doesn't choke before the sync container writes real users on its
first pass.

## Gotchas worth knowing

- **Secrets**: `.env` and `secrets/` hold the Remnawave token and the SSH
  private key — gitignore both, don't bake them into the image.
- **State persistence**: `sync_state` volume holds `naive-users.json`
  (username→password mapping). Losing it means every user gets a new
  password and every existing naive+https link breaks. Back it up.
- **Host key checking**: the scp step uses
  `StrictHostKeyChecking=accept-new` since there's no pre-seeded
  `known_hosts` in a fresh container — trusts on first connect, pins after.
- Fixed a small bug on the way: `file_server { root ... }` isn't valid Caddy
  syntax (`root` isn't a file_server subdirective) — split into
  `root * /var/www/html` + `file_server`. Probably was silently no-op-ing
  before and file_server fell back to its default root.
