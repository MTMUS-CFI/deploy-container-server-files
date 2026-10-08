# deploy-container-server-files

Starter deploy bundles for putting a **Next.js + Prisma** app on the shared
RHEL 10 server (rootless Podman 5 + Quadlets, NetApp NFS storage, Caddy edge
proxy). The image is built in **WSL** on a Windows workstation, saved to a
tarball, copied to the server, and loaded there. The server doesn't build
images itself because it can't reach public package mirrors.

Each top-level folder is one **flavor** of the same bundle. Pick the one that
matches your project, copy it into the Next.js project, rename the `myapp`
placeholder, and follow that folder's docs.

## Pick a flavor

| Folder | Package manager / runtime | Databases | Use when |
|---|---|---|---|
| [`npm/`](npm/) | Node 24 + npm | Postgres | Project has a canonical `package-lock.json` and no bun lockfile |
| [`bun/`](bun/) | Bun 1.x (build and runtime) | Postgres | Project has `bun.lock` / `bun.lockb` or `"packageManager": "bun@..."` |
| [`bun-with-mongo/`](bun-with-mongo/) | Bun 1.x (build and runtime) | Postgres + MongoDB 7 | Bun project that also needs GridFS file storage or Mongo collections |

- **npm + Mongo:** there is no `npm-with-mongo` folder. Use `npm/` and apply
  its [`mongo-addon/`](npm/mongo-addon/).
- **Both lockfiles in the project:** choose one package manager and delete the
  other lockfile before you start. The npm and bun images produce different
  `node_modules` layouts and can't use each other's lockfiles.
- **Mongo only "in case":** don't add it. Each database adds a NetApp volume,
  a container, a backup target and more to secure.

## What's in each flavor

All three folders have the same layout:

| File | Purpose |
|---|---|
| `Containerfile` | Multi-stage image build: install deps, `prisma generate`, build Next.js, start on port 3000 |
| `app.env.example` | App config and secrets (`DATABASE_URL`, Auth.js vars; `MONGODB_URI` in the Mongo flavor) |
| `postgres.env.example` | Postgres credentials |
| `mongo.env.example` | MongoDB root credentials (`bun-with-mongo/` only) |
| `quadlets/` | Podman Quadlet units: data network, app pod, DB pod, Postgres (and Mongo) container, app container |
| `caddy-vhost-snippet.txt` | Block to add to the shared Caddyfile |
| `rename.sh` | Replaces the `myapp` placeholder with your slug; prints the storage names to use |
| `set-port.sh` | Fills in the site port (what users type) across the docs, Caddy snippet and `app.env.example` |
| `README.md` | Full first-time walkthrough, with the reasons behind each step |
| `SETUP_CHECKLIST.md` | Checklist version of the first-time setup |
| `REDEPLOY.md` | Steps for shipping a new build once the app is running |
| `mongo-addon/` | Optional Mongo bolt-on (`npm/` and `bun/` only) |

## Topology

Every flavor deploys the same shape:

```
edge-net (shared) ◀── Caddy
  │
  └─ <app>-pod ── <app> (Next.js :3000)
        │
        └── <app>-data-net (internal, no internet egress)
              │
              └─ <app>-db-pod ── <app>-postgres (:5432) ── NetApp vol_<app>_postgres
                                 <app>-mongo    (:27017) ── NetApp vol_<app>_mongo   (Mongo only)
```

## How to use a flavor

1. **Copy the flavor folder into your Next.js project.** The Containerfile is
   built from the project root (`podman build .`), where `package.json`,
   the lockfile and `prisma/` live.
2. **Rename `myapp` to your app's slug** with `./rename.sh <slug>` in the
   flavor folder. This step is required. Every pod, container, NetApp
   volume, env path and systemd unit uses `myapp` as a placeholder. The
   script must finish with `OK`, and it prints the NetApp volume, junction
   and mount path names for each database. Use those names exactly when you
   set up storage.
3. **Pick a site port and fill it in.** Before DNS exists, users reach the
   app at `http://<server-ip>:<port>`, so each app needs its own free port
   on the server. Check it's free (flavor README, "Ports"), then run
   `./set-port.sh <port>` in the flavor folder. It writes the port into the
   docs, the Caddy snippet and `app.env.example` (including `NEXTAUTH_URL`).
4. **Follow the flavor's `SETUP_CHECKLIST.md`** for a first-time deploy, and
   use its `README.md` for the detailed commands. The setup runs in this order:
   WSL prep → NetApp volume → NFS mount and chown → env files → Quadlets →
   start services → migrations → site port + Caddy block → verify.
5. **Use `REDEPLOY.md`** for every later code change. The cycle is build in
   WSL → `podman save` → `scp` → `podman load` → restart the service.

## Prerequisites

- **Workstation:** WSL2 (Ubuntu) with `podman`, `git`, `ssh`, and `bun` if you
  picked a bun flavor. Clone the project into the WSL filesystem
  (`~/projects/...`), not `/mnt/c/...`.
- **Server:** the shared Caddy stack is running, `edge-net` exists, the
  operator's user has lingering enabled, and the unprivileged port floor has
  been lowered to 80. If this is the first app on a new server, set that up
  first.
- **Storage:** access to the ONTAP CLI to create the NetApp FlexVol(s).
