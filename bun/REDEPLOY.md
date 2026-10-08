# Redeploy a New Version of myapp

Quick-reference for shipping code changes once the app is already running.
For first-time setup, see [`SETUP_CHECKLIST.md`](SETUP_CHECKLIST.md) and
[`README.md`](README.md).

Three locations referenced below:
- **WSL** — your Linux build host on the Windows workstation
- **Server** — the RHEL host (e.g. `user@10.x.x.x`), via SSH or Cockpit terminal
- **NetApp** — ONTAP CLI (only relevant if storage tweaks are part of the change)

> **Why WSL + bun?** The project was developed with bun on Windows/WSL,
> but the server runs Linux containers built with Podman. WSL gives you a
> real Linux build host so `podman build`, `podman save`, and `scp` work
> the same way they would on a Linux laptop. The container itself uses
> the bun runtime end-to-end — `bun install` at build, `bun start` at
> runtime.

## 1. Build the new image in WSL

The server can't pull from public registries during build, so the image
has to be built off-server and shipped as a tarball.

```bash
# Inside WSL, in the project root (the same directory that holds package.json)
cd /mnt/c/Users/<you>/path/to/myapp
# or if you've cloned into WSL's native filesystem (recommended — faster I/O):
cd ~/projects/myapp

podman build -t localhost/myapp:1.0 -t localhost/myapp:latest .
```

Bump `:1.0` to `:1.1`, `:2.0`, etc. when you want a versioned trail.
Keep `:latest` aliased to the newest build — the Quadlet's `Image=`
line references `:latest`.

1–3 min on first build (bun's install is much faster than npm), ~30–90s
for incremental builds with the layer cache warm.

### WSL-specific gotchas

- **Cloning the repo inside WSL's native filesystem (`~/projects/...`) is
  faster than building from `/mnt/c/...`.** Cross-filesystem I/O between
  WSL2 and the Windows host adds ~2–3x build time on `bun install`. Less
  dramatic than the npm penalty but still noticeable. If you can only
  edit on the Windows side, use a git remote or VS Code's "Open in WSL"
  workflow to keep the working tree on the Linux side.
- **Podman in WSL needs `podman machine init` only on Windows hosts that
  don't have WSL2 yet — on a working WSL2 install, Podman runs natively
  in the distro.** Install with `sudo apt install podman` (or your
  distro's equivalent).
- **First build pulls ~200–300 MB of bun base layers.** Subsequent builds
  reuse the cache.

### If `bun install --frozen-lockfile` fails inside the container

Almost always one of two things:

1. **bun major-version skew between dev and the base image.** Container
   uses `oven/bun:1-debian`, which is the latest bun 1.x. If dev was on
   bun 0.x, regenerate the lockfile in WSL:
   ```bash
   bun --version          # should report 1.x
   rm -rf node_modules bun.lock bun.lockb
   bun install            # regenerates bun.lock
   git status             # commit the regenerated lockfile
   ```
2. **Lockfile last touched outside WSL** (e.g. someone ran
   `bun install` from Git Bash on Windows). Same fix as above —
   regenerate in WSL so the resulting lockfile matches what the
   container will see.

## 2. Save and ship

```bash
# Inside WSL
rm -f ~/myapp-image.tar
podman save -o ~/myapp-image.tar localhost/myapp:1.0
scp ~/myapp-image.tar user@<server-ip>:~/
```

`rm -f` first — `podman save` errors with
`docker-archive doesn't support modifying existing images` if the
target file already exists.

~500 MB–1 GB transfer for a bun-based Next.js app. Don't gzip — image
layers are already deduped.

If you want a versioned trail of build tarballs (handy for rollback),
write each save to a dated filename instead:

```bash
podman save -o ~/myapp-image-$(date +%F-%H%M).tar localhost/myapp:1.0
scp ~/myapp-image-*.tar user@<server-ip>:~/
```

## 3. Load on the server

```bash
# On the server
podman load -i ~/myapp-image.tar
podman tag localhost/myapp:1.0 localhost/myapp:latest
podman images localhost/myapp   # both tags should show the new image ID
rm ~/myapp-image.tar            # optional cleanup
```

## 4. Restart the app container

```bash
systemctl --user restart myapp
podman ps --filter name=myapp --format 'table {{.Names}}\t{{.Status}}'
```

The restart doesn't return until the new container passes its
healthcheck (`Notify=healthy` in the Quadlet), usually within ~90s, so
`podman ps` should already show `(healthy)`. If the restart instead
fails with a timeout, the new build never became healthy — check
`journalctl --user -u myapp -n 50` and roll back (see below). The DB
and pods keep running — only the app container picks up the new image.

If `restart myapp` returns "dependency job failed" because the pod was
stranded:

```bash
systemctl --user reset-failed
systemctl --user start myapp-pod-pod
sleep 3
systemctl --user start myapp
```

## 5. Verify

```bash
# From WSL or your workstation
curl -I http://<server-ip>:<site-port>/
# Expect: HTTP/1.1 200 OK, Content-Type: text/html
```

Then load `http://<server-ip>:<site-port>/` in a browser and exercise whatever flow
you changed.

---

## Conditional steps — only if your changes include them

### A. Schema (Prisma) changes

```bash
# On the server, after step 4
podman exec myapp bunx prisma migrate deploy
```

Idempotent — safe to run on every redeploy. If the migration alters
existing data, take an ONTAP snapshot of `vol_myapp_postgres` first.

### B. New environment variables

```bash
# On the server
$EDITOR ~/deploy/myapp/.env

# After saving:
systemctl --user restart myapp
```

No image rebuild required for env-only changes — `.env` is loaded by
the Quadlet at container start.

### C. Quadlet (`.container` / `.pod` / `.network`) changes

Quadlet files are independent of the app image. After updating them on
the server, copy any changed Quadlets to `~/.config/containers/systemd/`:

```bash
# On the server, after the new tarball is loaded
cp ~/deploy/myapp/quadlets/<changed-file> ~/.config/containers/systemd/

systemctl --user daemon-reload
# Then restart whichever services the changed Quadlets generate:
systemctl --user restart <relevant-services>
```

If you're not sure what changed, copy all five and reload — it's
idempotent:

```bash
cp ~/deploy/myapp/quadlets/*.{network,pod,container} \
   ~/.config/containers/systemd/
systemctl --user daemon-reload
```

Don't `systemctl --user enable` Quadlet-generated units — they're
transient (regenerated on each `daemon-reload`) and `[Install]` is
honored automatically.

### D. Caddyfile changes

```bash
# On the server
$EDITOR ~/deploy/caddy/Caddyfile

podman exec caddy caddy validate --config /etc/caddy/Caddyfile
podman exec caddy caddy reload --config /etc/caddy/Caddyfile
```

`validate` first — `reload` will refuse a broken config and the running
Caddy keeps serving the previous one.

If you edit with `vim`/`nano` and the change doesn't take effect, you
may have hit the bind-mount-of-single-file inode issue. Fix by:
`systemctl --user restart caddy`.

### E. New NetApp volume / mount

Rare during a normal redeploy — only if you're adding a new database
or storage location. See [`README.md`](README.md) §1–§2 for the full
ONTAP + fstab + chown sequence.

### F. Add-on (`mongo-addon/`, etc.) changes

Addons follow the same patterns as A–E, just in the addon's namespace:

- **Adding an addon to a running deployment** is a first-time integration,
  not a redeploy — follow the addon's own README (which slots into the
  base bundle's `README.md` §1–§7).
- **Updating an addon Quadlet** (e.g. bumping the Mongo image tag,
  changing `MemoryMax`): same flow as §C above. Copy the changed
  `<addon>/*.container` into `~/.config/containers/systemd/`,
  `daemon-reload`, and restart that addon's service:
  ```bash
  cp <repo>/mongo-addon/myapp-mongo.container ~/.config/containers/systemd/
  systemctl --user daemon-reload
  systemctl --user restart myapp-mongo myapp
  ```
- **Updating an addon's env** (root credentials, URI): same flow as §B.
  Edit `~/deploy/myapp/<addon>.env`, restart the addon and the app so
  both pick up the new value. Note that rotating an addon's root
  password via env-file change only seeds on first run — to actually
  rotate, connect as root and run the in-DB password-change command.
- **Removing an addon**: stop and remove its Quadlet, then strip the
  matching `NetworkAlias=` line from `myapp-db-pod.pod`, restart the
  db-pod, and clean up the `<addon>.env` reference in `.env`. The
  NetApp volume can be kept (for a future re-enable) or
  decommissioned via ONTAP.

Don't forget the addon when sizing backups — each addon adds a NetApp
volume that needs its own ONTAP snapshot policy and `pg_dump`-style
periodic dump if relevant (e.g. `mongodump` for the mongo addon).

---

## Rollback

If the new image breaks something, revert by re-tagging an older saved
image:

```bash
# On the server
podman images localhost/myapp
# Find a previous tag, e.g. localhost/myapp:1.0 (the prior version)

podman tag localhost/myapp:<previous-version> localhost/myapp:latest
systemctl --user restart myapp
```

If older versioned tags weren't kept, `podman load` from a saved
tarball if you have one. Otherwise the only recovery is to re-build
from a known-good git commit (inside WSL).

For database rollback (if the breakage was a bad migration), restore
from an ONTAP snapshot:

```ontap
volume snapshot restore -vserver <SVM> \
  -volume vol_myapp_postgres -snapshot <snapshot-name>
```

This unmounts the volume on the client; remount with
`sudo umount /netapp/myapp_data/postgres && sudo mount -a`, then
restart postgres.

---

## Common failure modes during redeploy

| Symptom | Cause | Fix |
|---|---|---|
| `systemctl --user --failed` lists units named after a long hex ID (e.g. `3f9c…e1.service` / `.timer`) | Podman runs each healthcheck from a transient systemd timer named after the container ID. Quadlet always runs containers with `--rm`, so every restart or redeploy creates a new container ID, and the old container's healthcheck unit can be left behind as failed | Harmless — the running container has its own, new unit. Clear them with `systemctl --user reset-failed`. Check the real units with `systemctl --user status myapp` |
| `Error: image localhost/myapp:latest not found` after restart | `podman tag :1.0 :latest` step skipped | Run the tag command from step 3 |
| `restart myapp` errors with "dependency job failed" | Pod stranded in dead state — pod's exit-policy defaults to `stop`, which kills it when the container restarts | Recover: `reset-failed`, then start `myapp-pod-pod`, then `myapp`. Permanent: ensure `myapp-pod.pod` carries `PodmanArgs=--exit-policy=continue` |
| `quadlet-generator: unsupported key 'ExitPolicy' in group 'Pod'` | Older Quadlet versions don't accept the dedicated `ExitPolicy=` directive | Use `PodmanArgs=--exit-policy=continue` instead — same effect, recognized everywhere |
| New image starts but app hangs at / | Stale build of an older code version still tagged `:latest` | Verify image IDs match: `podman images localhost/myapp` |
| 502 from Caddy after restart | App took longer than usual to bind 3000 | Wait 60–90s; if persistent, `podman logs --tail 100 myapp` |
| App logs show env-var errors | `.env` line still has surrounding `""` quotes or unencoded `+`/`/` in DB password | Strip quotes; URL-encode `+` → `%2B`, `/` → `%2F` in DB URLs only |
| `bun install` ran inside the container and failed at runtime | Network restriction — this should only happen at build time in WSL | Don't run `podman exec myapp bun install`; rebuild and ship instead |
| `podman save` errors with "docker-archive doesn't support modifying existing images" | Previous tarball still at the output path | `rm -f ~/myapp-image.tar` then re-run, or use a dated filename |
| `bun install` very slow inside WSL | Repo lives on the Windows filesystem (`/mnt/c/...`) — cross-FS I/O is the bottleneck | Clone to WSL's native FS (`~/projects/myapp`) |
| `scp` from WSL prompts for password every time | No SSH key forwarded into WSL | Generate a WSL key with `ssh-keygen` and copy with `ssh-copy-id user@<server-ip>` |
| Container exits immediately with `script not found "start"` | Project's `package.json` has no `start` script | Add `"start": "next start"` to scripts, OR change Containerfile `CMD` to `["bun", "run", "next", "start"]` |
| `bunx prisma migrate deploy` errors with `bunx: command not found` | The base image inside Podman doesn't have bunx on PATH (very rare with `oven/bun:1-debian`, but possible with custom base) | Use `bun x prisma migrate deploy` instead — same thing, dash-separated |
