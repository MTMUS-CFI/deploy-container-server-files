# Mongo add-on for myapp

Optional add-on to the base Postgres-only `bun/` (or `npm/`) deploy
bundle. Use this when the app needs MongoDB alongside Postgres — most
commonly for **GridFS file storage** (PDFs, Office docs, images) or
schemaless document collections.

Two-DB topology after applying this addon:

```
edge-net ◀── Caddy ──▶ myapp-pod ── myapp (Next.js :3000)
                            │
                  myapp-data-net (internal, no egress)
                            │
                myapp-db-pod ── myapp-postgres (:5432) ── /netapp/myapp_data/postgres
                              └─ myapp-mongo    (:27017) ─ /netapp/myapp_data/mongo
```

Both databases live in the same `myapp-db-pod` and share its network
namespace (so each container needs a different port, which they
already do: 5432 vs 27017). Each gets its own NetApp FlexVol so
snapshot policy, growth, and recovery are scoped per-DB.

## Files

| File | Purpose |
|---|---|
| `myapp-mongo.container` | Quadlet — drops Mongo 7 into the existing `myapp-db-pod`. |
| `mongo.env.example` | Template for `MONGO_INITDB_ROOT_USERNAME` / `MONGO_INITDB_ROOT_PASSWORD`. |
| `README.md` | This file — the integration steps. |

The base bundle's `README.md` / `SETUP_CHECKLIST.md` / `REDEPLOY.md`
all still apply; the steps below are **in addition** to those.

## When NOT to use this

- If the app only needs document-shaped state, a Postgres `jsonb`
  column is usually simpler and lets you keep one DB.
- If the app needs object storage (large binaries, video), an S3-like
  service (MinIO) or NFS directly is often a better fit than GridFS.
- If you already have a Mongo cluster elsewhere on the network, just
  point `MONGODB_URI` at it and skip this addon entirely.

## What to add to the base setup

The base bundle covers steps 1–10 (NetApp Postgres volume, fstab,
chown, Quadlets, Caddy, etc.). This addon adds:

1. **A second NetApp FlexVol** for Mongo (`vol_myapp_mongo`, junction
   `/myapp_mongo`).
2. **A second fstab line** mounting it at `/netapp/myapp_data/mongo`.
3. **A second pre-chown** of that dir to the rootless-mapped UID.
4. **One Quadlet** (`myapp-mongo.container`) dropped into
   `~/.config/containers/systemd/`.
5. **One alias line** added to the existing `myapp-db-pod.pod`
   Quadlet so the app can resolve `myapp-mongo:27017` via container DNS.
6. **One env file** (`mongo.env`) plus a `MONGODB_URI` line in `.env`.
7. **One extra service** in the start order (`myapp-mongo` alongside
   `myapp-postgres`).

---

## 1. NetApp — provision the second FlexVol

Same flow as the Postgres volume in the base bundle's `README.md` §1,
just with the mongo-specific name and junction. From WSL:

```bash
ssh admin@<ontap-cluster-mgmt-ip>
```

```ontap
volume create \
  -vserver <SVM> \
  -volume vol_myapp_mongo \
  -aggregate <data-aggregate> \
  -size 50GB \
  -junction-path /myapp_mongo \
  -security-style unix \
  -state online \
  -space-guarantee none \
  -snapshot-policy default \
  -percent-snapshot-space 5 \
  -unix-permissions 755

volume efficiency on -vserver <SVM> -volume vol_myapp_mongo
volume efficiency modify -vserver <SVM> -volume vol_myapp_mongo -policy auto
volume modify -vserver <SVM> -volume vol_myapp_mongo -snapdir-access false

volume modify -vserver <SVM> -volume vol_myapp_mongo -policy <prod-policy>
```

> Mongo (GridFS) typically grows **faster** than Postgres on the same
> app — files outweigh schema rows quickly. Size the volume to your
> expected file footprint, not to the app-state DB's size.

---

## 2. RHEL host — fstab + mount + chown

Run on the server. Same patterns as base bundle §2, just adding a
second line / dir / chown for Mongo.

```bash
# Pre-flight: the new junction is advertised?
showmount -e <netapp-lif-ip>
# Should now show BOTH /myapp_postgres AND /myapp_mongo.

# Permanent mount via fstab — add ONE line under the postgres one
sudo mkdir -p /netapp/myapp_data/mongo
sudo tee -a /etc/fstab >/dev/null <<'EOF'
<netapp-lif-ip>:/myapp_mongo  /netapp/myapp_data/mongo  nfs  vers=3,tcp,mountproto=tcp,hard,intr,rsize=65536,wsize=65536,_netdev  0  0
EOF
sudo systemctl daemon-reload
sudo mount -a
df -h | grep myapp_data

# Pre-chown the new dir to the rootless-mapped UID
SUBUID_BASE=$(grep "^${USER}:" /etc/subuid | awk -F: '{print $2}')
MONGO_HOST_UID=$((SUBUID_BASE + 998))
sudo chown -R "$MONGO_HOST_UID:$MONGO_HOST_UID" /netapp/myapp_data/mongo
sudo chmod 0700 /netapp/myapp_data/mongo
```

Same warnings as Postgres: **never `chmod 0777`** — fix ownership with
`chown`, not by widening modes.

---

## 3. Pod Quadlet — add the Mongo alias

The base bundle's `myapp-db-pod.pod` declares only
`NetworkAlias=myapp-postgres`. Add a second alias line so the app's
`mongodb://...@myapp-mongo:27017/...` connection string resolves.

Edit `~/.config/containers/systemd/myapp-db-pod.pod` (or
`<repo>/quadlets/myapp-db-pod.pod` before copying it over):

```diff
 NetworkAlias=myapp-postgres
+NetworkAlias=myapp-mongo
```

aardvark-dns registers pods, not container names — without this alias,
only `myapp-db-pod` resolves and the connection string fails.

---

## 4. Drop the Mongo Quadlet + env file

On the server:

```bash
cp <repo>/mongo-addon/myapp-mongo.container ~/.config/containers/systemd/
cp <repo>/mongo-addon/mongo.env.example     ~/deploy/myapp/mongo.env
chmod 600 ~/deploy/myapp/mongo.env
$EDITOR ~/deploy/myapp/mongo.env       # set MONGO_INITDB_ROOT_USERNAME / PASSWORD
```

Generate a strong password:

```bash
openssl rand -base64 24
# or with no `+`/`/` to skip URL-encoding in MONGODB_URI:
openssl rand -hex 24
```

---

## 5. Add MONGODB_URI to the app .env

Edit `~/deploy/myapp/.env` and add:

```
MONGODB_URI=mongodb://<MONGO_INITDB_ROOT_USERNAME>:<URL_ENCODED_PASSWORD>@myapp-mongo:27017/<DB_NAME>?authSource=admin
```

Three things that bite:

1. **`?authSource=admin` is required** — root lives in the `admin`
   DB, not the DB you're connecting to. Without it: "Authentication
   failed" on first connect.
2. **URL-encode `+`/`/` in the password** segment of the URI only.
   `+` → `%2B`, `/` → `%2F`. The matching `MONGO_INITDB_ROOT_PASSWORD`
   in `mongo.env` stays raw.
3. **No surrounding quotes** around the value. Podman's `--env-file`
   treats `"..."` as literal characters.

---

## 6. Reload Quadlets + start order

```bash
systemctl --user daemon-reload

# Restart the db-pod so the new NetworkAlias registers in aardvark-dns.
systemctl --user restart myapp-db-pod-pod.service

# Start Mongo alongside Postgres.
systemctl --user start myapp-mongo.service

# Watch for "(healthy)" — typically 30s:
podman ps --format 'table {{.Names}}\t{{.Status}}'

# Restart the app so it picks up MONGODB_URI from .env.
systemctl --user restart myapp.service
```

For a fresh deploy (no app running yet), just fold Mongo into the
base bundle's start order:

```
data-net  →  db-pod  →  postgres + mongo (both)  →  app-pod  →  app
```

---

## 7. Verify

```bash
# All three DB containers up?
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Pod}}'
# Expect: myapp-postgres, myapp-mongo (both in myapp-db-pod), and myapp.

# Mongo data dir claimed by mongod?
sudo ls -la /netapp/myapp_data/mongo

# From inside the app container, connect string works?
podman exec myapp curl -fsS http://localhost:3000/api/health
# (or whatever health endpoint hits Mongo)

# Direct Mongo shell as the root user:
podman exec -it myapp-mongo mongosh \
  -u "$MONGO_INITDB_ROOT_USERNAME" \
  --authenticationDatabase admin
```

---

## Ops cheat sheet — Mongo additions

| Action | Command |
|---|---|
| Tail Mongo logs | `journalctl --user -u myapp-mongo -f` |
| Restart Mongo only | `systemctl --user restart myapp-mongo` |
| Mongo shell (root) | `podman exec -it myapp-mongo mongosh -u "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin` |
| Backup Mongo | `podman exec myapp-mongo mongodump --archive --gzip > mongo-$(date +%F).archive.gz` |
| Restore Mongo | `podman exec -i myapp-mongo mongorestore --archive --gzip --drop < mongo-<file>.archive.gz` |
| ONTAP snapshot before upgrade | `volume snapshot create -vserver <SVM> -volume vol_myapp_mongo -snapshot premigration_$(date +%F)` |
| Rotate root password | Connect as root → `use admin` → `db.changeUserPassword(...)`; update `MONGODB_URI` in `.env`; restart app |

---

## Troubleshooting (Mongo-specific additions to the base bundle)

- **`Authentication failed` on first connect** — three usual causes:
  1. `?authSource=admin` missing from `MONGODB_URI`. Root user lives
     in the admin DB.
  2. Password contains unencoded `+` or `/` in the URI. URL-encode in
     the URI; raw in `mongo.env`.
  3. The mongo container isn't seeing `MONGO_INITDB_ROOT_USERNAME/PASSWORD`
     in its env — verify `cat ~/deploy/myapp/mongo.env` and that the
     Quadlet's `EnvironmentFile=` line points at it.
- **Mongo healthcheck reports `Authentication failed`** — same root
  cause: the HealthCmd references `$MONGO_INITDB_ROOT_USERNAME` /
  `$MONGO_INITDB_ROOT_PASSWORD` from the container's env (loaded via
  `EnvironmentFile=`). If those env vars aren't set, the auth string is
  empty and the cmd fails. Confirm with `podman exec myapp-mongo env | grep MONGO_`.
- **App can't resolve `myapp-mongo`** — the db-pod Quadlet is missing
  `NetworkAlias=myapp-mongo`. See step 3. After adding the alias, the
  pod must be restarted so aardvark-dns re-registers:
  `systemctl --user restart myapp-db-pod-pod`.
- **`mongosh: bad option: --quiet` (or similar) inside HealthCmd** —
  Quadlet's `HealthCmd=` passes the value through `/bin/sh -c` (Dash on
  Debian), which can mis-parse if a flag value happens to contain `(`,
  `)`, `|`, or unquoted whitespace. Keep flags simple; never use shell
  features inside `HealthCmd=`.
- **Mongo container starts but writes nothing to /netapp** — host UID
  mapping wrong. The volume root must be owned by `<subuid_base> + 998`
  (same UID as the postgres dir, but a separate dir). Re-run the
  `chown` from step 2.
- **`initdb-style` error on first start (Mongo equivalent)** —
  permissions too loose. Mongo doesn't enforce 0700 the way Postgres
  does, but 0700 + correct ownership is the right starting point.
- **`MONGODB_URI` shows up inside the container with literal `""`
  quotes** — Podman's `--env-file` treats them as part of the value.
  Strip surrounding quotes from `.env` lines.
- **Snapshot restore brings Mongo back but app can't auth** — if you
  restored the data dir from before the current `mongo.env`'s root
  password rotation, the in-DB password is the old one. Either restore
  the matching `mongo.env` from the same point in time, OR connect as
  root with the old password and rotate forward.
- **First start hangs at "STORAGE [initandlisten] Initializing the WiredTiger storage engine"**
  — usually NFS performance / mount option issue. Confirm fstab has
  `vers=3,tcp,mountproto=tcp,hard,intr,rsize=65536,wsize=65536` — the
  default `vers=4.2,udp,defaults` hangs on this cluster.
