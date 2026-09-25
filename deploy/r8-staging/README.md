# GrandA Website R2 — R8 staging connection kit (`jp.granda-jp.com`)

Connects the **already-deployed R7 app** to the **existing** Tencent Nginx through one new vhost.
It rebuilds nothing, starts no new Nginx, does not touch DNS, `www.granda-jp.com`, other vhosts,
or other certificates.

```
https://jp.granda-jp.com -> existing Nginx :443 (server_name) -> 127.0.0.1:<R7_PORT> -> R7 -> R7 DB
```

## Status legend

| Label | Meaning |
|---|---|
| **VERIFIED** | Proven by `tests/run_tests.sh` against a real Nginx 1.24 (throwaway instance) |
| **REQUIRES_REAL_SERVER** | Can only be confirmed on the Tencent Seoul server |
| **REQUIRES_R7_SOURCE** | Needs facts from the R7 source (not available to this kit's author) |
| **CEO_ACTION_REQUIRED** | Needs a human login/decision |

## Inputs

| Variable | Required | Source | If missing |
|---|---|---|---|
| `R7_PORT` | apply | R7 process on the server (preflight lists 127.0.0.1 listeners) | apply refuses |
| `R7_ADMIN_LOGIN_PATH` | no | **REQUIRES_R7_SOURCE** | no login rate limit rendered; verify says UNVERIFIED |
| `R7_HEALTH_PATH` | no | **REQUIRES_R7_SOURCE** | only `/` checked; UNVERIFIED |
| `R7_ROUTE_MANIFEST` | no | **REQUIRES_R7_SOURCE** (the 76 legacy + current routes, `path [status]` per line) | routes UNVERIFIED; blocklist compatibility UNVERIFIED |
| `R8_HEALTH_URLS` | no | ops: `name url` per line for Meishi/OCR/Control health endpoints | only process state + vhost fingerprints tracked |
| `SERVER_PUBLIC_IP` | no | server (preflight reads Tencent metadata) | bare-IP probe uses Host `127.0.0.1` |

The kit no longer guesses any R7 route, page or login path.

## Run order (on the Tencent Seoul server, as root) — REQUIRES_REAL_SERVER

| Step | Command | Changes anything? |
|---|---|---|
| 1 | `./r8_preflight.sh` | No (writes a report under `/root/granda-r8/`) |
| 2 | Read report: `LISTEN_POLICY`, R7 127.0.0.1 port, `DNS`, `CERT_RENEWAL` | No |
| 3 | `R7_PORT=<port> [R7_*=..] ./r8_preflight.sh` | No |
| 4 | `R7_PORT=<port> [R7_*=..] ./r8_apply.sh` | Yes — **only** the files in its manifest |
| 5 | From iPhone/another computer: `EXPECTED_IP=<ip> R7_PORT=<port> [R7_*=..] ./r8_verify.sh` | No |
| 6 | CEO admin flow (login → draft → preview → publish → unpublish) — **CEO_ACTION_REQUIRED** | App data only |

Rollback at any time: `./r8_rollback.sh` (idempotent).

`r8_verify.sh` exits 0 = all PASS, 1 = any FAIL, 2 = no FAIL but something UNVERIFIED.

## Safety guarantees — VERIFIED (test ids in brackets)

**Refuses to start (nothing written) when:**
- the existing config fails `nginx -T` [t11];
- R7 is not listening [t09] or is bound publicly [t10];
- `jp` is already configured [t25];
- another run holds the lock [t28];
- an input fails validation (domain, ports, paths) [t26];
- an R7 manifest route would be blocked by the staging blocklist [t20];
- **a shared 80/443 socket has no explicit `default_server`** [t06]. jp would otherwise become the
  bare-IP / unknown-host landing site. Fail closed; ops must mark the intended existing default first.

**HTTP/2 isolation:**
- jp never sets listen-level `http2`, which is per address:port in Nginx <1.25 and would switch every
  :443 site to HTTP/2.
- Existing sites keep their protocol [t04].
- If existing :443 listeners already use h2, jp inherits it (mirror) [t05].
- If the existing config uses the per-server `http2 on;` directive, jp gets the same.

**Default server:**
- jp is never `default_server`.
- A socket with **no** existing listener gets a reject-only sink (`return 444` / `ssl_reject_handshake`).
  Before, that was "connection refused", so no business behaviour changes [t08].
- Bare-IP and unknown-host requests still reach the existing default site [t07].

**Backup, manifest and reload:**
- Before any change: `/etc/nginx` tarball, `nginx -T` dump, resources, two baseline health snapshots.
- A manifest of exactly the files added. Any pre-existing file at those paths is a refusal.
- Every change is gated by `nginx -t`, then a graceful `nginx -s reload`. The master PID must be
  unchanged [t12].

**Regression detection, per target, stable fields only:**
- Targets: every existing hostname (http + https), bare IP (http + https without SNI), and an unknown
  host (http + https).
- Fields: status, HTTP protocol, redirect target (query stripped), certificate subject+SAN hash,
  `<title>` hash, and the Content-Type, X-Robots-Tag, HSTS and X-Frame-Options headers.
- Services: systemd running units, docker `running:healthy|unhealthy|starting|nohealthcheck`, pm2
  `online`, and optional `R8_HEALTH_URLS` status codes.
- No full-body hashes. Fields that differ between the two baseline samples are treated as dynamic and
  ignored. Targets already failing (000/5xx) at baseline are ignored.

**Automatic rollback when:**
- any tracked field changes or disappears [t13 re-injects the HTTP/2 leak; t14 an unhealthy container];
- `nginx -t` fails;
- certificate issuance fails [t24];
- any unexpected error or signal occurs mid-change [t29].

Rollback removes manifest files (only under the Nginx and renewal-hook dirs), reloads, then re-verifies
against the baseline [t15].

Defence in depth: with the default_server guard deliberately disabled, the fingerprint layer alone
still detects the bare-IP hijack and rolls back. This was checked by a mutation run, not a permanent
test.

**Certificate:**
- An existing cert is reused only if its SAN is exactly `jp.granda-jp.com` with more than 7 days left.
- Otherwise `certbot certonly --webroot` issues it for that single name; certbot never edits Nginx
  files [t23].
- `CERT_RENEWAL = PASS | GAPS | FAIL` checks certbot, an active systemd timer or a live cron entry (a
  Debian cron line guarded by `! -d /run/systemd/system` does not count on systemd hosts), and expiry.
  Having no email is not a failure [t22].

## Staging vhost policy — VERIFIED in tests; REQUIRES_REAL_SERVER for final confirmation

- HTTP → HTTPS 301; the ACME path stays on HTTP.
- `X-Robots-Tag: noindex, nofollow, noarchive` on every response, plus `robots.txt` with `Disallow: /`.
- HSTS `max-age=86400` **without** `includeSubDomains`.
- 404 for dotfiles, backup/dump/archive/log/key extensions and backup/dump/log dirs. One list lives in
  `r8_lib.sh` and feeds the vhost, `r8_verify.sh` and the manifest conflict check.
- The login rate limit (10/min, burst 5 → 429) is exact-match on `R7_ADMIN_LOGIN_PATH`, and only when
  that path is supplied [t21].
- `X-Forwarded-Proto https` is sent so R7 can set Secure cookies. Whether it does is
  **REQUIRES_R7_SOURCE** / REQUIRES_REAL_SERVER.

## Tests

```
sudo deploy/r8-staging/tests/run_tests.sh          # 29 tests, ~100 s
sudo deploy/r8-staging/tests/run_tests.sh t13      # filter by name
```

The tests use their own Nginx prefix, config and PID under `mktemp`, ports 28080/28443/28090-28099,
and stub `docker`/`systemctl`/`certbot`. They refuse to run if those ports are busy. They never touch
`/etc/nginx`, ports 80/443, Tencent, DNS or the network. They need root, nginx ≥1.19.4, openssl, curl,
python3, ss and flock.

## Not verified here

- **REQUIRES_REAL_SERVER:**
  - the server's public IP, and that `jp.granda-jp.com` resolves to it (earlier evidence was only
    INFERRED from a proxy-side resolver);
  - the real Nginx layout and existing default_server state;
  - R7 port and bind;
  - certbot/timer presence;
  - resource headroom;
  - Meishi/OCR/Control health endpoints;
  - that Meishi's `compose.yaml` publishes `8080` on all interfaces.
- **REQUIRES_R7_SOURCE:**
  - the route manifest (76 legacy routes);
  - the admin login path;
  - the health path;
  - Secure/HttpOnly cookie behaviour;
  - CSRF and upload handling;
  - the admin draft/preview/publish/unpublish flows.
- **CEO_ACTION_REQUIRED:**
  - Tencent console / OrcaTerm login to run the kit;
  - Onamae DNS check or change for `jp` only;
  - iPhone acceptance.
