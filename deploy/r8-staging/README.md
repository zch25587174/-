# GrandA Website R2 — R8 staging connection kit (`jp.granda-jp.com`)

Task: `GRANDA_WEBSITE_R2_R8_CLAUDE_TAKEOVER`. This connects the **already-deployed R7 app**
to the **existing** Tencent Nginx. It rebuilds nothing, starts no new Nginx, does not touch DNS,
`www.granda-jp.com`, other vhosts, or other certificates.

```
https://jp.granda-jp.com -> existing Nginx :443 (server_name) -> 127.0.0.1:<R7_PORT> -> R7 -> R7 DB
```

## Run order (on the Tencent Seoul server, as root)

| Step | Command | Changes anything? |
|---|---|---|
| 1 | `./r8_preflight.sh` | No. Records services, ports, Nginx (`nginx -T`), resources, DNS vs server IP, TLS, health baseline in `/root/granda-r8/preflight-*/` |
| 2 | Read report: pick R7's **127.0.0.1** port; confirm DNS A = server public IP | No |
| 3 | `./r8_preflight.sh <R7_PORT>` | No. Confirms R7 bind is localhost-only and `/`, `/admin/` answer |
| 4 | `R7_PORT=<port> ./r8_apply.sh` | Yes, **only** the files listed in its manifest |
| 5 | From iPhone / another computer: `./r8_verify.sh jp.granda-jp.com <R7_PORT> <server_ip>` | No |
| 6 | Real admin flow (login → draft → preview → publish → unpublish) | App data only |

Rollback at any time: `./r8_rollback.sh` (uses `/root/granda-r8/last-apply`).

## What `r8_apply.sh` guarantees

- **Refuses to start** if: current Nginx config already fails `nginx -t`; nothing listens on `R7_PORT`;
  R7 is bound to a public address; `jp.granda-jp.com` already exists in the Nginx config.
- **Before-backup**: `/etc/nginx` tarball, `nginx -T` dump, resources, health snapshot → `/root/granda-r8/apply-<ts>/`.
- **Manifest**: exactly the files it adds (vhost, its symlink, `/etc/nginx/granda-r8-proxy.inc`, certbot reload hook).
- **Certificate**: reuses an existing cert only if its SAN is exactly `jp.granda-jp.com` and >7 days remain;
  otherwise `certbot certonly --webroot` for that single name (no `--nginx` plugin, so certbot never edits Nginx files).
- Every change: `nginx -t` → only if PASS → `nginx -s reload` (graceful, **never restart**).
- After each reload, every existing `server_name` is probed on 80/443 and every running
  systemd service / docker container / pm2 process is compared to the baseline.
  Any site going to 5xx/000 or any process disappearing → **automatic rollback** (remove manifest files, `nginx -t`, reload, re-verify).
- IPv6 listeners are emitted only if the existing config already uses `[::]`.

## Staging vhost policy

- HTTP → HTTPS 301; ACME path served for renewals.
- `X-Robots-Tag: noindex, nofollow, noarchive` on every response + `robots.txt` `Disallow: /`.
- HSTS `max-age=86400` **without** `includeSubDomains` (must not affect `www` or other hosts).
- 404 for dotfiles (`.env`, `.git/…`), backups/dumps/archives/logs/keys by extension, `/backup(s)`, `/dump(s)`, `/log(s)`.
- `autoindex off`, `server_tokens off`, 20 MB upload cap.
- `/admin/(login|auth|session)` rate-limited 10 req/min per IP (burst 5) → 429.
- `X-Forwarded-Proto https` passed so R7 can set `Secure` cookies.

## Verified in this repo (simulated server, Nginx 1.24)

Apply → vhost live, existing vhost unchanged, `nginx -T` diff = only R8 additions; noindex/HSTS headers present;
sensitive paths 404; robots disallow; HTTP→HTTPS 301; login 429 after burst; manual rollback restores original set;
forced `nginx -t` failure → auto rollback, original config valid; public-bind R7 → refused;
regression detector flags `200→502` and a stopped pm2 process, ignores sites already failing before.

**Not** verified here: the real Tencent server, real R7, real DNS/TLS — this session has no route to them (see status).
