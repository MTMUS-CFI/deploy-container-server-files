# myapp — Server Deployment (WSL + bun flavor)

Reusable deploy bundle for a Next.js + Prisma + Postgres app that:
- Was developed on **Windows/WSL with bun** (not npm).
- Uses **Postgres only** (no Mongo / GridFS).
- Targets the same RHEL 10 + rootless Podman 5 + NetApp + Caddy
  infrastructure as the npm and doc-app stacks, but uses the bun
  runtime end-to-end (build *and* runtime inside the container).

## REQUIRED — rename `myapp` before deploying

**Do not deploy with the literal slug `myapp`.** Every Podman object,
NetApp volume, env file, hostname stub, and systemd unit name in this
bundle uses `myapp` as a placeholder. Shipping it as-is will:

- collide with any other app on the server that did the same;
- name your NetApp volume `vol_myapp_postgres` (literally), making
  storage audits useless and inviting accidental cross-app restore;
- generate systemd unit names like `myapp.service` that tell an
  operator nothing about what's running;
- produce a Caddy vhost matching `myapp.local` / `myapp.example.com`
  that doesn't match your real DNS.

This is non-negotiable. Treat it like a `CHANGE_ME` in an env file.

### Three forms — keep them straight

Every occurrence of the slug uses one of three forms, and each form is
required by the layer that consumes it. The rename script below handles
all three; this table is so you understand what it's doing.

| Form | Where it appears | Why |
|---|---|---|
| `myapp-<thing>` (hyphen) | Podman networks, pods, containers, image tags (`localhost/myapp:1.0`), Caddy upstream (`reverse_proxy myapp:3000`), Quadlet filenames | Podman / DNS conventions prefer hyphens in resolvable names |
| `myapp_<thing>` (underscore) | NetApp FlexVol names (`vol_myapp_postgres`), junctions (`/myapp_postgres`), host fstab mount points (`/netapp/myapp_data/postgres`), Postgres role / DB names | NetApp + Postgres conventions; NFS junctions are case-sensitive |
| bare `myapp` | Hostname stub (`myapp.local`), Caddy upstream container name, Mongo DB name | Same slug, no suffix |

Pick a slug that works as **all three forms** — lowercase, no spaces, no
dots, no leading digit. Hyphens are fine; the script auto-translates to
underscores for the NetApp/Postgres forms. Keep it under ~30 characters
so combined names like `<slug>-data-net-network.service` stay readable.

### Concrete rename — copy/paste, then VERIFY zero `myapp` remain

```bash
# 1. Decide your slug (hyphenated, lowercase, no dots/spaces).
#    Examples: dor, billing, daily-overview-report.
APP_SLUG=replace-me
APP_SLUG_UNDER=$(echo "$APP_SLUG" | tr '-' '_')

# 2. cd to the bundle root (this folder, the one with Containerfile in it).
cd <bundle root — e.g. ~/projects/<your-repo>/bun>

# 3. Rename FILES whose names contain `myapp`.
find . -depth -name 'myapp*' -print | while read f; do
  mv "$f" "$(dirname "$f")/$(basename "$f" | sed "s/^myapp/$APP_SLUG/")"
done

# 4. Replace CONTENT — underscored form FIRST, then hyphenated, then bare.
#    Order matters: the hyphenated replace would otherwise leave
#    `myapp_postgres` untouched because it has no trailing hyphen,
#    and the bare replace would clobber things the others should claim.
find . -type f \( -name 'Containerfile' -o -name '*.md' -o -name '*.network' \
                  -o -name '*.pod' -o -name '*.container' -o -name '*.example' \
                  -o -name '*.txt' \) -print0 \
| xargs -0 sed -i "s/myapp_/${APP_SLUG_UNDER}_/g; \
                   s/myapp-/${APP_SLUG}-/g; \
                   s/\\bmyapp\\b/${APP_SLUG}/g"

# 5. VERIFY — this must print "OK". Any hit must be fixed by hand.
grep -rn 'myapp' . && echo "RENAME INCOMPLETE — fix above hits" || echo OK
```

**Step 5 is the one that matters.** Anything `grep` finds after step 4
will either fail at runtime or — worse — attach the wrong NetApp volume
to the wrong pod and write live app data to someone else's storage.
Do not skip the verify.

A reference table mapping every identifier to its renamed form lives at
the bottom of [`SETUP_CHECKLIST.md`](SETUP_CHECKLIST.md). If you use any
add-ons (see "Add-ons" below), re-run the same rename inside each addon
folder you keep — addon files use the same `myapp` placeholder.

## What's in this folder

| File | Purpose |
|---|---|
| `Containerfile` | Multi-stage image build — `oven/bun:1-debian` base, `bun install`, Prisma generate, `bun run build`, `CMD bun start`. |
| `.env.example` | App-level secrets template — DATABASE_URL, Auth.js v5 vars. |
| `postgres.env.example` | Postgres seed credentials. |
| `quadlets/myapp-data-net.network` | Internal, no-egress network for the DB. |
| `quadlets/myapp-pod.pod` | App pod, dual-homed on edge-net + data-net. |
| `quadlets/myapp-db-pod.pod` | DB pod, data-net only. |
| `quadlets/myapp-postgres.container` | Postgres 16, NFS-backed, runs as UID 999. |
| `quadlets/myapp.container` | The bun app container. |
| `caddy-vhost-snippet.txt` | Block to add to the shared `Caddyfile`. |
| `REDEPLOY.md` | Day-to-day "ship a new build" runbook. |
| `SETUP_CHECKLIST.md` | First-time end-to-end checklist. |
| `README.md` | This file — full setup walkthrough with reasoning. |
| `mongo-addon/` | **Optional add-on** — MongoDB 7 container alongside Postgres (GridFS file storage, document collections). See `mongo-addon/README.md`. |

## Add-ons (optional)

The base bundle ships **Postgres-only**. Capabilities the project doesn't
need by default (a second database, an object store, a cache) live in
opt-in `*-addon/` subfolders. Each addon has its own README with the
NetApp / Quadlet / env steps to bolt it on.

Currently available:

| Folder | Adds | Typical reason to enable |
|---|---|---|
| `mongo-addon/` | MongoDB 7 container in the same DB pod | GridFS file storage, or document collections that don't fit Postgres `jsonb` |

How addons are structured — worth knowing so you can judge whether the
pattern fits a future need:

- Each addon lives in its own subfolder (`mongo-addon/`, future
  `redis-addon/`, etc.). The base bundle stays clean — if you don't
  need an addon, delete its folder and the base setup is unchanged.
- An addon may slot into the existing `myapp-db-pod` (Mongo does), or
  introduce its own pod / network if it needs different isolation.
- Every addon typically requires the same shape of integration: a
  dedicated NetApp volume, a fstab line, a pre-chown for the
  rootless-mapped UID, a Quadlet drop, a **one-line edit** to the base
  `myapp-db-pod.pod` (adding a `NetworkAlias=` for the new service),
  a new env file, and a new env var in the app `.env`.
- Addons reuse the same `myapp` placeholder convention — re-run the
  rename script from the section above inside each addon folder you
  keep before deploying.
- An addon's README is authoritative for that addon's quirks
  (auth-source rules, healthcheck specifics, snapshot timing). The
  base bundle's troubleshooting catalog covers everything else.

Don't add an addon "in case we need it later." Each one is a NetApp
volume + a running container + a backup target + a security surface.
Add only what the app actually uses.

## When to use this bundle vs. the npm bundle

| Project trait | Use |
|---|---|
| `package.json` has `"packageManager": "bun@..."` or contains `bun.lock` / `bun.lockb` | **this bundle** |
| Project README documents `bun dev` / `bun run build` workflows | **this bundle** |
| `package-lock.json` exists and is canonical, no bun lockfile | `wsl-npm-deploy-files/` |
| Mixed history with both lockfiles | pick one in the project and delete the other — keeping both is the #1 source of "works on my machine" |

Bun and npm produce different `node_modules` shapes (different hoisting,
different binary handling). Don't try to run one bundle's image with the
other's lockfile.

## How this differs from the npm bundle

| Concern | npm bundle | bun bundle (this one) |
|---|---|---|
| Containerfile base | `docker.io/node:24-bookworm` | `docker.io/oven/bun:1-debian` |
| Install command | `npm ci` | `bun install --frozen-lockfile` |
| Prisma generate | `npx prisma generate` | `bunx prisma generate` |
| Build command | `npm run build` | `bun run build` |
| Runtime entrypoint | `CMD ["npm", "start"]` | `CMD ["bun", "start"]` |
| Lockfile copied in | `package-lock.json` | `bun.lock` / `bun.lockb` (wildcard handles either) |
| Migration command in container | `npx prisma migrate deploy` | `bunx prisma migrate deploy` |
| Seed command | `npx prisma db seed` | `bunx prisma db seed` |
| Typical first-build time | 5–10 min | 1–3 min (bun install is much faster) |
| Image size | ~500 MB–1 GB | similar (Debian base + node_modules dominates) |

Everything else (NetApp provisioning, fstab options, UID-mapping for
NFS, Quadlet exit-policy quirks, aardvark-dns aliases, HealthCmd
shell-parsing limits, env-file no-quotes / URL-encode rules) is
identical and the same wisdom carries over.

## Topology

```
edge-net (shared, host-bridged) ◀── Caddy (separate pod)
  │
  └─ myapp-pod ─── myapp (Next.js via bun, port 3000)
        │
        └── myapp-data-net (internal, no internet egress)
              │
              └─ myapp-db-pod ─── myapp-postgres (5432) ─── /netapp/myapp_data/postgres ◀── vol_myapp_postgres
```

**Prerequisites**: the Caddy stack is already running on the server
(`curl http://<server-ip>/healthz` returns `ok`), `edge-net` exists,
the operator's `loginctl enable-linger` is on, and the
unprivileged-port floor is lowered. If this is the first app on a
fresh server, do that setup first.

---

## 0. Prepare WSL on the Windows workstation

One-time setup on the development laptop.

```powershell
# In a Windows PowerShell as Administrator
wsl --install -d Ubuntu
# Reboot if prompted, then set up the Ubuntu user when WSL drops you in
```

Inside the Ubuntu WSL prompt:

```bash
sudo apt update
sudo apt install -y podman openssh-client git unzip curl

# Install bun (official install script — drops a binary into ~/.bun/bin)
curl -fsSL https://bun.sh/install | bash
# Either restart the shell or:
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
bun --version          # confirm 1.x

podman info >/dev/null && echo OK

# Clone the project into the WSL native filesystem — NOT under /mnt/c/.
# Cross-filesystem I/O between WSL2 and Windows makes bun install
# noticeably slower (less dramatic than npm, but still real).
mkdir -p ~/projects
cd ~/projects
git clone <repo-url> myapp
cd myapp

# Drop this deploy folder alongside the project (or keep it inside the
# repo as `wsl-bun-deploy-files/`).

# SSH key for the server
ssh-keygen -t ed25519        # accept defaults
ssh-copy-id user@<server-ip>
ssh user@<server-ip>         # confirm passwordless
```

### Why WSL specifically

Building Linux container images on Windows needs a Linux build host.
Bun does have a native Windows build, but:

1. The runtime container needs Linux-compatible `node_modules` (some
   packages pull platform-specific binaries during install). A bun
   install run on Windows can write a lockfile that's missing Linux
   binaries — same failure mode the npm bundle warns about.
2. Podman itself needs Linux.

WSL gives you both. Run `bun install` *inside WSL* so the lockfile and
node_modules layout match what the container will produce. The dev can
edit project files from Windows (VS Code's WSL extension makes this
seamless), but all install / build / publish operations happen on the
Linux side.

---

## 1. Provision the NetApp volume (ONTAP CLI)

Single FlexVol for Postgres. Identical to the npm bundle's §1 — the
ONTAP commands don't care about which package manager built the image.
Summary:

```bash
# From WSL — never SSH to ONTAP from the RHEL host
ssh admin@<ontap-cluster-mgmt-ip>
```

```ontap
# Pre-flight
cluster show
storage aggregate show
volume show -vserver <SVM> -fields volume,size,junction-path

# Create the Postgres volume (pick the aggregate with more free space)
volume create \
  -vserver <SVM> \
  -volume vol_myapp_postgres \
  -aggregate <data-aggregate> \
  -size 50GB \
  -junction-path /myapp_postgres \
  -security-style unix \
  -state online \
  -space-guarantee none \
  -snapshot-policy default \
  -percent-snapshot-space 5 \
  -unix-permissions 755

# Tune
volume efficiency on -vserver <SVM> -volume vol_myapp_postgres
volume efficiency modify -vserver <SVM> -volume vol_myapp_postgres -policy auto
volume modify -vserver <SVM> -volume vol_myapp_postgres -snapdir-access false

# Export policy — `-superuser any` is required for rootless mapped UIDs
volume modify -vserver <SVM> -volume vol_myapp_postgres -policy <prod-policy>

# NFS service sanity (verify, don't blindly modify)
vserver nfs show -vserver <SVM> \
  -fields enabled,v3,v40,v41,mount-rootonly,showmount
# Expected: enabled=true, v3/v40/v41=enabled, mount-rootonly=disabled, showmount=enabled
```

> **Never** use `aggr0_*` aggregates — they hold the cluster's root
> volumes and have very little free space. Always pick a data
> aggregate (`aggr1_*`, `aggr_data_*`, etc.) by free space.

---

## 2. Mount the NetApp volume on the RHEL host

Run on the server. Steps 2.1–2.3 require **sudo**.

### 2.1 Pre-flight

```bash
# NFS port reachable?
timeout 3 bash -c 'echo > /dev/tcp/<netapp-lif-ip>/2049' \
  && echo "NFS port open" || echo "NFS port BLOCKED"

# Does the NetApp advertise our junction?
showmount -e <netapp-lif-ip>
# Expect to see /myapp_postgres in the output.
```

### 2.2 Test mount

```bash
sudo mkdir -p /mnt/test_myapp_postgres
sudo mount -t nfs -o vers=3,tcp,mountproto=tcp \
  <netapp-lif-ip>:/myapp_postgres /mnt/test_myapp_postgres
df -h /mnt/test_myapp_postgres
sudo umount /mnt/test_myapp_postgres
sudo rmdir /mnt/test_myapp_postgres
```

### 2.3 Permanent mount via fstab

`vers=3,tcp,mountproto=tcp` is **required** — `defaults` lets the
client negotiate v4.2/UDP which hangs on this cluster.

```bash
sudo mkdir -p /netapp/myapp_data/postgres

sudo tee -a /etc/fstab >/dev/null <<'EOF'
<netapp-lif-ip>:/myapp_postgres  /netapp/myapp_data/postgres  nfs  vers=3,tcp,mountproto=tcp,hard,intr,rsize=65536,wsize=65536,_netdev  0  0
EOF

sudo systemctl daemon-reload
sudo mount -a
systemctl --failed       # zero failed units
df -h | grep netapp
```

### 2.4 Pre-chown for the rootless-mapped UID

The Postgres container runs as UID 999 (the postgres user inside the
image). Under rootless Podman, that maps to host UID
`<subuid_base> + 998` — typically a value like `100998` or `525286`
depending on `/etc/subuid`. The NFS volume root must be owned by **that
host UID** before Postgres starts, otherwise the entrypoint's root
branch fails on `chown`/`chmod` operations that NFS rejects.

The Quadlet sets `User=999:999` so the container runs as UID 999 from
the start (skipping the entrypoint's root branch entirely). All we
need to do is pre-chown the dir to match.

```bash
# Confirm the volume is mounted
df -h | grep myapp

# Compute the mapped UID once
SUBUID_BASE=$(grep "^${USER}:" /etc/subuid | awk -F: '{print $2}')
PG_HOST_UID=$((SUBUID_BASE + 998))
echo "Container UID 999 maps to host UID: $PG_HOST_UID"

# Chown the volume root to that mapped UID. Sudo + NetApp's
# -superuser any export-policy flag is what lets this through to NFS.
sudo chown -R "$PG_HOST_UID:$PG_HOST_UID" /netapp/myapp_data/postgres

# Lock down to 0700 — postgres specifically rejects looser modes on initdb.
sudo chmod 0700 /netapp/myapp_data/postgres

# Sanity check — can the mapped UID write?
sudo -u "#$PG_HOST_UID" touch /netapp/myapp_data/postgres/.writetest \
  && sudo rm /netapp/myapp_data/postgres/.writetest \
  && echo "Postgres volume writable by mapped UID" \
  || echo "Postgres volume write FAILED — verify -superuser any on NetApp policy"
```

> **NEVER `chmod 0777` the volume root** as a "fix" for permission
> errors. Postgres' entrypoint expects 0700 and will refuse to start
> on `initdb: data directory has invalid permissions`.

---

## 3. Place the deploy bundle on the server

From WSL:

```bash
# Ship just the deploy files (Quadlets, envs, README) for first setup
scp -r ~/projects/myapp/wsl-bun-deploy-files user@<server-ip>:~/deploy/myapp
```

Or ship the whole repo if you want the Containerfile / Prisma schema /
seed scripts on the server as well:

```bash
scp -r ~/projects/myapp user@<server-ip>:~/deploy/myapp
```

(The image tarball gets shipped separately in step 4.)

---

## 4. Build the app image (off-server, then ship)

The server's outbound network blocks public package mirrors at build
time. The build runs in WSL; the resulting image is saved to a tarball
and loaded onto the server.

### 4.1 Build in WSL

```bash
cd ~/projects/myapp     # the repo root, where the Containerfile lives
podman build -t localhost/myapp:1.0 -t localhost/myapp:latest .
```

1–3 min on first build (bun's install is much faster than npm); ~30–90s
for incremental builds with the layer cache warm. Tag both `:1.0` and
`:latest` — the Quadlet's `Image=` directive references `:latest`.

Verify locally:

```bash
podman images localhost/myapp
# Expect both :1.0 and :latest, ~500 MB–1 GB
```

#### If `bun install --frozen-lockfile` fails inside the container

The most common cause is a lockfile mismatch: someone ran `bun install`
on a different bun major (1.0.x vs 1.1.x) than the base image, or the
lockfile was last touched outside WSL. Fix in WSL:

```bash
# Same bun major as the container's base image (oven/bun:1-debian → bun 1.x)
bun --version                           # confirm 1.x
rm -rf node_modules bun.lock bun.lockb
bun install                             # regenerates the lockfile
git status                              # commit the regenerated lockfile
```

This is the bun-equivalent of the `npm ci` lockfile-out-of-sync issue
the npm bundle warns about. Bun is less prone to it (its install isn't
platform-conditional the way npm's optional binaries are), but bun
major-version skew between dev and CI still causes it.

### 4.2 Save the image

```bash
podman save -o ~/myapp-image.tar localhost/myapp:1.0
ls -lh ~/myapp-image.tar
```

### 4.3 Ship to the server

```bash
scp ~/myapp-image.tar user@<server-ip>:~/
```

### 4.4 Load on the server

```bash
# On the server (ssh user@<server-ip>):
podman load -i ~/myapp-image.tar

# podman save preserves the source tag (:1.0). Re-create :latest:
podman tag localhost/myapp:1.0 localhost/myapp:latest

podman images localhost/myapp
# Expect both :1.0 and :latest entries

rm ~/myapp-image.tar     # optional cleanup
```

### Why not `podman build` on the server

`apt-get` in the build container needs outbound access to the Debian
mirrors. The server blocks plain HTTP:80, and corporate TLS
interception breaks HTTPS without the corporate CA bundle (which the
build container doesn't carry). The `build → save → scp → load` flow
sidesteps both — the only outbound the server needs is the inbound
SCP from WSL.

---

## 5. Create the two env files

Both live alongside the deploy bundle under `~/deploy/myapp/` and must
be chmod 600 (only the operator reads them).

```bash
cd ~/deploy/myapp

# Postgres credentials
cp postgres.env.example postgres.env
chmod 600 postgres.env
$EDITOR postgres.env

# App config + secrets
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

Generate strong values:

```bash
openssl rand -base64 32   # NEXTAUTH_SECRET / opaque tokens
openssl rand -base64 24   # POSTGRES_PASSWORD
openssl rand -hex 32      # if your app uses any 64-hex-char secret
```

Fill `.env` so `DATABASE_URL` references the Postgres values:

```
DATABASE_URL=postgresql://<POSTGRES_USER>:<URL_ENCODED_PASSWORD>@myapp-postgres:5432/<POSTGRES_DB>?schema=public
NEXTAUTH_URL=http://<server-ip>
NEXTAUTH_SECRET=<openssl output>
AUTH_TRUST_HOST=true
```

Three rules that bite if missed:

1. **No surrounding quotes.** Podman's `--env-file` (which Quadlet
   uses) treats `"..."` as part of the value, unlike systemd's
   `EnvironmentFile` which strips them. Each line must be plain
   `KEY=value` to end-of-line.
2. **URL-encode `+` and `/` in DB passwords.** The password segment of
   `DATABASE_URL` lives between `:` and `@`, and any `/` in it is
   interpreted as the path separator. `+` → `%2B`, `/` → `%2F`. Apply
   this **only** in the URL field; the matching `POSTGRES_PASSWORD` in
   `postgres.env` stays raw because Postgres stores it verbatim.
3. **`AUTH_TRUST_HOST=true` is required** if the app uses Auth.js v5.
   Auth.js rejects requests by default unless this is set, surfacing
   as `UntrustedHost: Host must be trusted` in the app logs and
   "Server error" in the browser. Caddy is the trusted edge here.

Switch `NEXTAUTH_URL` to `https://myapp.example.com` when DNS + TLS
go live (only env change required at that point).

---

## 6. Place the Quadlets

```bash
mkdir -p ~/.config/containers/systemd

cd ~/deploy/myapp
cp quadlets/myapp-data-net.network    ~/.config/containers/systemd/
cp quadlets/myapp-pod.pod             ~/.config/containers/systemd/
cp quadlets/myapp-db-pod.pod          ~/.config/containers/systemd/
cp quadlets/myapp-postgres.container  ~/.config/containers/systemd/
cp quadlets/myapp.container           ~/.config/containers/systemd/
```

(The Caddy Quadlets from the shared edge-proxy setup should already
be in place.)

---

## 7. Reload systemd and start in order

```bash
systemctl --user daemon-reload

# Network first
systemctl --user start myapp-data-net-network.service

# DB pod + Postgres (NFS mount must already be up — fstab from step 2)
systemctl --user start myapp-db-pod-pod.service
systemctl --user start myapp-postgres.service

# Watch for "(healthy)" — typically 30s:
podman ps --format 'table {{.Names}}\t{{.Status}}'

# App pod + container
systemctl --user start myapp-pod-pod.service
systemctl --user start myapp.service
```

**No `systemctl --user enable` needed.** Quadlet-generated units live
in `/run/user/$UID/systemd/generator/` (transient — regenerated on
every `daemon-reload`), and systemd refuses to enable transient units.
Each Quadlet's `[Install] WantedBy=default.target` directive already
wires the services into `default.target`. They come back automatically
after a reboot. Verify with:

```bash
systemctl --user list-dependencies default.target | grep myapp
# Expect five lines: data-net-network, db-pod-pod, postgres, app-pod-pod, app
```

> **Note on unit names**: Quadlet appends `-network`/`-pod` to the
> generated unit names. `myapp-data-net.network` →
> `myapp-data-net-network.service`, `myapp-pod.pod` →
> `myapp-pod-pod.service`, etc. The "-pod-pod" and "-net-network" are
> aesthetic, not bugs. `.container` files are clean:
> `myapp.container` → `myapp.service`.

---

## 8. Migrations + seed (one-shot)

```bash
podman exec myapp bunx prisma migrate deploy

# Only on a fresh database — re-running may fail on unique constraints:
podman exec myapp bunx prisma db seed
```

Some projects don't define a seed script — skip if so. If the project
runs its seed via `bun run` against a TS file (e.g.
`bun run prisma/seed.ts`), use that instead.

---

## 9. Wire Caddy to the app

Edit `~/deploy/caddy/Caddyfile` and add the block from
`caddy-vhost-snippet.txt`:

```caddy
myapp.local {
    encode zstd gzip

    reverse_proxy myapp:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}

        transport http {
            read_timeout 5m
            write_timeout 5m
            dial_timeout 10s
        }
    }

    handle /healthz { respond "ok" 200 }
}
```

Validate and reload:

```bash
podman exec caddy caddy validate --config /etc/caddy/Caddyfile
podman exec caddy caddy reload   --config /etc/caddy/Caddyfile
```

`validate` first — `reload` will refuse a broken config and the
running Caddy keeps serving the previous one.

To test from WSL with the hostname stub:

```bash
curl -H 'Host: myapp.local' -I http://<server-ip>/
```

When real DNS goes live, swap to the phase-2 hostname block (see
`caddy-vhost-snippet.txt`) and update `NEXTAUTH_URL` in `.env`.

---

## 10. Verify

```bash
# All containers up?
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Pod}}'

# NetApp data dir claimed by Postgres?
sudo ls -la /netapp/myapp_data/postgres

# App responding through Caddy?
curl -H 'Host: myapp.local' -I http://<server-ip>/

# Database connectivity:
podman exec myapp bunx prisma db pull --print | head
podman exec -it myapp-postgres psql -U "$POSTGRES_USER" -c '\dt'
```

Open the app in a browser (with /etc/hosts mapping for `myapp.local`
or via the real hostname once DNS is live) and run a smoke test.

---

## Going to TLS

When DNS for `myapp.example.com` points to `<server-ip>`:

1. Replace the `myapp.local { ... }` block in the Caddyfile with the
   phase-2 hostname block (see `caddy-vhost-snippet.txt`).
2. Update `.env`: `NEXTAUTH_URL=https://myapp.example.com`.
3. Reload:
   ```bash
   podman exec caddy caddy reload --config /etc/caddy/Caddyfile
   systemctl --user restart myapp.service
   ```

Caddy auto-provisions a Let's Encrypt cert via HTTP-01 (port 80 must
remain reachable from the public internet). For an internal-only
domain, swap to `tls internal`.

---

## Ops cheat sheet

| Action | Command |
|---|---|
| Tail app logs | `journalctl --user -u myapp -f` |
| Restart app only | `systemctl --user restart myapp.service` |
| Restart Postgres | `systemctl --user restart myapp-postgres` |
| Rebuild image after code change | (WSL) `cd ~/projects/myapp && podman build -t localhost/myapp:1.0 -t localhost/myapp:latest . && podman save -o ~/myapp-image.tar localhost/myapp:1.0 && scp ~/myapp-image.tar user@<server-ip>:~/` then on server: `podman load -i ~/myapp-image.tar && podman tag localhost/myapp:1.0 localhost/myapp:latest && systemctl --user restart myapp` |
| Apply new migration | `podman exec myapp bunx prisma migrate deploy` |
| Open a bun shell in the running container | `podman exec -it myapp bun repl` |
| Postgres shell | `podman exec -it myapp-postgres psql -U "$POSTGRES_USER"` |
| ONTAP snapshot before upgrade | `volume snapshot create -vserver <SVM> -volume vol_myapp_postgres -snapshot premigration_$(date +%F)` |
| Inspect generated systemd unit | `systemctl --user cat myapp.service` |
| Backup Postgres | `podman exec myapp-postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > pg-$(date +%F).sql` |

---

## Troubleshooting

- **`bun install --frozen-lockfile` fails in the build** — see §4.1.
  Most often a bun major-version skew between dev and the base image,
  or the lockfile was touched outside WSL. Regenerate in WSL and rebuild.
- **`mount.nfs: access denied by server`** — three possible causes:
  1. Junction path case mismatch (must be lowercase on both sides).
  2. `mount-rootonly` still enabled on the SVM.
  3. Export policy doesn't include the RHEL host's IP.
- **17+ failed mount units at boot** — fstab using `defaults`. Pin
  `vers=3,tcp,mountproto=tcp` in every NetApp fstab line (§2.3) and
  `sudo systemctl reset-failed && sudo mount -a`.
- **Postgres container starts as root and fails on `chown`/`chmod` of
  the data dir** (`Operation not permitted`) — this is the correct
  behavior with rootless + NFS, but the container's entrypoint expects
  root-on-NFS (which we don't have). The Quadlet sets `User=999:999`
  to skip the entrypoint's root branch. The data dir on NetApp must
  be pre-chowned to the host UID that maps to container 999 —
  `<subuid_base> + 998` — see §2.4.
- **`chmod: changing permissions of '/var/lib/postgresql/data':
  Operation not permitted` even after `chmod 0777` on host** — the
  rootless container's mapped UID isn't the dir owner, so it can't
  modify permissions. `chmod 0777` lets *anyone* write into the dir
  but doesn't grant ownership. Fix is to `chown` the dir on host to
  `<subuid_base> + 998` (see §2.4), not chmod-loosen.
- **Quadlet generates network unit but skips a `.container`** —
  invalid directive somewhere. Common: `MemoryMax=` belongs in
  `[Service]`, not `[Container]`. Run
  `/usr/libexec/podman/quadlet -dryrun -user 2>&1 | grep -B1 error`
  to see exactly which directive Quadlet rejected.
- **Healthcheck reports unhealthy with `/bin/sh: 1: Syntax error: "("
  unexpected`** — Quadlet's `HealthCmd=` directive passes the value
  through `/bin/sh -c`, which is Dash on Debian images and parses `(`
  as subshell-start. Avoid parens, quotes, and pipes in `HealthCmd=`.
- **App can't resolve `myapp-postgres` or `myapp`** — aardvark-dns
  registers **pods**, not the containers inside them, so by default
  only `myapp-pod` and `myapp-db-pod` resolve. Both `.pod` Quadlets in
  this folder carry `NetworkAlias=` for the expected container names,
  which adds the records to aardvark. If resolution fails:
  1. Confirm the aliases are in the Quadlet:
     `grep NetworkAlias= ~/.config/containers/systemd/myapp-*.pod`.
  2. Confirm aardvark picked them up — restart the pods to
     re-register: `systemctl --user restart myapp-pod-pod myapp-db-pod-pod`.
  3. Pod network attachment can also be wrong:
     `podman pod inspect myapp-pod | grep -A5 Networks` should show
     both `edge-net` and `myapp-data-net`. The DB pod should show only
     `myapp-data-net`.
- **`next build` fails with `DATABASE_URL` (or similar) is not
  defined** — Next.js's "Collecting page data" phase imports every
  API route. If any module reads `process.env.X` at load time, X
  must be set during build. The Containerfile sets placeholder
  values for the build stage only; they don't enter the runtime
  image. If you're seeing this anyway, the build-stage env block was
  edited out — restore from git.
- **`bun start` exits immediately with `script not found "start"`** —
  the project's `package.json` doesn't define a `start` script. Either
  add one (`"start": "next start"`) or change `CMD` in the Containerfile
  to call the entrypoint directly: `["bun", "run", "next", "start"]`
  for Next.js apps.
- **Caddy returns 502** — usually the app pod is still starting.
  Check with `podman exec caddy wget -qO- http://myapp:3000/`. If
  that fails too, it's a network-attachment issue, not an app issue.
- **Migrations succeed, seed fails** — `prisma migrate deploy` is
  idempotent; the seed is not. If the DB already has seed data, skip
  it.
- **NFS mount drops after a network blip** — `hard,intr` in fstab
  makes it block-and-resume rather than fail. If processes hang after
  a long outage, force-unmount and remount:
  ```bash
  sudo umount -lf /netapp/myapp_data/postgres
  sudo mount -a
  ```
  The container's `Restart=on-failure` brings it back.
- **`bun install` very slow inside WSL** — repo lives on the Windows
  filesystem (`/mnt/c/...`); cross-FS I/O is the bottleneck. Clone to
  WSL's native filesystem (`~/projects/myapp`). Bun masks this less
  than npm but doesn't eliminate it.
- **`scp` from WSL prompts for password every time** — no SSH key
  forwarded into WSL. Generate one with `ssh-keygen` and copy with
  `ssh-copy-id user@<server-ip>`.
