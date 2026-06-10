# End-to-End Setup Checklist — myapp

Reusable checklist for deploying a bun-based Node app on RHEL 10 + Podman 5 +
NetApp FAS70, built from a WSL host on a Windows workstation.

Three locations to run commands from:
- **WSL** — your Linux build host inside Windows (where the repo is cloned, where you SSH from)
- **Server** — the RHEL host (e.g. 10.x.x.x), via SSH or Cockpit terminal
- **NetApp** — ONTAP CLI

Detailed commands and reasoning live in [`README.md`](README.md).

---

## Phase 0 — WSL host prep (one-time per workstation)

- [ ] **Windows** — `wsl --install` (or `wsl --install -d Ubuntu`) — sets up WSL2 + a Linux distro.
- [ ] **WSL** — `sudo apt update && sudo apt install -y podman openssh-client git unzip curl` (or distro equivalent).
- [ ] **WSL** — `curl -fsSL https://bun.sh/install | bash`, then ensure `~/.bun/bin` is on `PATH` (the install script writes it into `.bashrc` / `.zshrc`). `bun --version` reports 1.x.
- [ ] **WSL** — `podman info` runs without errors. (If it complains about runtime/storage, reinstall — don't use `podman machine` on WSL2.)
- [ ] **WSL** — clone the repo into the **WSL native filesystem** (`~/projects/myapp`), not `/mnt/c/...`. Cross-FS I/O makes `bun install` 2–3x slower.
- [ ] **WSL** — `ssh-keygen` if no key, `ssh-copy-id user@<server-ip>` to enable passwordless `scp`.

## Phase A — Host prep (one-time per server, sudo)

If this is the first app on the server, run the standard host-prep
steps (covered by the Caddy setup playbook). Re-verify each:

- [ ] **Server** — `podman --version` shows 5.x; `cockpit-podman` installed.
- [ ] **Server** — `loginctl show-user $USER | grep Linger` says `Linger=yes`.
- [ ] **Server** — `cat /etc/sysctl.d/90-unprivileged-ports.conf` shows `net.ipv4.ip_unprivileged_port_start=80`.
- [ ] **Server** — `sudo firewall-cmd --list-services` includes `http https`.

## Phase B — Caddy proxy (one-time per server)

The Caddy stack is shared across apps. If another app already set it
up, skip this phase. Otherwise follow the Caddy setup README from the
first deployment. Final state to verify:

- [ ] **Server** — `systemctl --user status caddy edge-net-network` both green.
- [ ] **WSL** — `curl http://<server-ip>/healthz` returns `ok`.
- [ ] **WSL** — `curl -I http://<server-ip>/` returns 200 (placeholder) or 502 (phase-1 wired but no app yet).

## Phase C — NetApp volume provisioning

Single FlexVol for Postgres (no Mongo). Sizes and SVM-specific values
are placeholders — fill from the README.

- [ ] **WSL** — `ssh admin@<ontap-cluster-mgmt-ip>` (NEVER from the RHEL host — keep creds off shared infra).
- [ ] **NetApp** — pre-flight: `cluster show` + `storage aggregate show` + `volume show` (collision check).
- [ ] **NetApp** — pick a data aggregate by free space. **Never** `aggr0_*`.
- [ ] **NetApp** — create **one FlexVol**: `vol_myapp_postgres` (junction `/myapp_postgres`), `-unix-permissions 755`.
- [ ] **NetApp** — tune: `volume efficiency on` + `policy auto`, then `volume modify -snapdir-access false`.
- [ ] **NetApp** — assign export policy (existing prod policy, or dedicated `myapp_policy` with `-superuser any`).
- [ ] **NetApp** — verify NFS service: `enabled=true`, `v3/v40/v41=enabled`, `mount-rootonly=disabled`, `showmount=enabled`.
- [ ] **Server** (sudo) — pre-flight `showmount -e <netapp-lif-ip>` (expect `/myapp_postgres`), test mount, then add **one fstab line** and `sudo mount -a`.
- [ ] **Server** (sudo) — pre-chown `/netapp/myapp_data/postgres` to the host UID that maps to container 999, then `chmod 0700`. See README §2.4.
- [ ] **Server** — `systemctl --failed` returns zero failed mount units.

## Phase D — Ship the source / deploy directory

- [ ] **WSL** — `scp -r wsl-bun-deploy-files/ user@<server-ip>:~/deploy/myapp/` (or rename to `myapp/` on the server).
- [ ] **Server** — `ls ~/deploy/myapp/` shows `Containerfile`, `.env.example`, `postgres.env.example`, `quadlets/`, etc.

## Phase E — Build, ship, and configure

The image must be built off-server because the server can't reach
public package repos at build time. See README §4.

- [ ] **WSL** — `bun --version` matches the container's base image major (1.x). If it doesn't, install matching bun (or accept the regenerate-lockfile step below).
- [ ] **WSL** — `cd ~/projects/myapp && bun install` to regenerate `bun.lock` on Linux if it was last touched on Windows. Commit the lockfile if needed.
- [ ] **WSL** — `podman build -t localhost/myapp:1.0 -t localhost/myapp:latest .` (1–3 min on first build).
- [ ] **WSL** — `podman save -o ~/myapp-image.tar localhost/myapp:1.0` (~500 MB–1 GB).
- [ ] **WSL** — `scp ~/myapp-image.tar user@<server-ip>:~/`.
- [ ] **Server** — `podman load -i ~/myapp-image.tar && podman tag localhost/myapp:1.0 localhost/myapp:latest`.
- [ ] **Server** — verify with `podman images localhost/myapp` (expect both tags).
- [ ] **Server** — `rm ~/myapp-image.tar` once loaded.
- [ ] **Server** — create `~/deploy/myapp/postgres.env` from `postgres.env.example`, chmod 600.
- [ ] **Server** — create `~/deploy/myapp/.env` from `.env.example`, chmod 600. README §5 covers the connection-string and secret values.

## Phase F — Place Quadlets and start

- [ ] **Server** — `cp ~/deploy/myapp/quadlets/* ~/.config/containers/systemd/`.
- [ ] **Server** — `systemctl --user daemon-reload`.
- [ ] **Server** — start in order: data-net → db-pod → postgres (wait for `(healthy)`) → app-pod → app. README §7.
- [ ] **Server** — verify boot survival: `systemctl --user list-dependencies default.target | grep myapp` shows all five units. (No explicit `enable` — Quadlet-generated units are transient; their `[Install] WantedBy=default.target` is honored automatically on each `daemon-reload`.)

## Phase G — Migrate, seed, wire Caddy

- [ ] **Server** — `podman exec myapp bunx prisma migrate deploy` (idempotent).
- [ ] **Server** — `podman exec myapp bunx prisma db seed` (one-shot; skip if DB already seeded, or if the project has no seed script).
- [ ] **Server** — edit `~/deploy/caddy/Caddyfile`: add the block from `caddy-vhost-snippet.txt`.
- [ ] **Server** — `podman exec caddy caddy validate ... && podman exec caddy caddy reload ...`.

## Phase H — Verify

- [ ] **Server** — `podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Pod}}'` shows caddy + 2 myapp containers, all `(healthy)`.
- [ ] **Server** — `sudo ls -la /netapp/myapp_data/postgres` shows files written by mapped UIDs.
- [ ] **WSL** — `curl -I http://<server-ip>/` returns 200, `Content-Type: text/html`.
- [ ] **Windows browser** — load the app and sign in / exercise the smoke path.

---

## Phase I — TLS handoff (when DNS for the real hostname is live)

- [ ] **DNS team** — `myapp.example.com` resolves to `<server-ip>`.
- [ ] **Server** — swap Caddyfile from the phase-1 placeholder block to the phase-2 hostname block (see `caddy-vhost-snippet.txt`).
- [ ] **Server** — set `NEXTAUTH_URL=https://myapp.example.com` in `~/deploy/myapp/.env`.
- [ ] **Server** — `caddy validate && caddy reload`, then `systemctl --user restart myapp.service`.
- [ ] **Browser** — load `https://myapp.example.com/`, verify cert + login.

---

## Common failure modes (quick lookup)

| Symptom | Most likely cause | Where to look |
|---|---|---|
| `bun install --frozen-lockfile` fails inside the container | Lockfile out of sync — bun major-version skew between dev and base image, OR lockfile last touched outside WSL | Regenerate in WSL: `rm bun.lock bun.lockb && bun install` (README §4.1) |
| `mount.nfs: access denied by server` | Junction case mismatch, `mount-rootonly` enabled, or export policy missing client IP | README §1.5 / §2.1 |
| 17+ failed mount units at boot | fstab using `defaults` instead of `vers=3,tcp,mountproto=tcp` | README §2.3 |
| Postgres container exits with `chmod`/`chown: Operation not permitted` | Container starts as root and tries to chmod NFS dir; rootless+NFS can't allow this. Set `User=999:999` in Quadlet, pre-chown dir to `<subuid_base>+998` | README §2.4 |
| `chmod 0777` on data dir doesn't fix permission denied | Mapped UID isn't the dir owner. `chmod` lets others write but doesn't grant ownership for chmod/chown — use `chown` to mapped UID instead | README §2.4 |
| `prisma migrate deploy` fails with connection refused | DB not yet healthy — `Requires=`/`After=` only orders start, not readiness | Wait for `(healthy)` in `podman ps` before migrating |
| `next build` fails with `DATABASE_URL` or other required env not defined | App imports modules that throw at module-eval if the var is missing; Next.js page-data collection imports every route during build | Containerfile sets placeholder envs in build stage; restore from the project's Containerfile in this folder if missing |
| `bun start` exits immediately with `script not found "start"` | Project's `package.json` has no `start` script | Add `"start": "next start"`, OR change Containerfile `CMD` to `["bun", "run", "next", "start"]` |
| `podman build` fails on `apt-get update` (cert / repo / network) | Server blocks HTTP:80 outbound; corporate TLS interception breaks HTTPS without CA bundle | Build off-server in WSL, ship via `podman save \| scp \| podman load` (README §4) |
| Quadlet generates network unit but skips a `.container` | Invalid directive in the .container file. Common: `MemoryMax=` belongs in `[Service]`, not `[Container]` | `/usr/libexec/podman/quadlet -dryrun -user 2>&1 \| grep -B1 error` |
| Healthcheck fails with `/bin/sh: Syntax error: "(" unexpected` | Quadlet's `HealthCmd=` runs through `sh -c`; parens / quotes / pipes get parsed as shell syntax | Avoid special chars in `HealthCmd` |
| `caddy reload` fails with `connection refused` on port 2019 | `admin off` in Caddyfile globals disables the API that reload posts to | Use `admin localhost:2019` (default, container-internal only) |
| Caddyfile edits don't show up after `caddy reload` | Single-file bind mount got a new inode when editor renamed-on-save; container still bound to old inode | `systemctl --user restart caddy`, or use vim with `set backupcopy=yes` going forward |
| Caddy 502 | App pod not running, not on `edge-net`, or container name typo in `reverse_proxy` upstream | Check `podman ps`, `podman pod inspect myapp-pod` |
| `systemctl --user enable` errors with `Unit … is transient or generated` | Quadlet units live in `/run/user/$UID/systemd/generator/` — can't be enabled. `[Install] WantedBy=default.target` in the Quadlet does the equivalent automatically | README §7 |
| App can't resolve `myapp-postgres` / `myapp` even though pods are healthy | aardvark-dns registers the **pod** name, not container names. Pod Quadlets carry `NetworkAlias=` for the container names; if aliases are missing or aardvark didn't reload, names won't resolve | `grep NetworkAlias= ~/.config/containers/systemd/*.pod` |
| Login UI shows "Server error" / `UntrustedHost: Host must be trusted` in app logs | Auth.js v5 rejects requests by default behind a reverse proxy unless `AUTH_TRUST_HOST=true` is set | Add `AUTH_TRUST_HOST=true` to `.env`, `systemctl --user restart myapp` |
| Connection string env vars come into the container with literal `""` quotes around the value | Podman `--env-file` doesn't strip quotes the way systemd's `EnvironmentFile` does | Strip surrounding quotes from `.env` lines |
| Prisma errors with "URL must start with protocol postgresql://" but URL looks correct | Either surrounding quotes are part of the value, OR the password contains unencoded `+` / `/` that breaks URL parsing | Strip quotes; URL-encode `+` → `%2B`, `/` → `%2F` in DB password segment |
| `bun install` extremely slow on WSL | Repo lives on `/mnt/c/...` (Windows side); cross-FS I/O is the bottleneck | Clone to WSL native FS (`~/projects/myapp`) |

---

## Per-app rename checklist

This stack is a template. To deploy a real app, search-and-replace
`myapp` (in filenames, Quadlet contents, env files, READMEs) with a
real slug. Identifiers to change:

| Identifier | Pattern | myapp value |
|---|---|---|
| App slug (Podman objects) | `<slug>-*` | `myapp` |
| NetApp volume (Postgres) | `vol_<slug>_postgres` | `vol_myapp_postgres` |
| NetApp junction (Postgres) | `/<slug>_postgres` | `/myapp_postgres` |
| Host mount (Postgres) | `/netapp/<slug>_data/postgres` | `/netapp/myapp_data/postgres` |
| Image tag | `localhost/<slug>:1.0` | `localhost/myapp:1.0` |
| Network | `<slug>-data-net` | `myapp-data-net` |
| App pod | `<slug>-pod` | `myapp-pod` |
| DB pod | `<slug>-db-pod` | `myapp-db-pod` |
| Containers | `<slug>`, `<slug>-postgres` | `myapp`, `myapp-postgres` |
| Caddy upstream | `reverse_proxy <slug>:3000` | `reverse_proxy myapp:3000` |
| Deploy dir on server | `~/deploy/<slug>/` | `~/deploy/myapp/` |
| Phase-2 hostname | `<slug>.example.com` | `myapp.example.com` |
