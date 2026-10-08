#!/usr/bin/env bash
# Replace the `myapp` placeholder throughout this bundle with your app's slug.
#
# Usage:   ./rename.sh <slug>          e.g.  ./rename.sh daily-report
#
# Run it once, on the copy of the bundle you're going to deploy. It works on
# the folder this script lives in (wherever you run it from) and everything
# under it, including any *-addon/ subfolders.
#
# This logic lives in its own file, not in README.md, on purpose: the rename
# rewrites every .md file, so a copy of the script inside the README would
# rewrite its own patterns and break if re-run. This file is never touched by
# the rename.
#
# The slug ends up in three forms (see README "Three forms"):
#   daily-report-<thing>   Podman networks/pods/containers, image tags, Quadlet filenames
#   daily_report_<thing>   NetApp volumes + junctions, /netapp mount dirs, Postgres names
#   daily-report           hostname stub, Caddy upstream, ~/deploy/<slug>, Mongo DB name
set -euo pipefail

cd "$(dirname "$0")"

SLUG=${1:-}
if [[ ! $SLUG =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ || ${#SLUG} -gt 30 || $SLUG == myapp ]]; then
  echo "usage: $0 <slug>" >&2
  echo "  slug: lowercase letters, digits and single hyphens; starts with a letter;" >&2
  echo "  no trailing hyphen; max 30 chars; not 'myapp'. e.g. daily-report" >&2
  exit 1
fi
SLUG_UNDER=${SLUG//-/_}

if ! grep -rqI --exclude=rename.sh myapp .; then
  echo "No 'myapp' placeholders found in $(pwd) — already renamed? Nothing done." >&2
  exit 1
fi

# 1. Rename files whose names start with `myapp`.
find . -depth -name 'myapp*' -print | while IFS= read -r f; do
  mv "$f" "$(dirname "$f")/$(basename "$f" | sed "s/^myapp/$SLUG/")"
done

# 2. Replace content — underscored form FIRST, then hyphenated, then bare.
#    Order matters: `myapp_postgres` has no trailing hyphen, so only the
#    underscore rule converts it to the NetApp/Postgres form; the bare rule
#    runs last so it can't claim text the other two should.
find . -type f ! -name rename.sh \
     \( -name 'Containerfile' -o -name '*.md' -o -name '*.network' \
        -o -name '*.pod' -o -name '*.container' -o -name '*.example' \
        -o -name '*.txt' \) -print0 \
| xargs -0 sed -i "s/myapp_/${SLUG_UNDER}_/g; s/myapp-/${SLUG}-/g; s/\bmyapp\b/${SLUG}/g"

# 3. Verify nothing was missed.
if grep -rnI --exclude=rename.sh myapp .; then
  echo "RENAME INCOMPLETE — fix the hits above by hand before deploying." >&2
  exit 1
fi
echo "OK — no 'myapp' placeholders remain."

# 4. Print the storage names, derived from the Quadlets' Volume= lines — the
#    paths the containers will actually mount. Create the NetApp volumes,
#    fstab lines and chowns with exactly these names; a mismatch means the
#    DB containers fail to start.
echo
echo "Storage names for this app (use these exactly):"
printf '  %-36s %-30s %-26s %s\n' "Quadlet" "NetApp volume" "Junction" "Host mount (fstab, chown)"
find . -name '*.container' -print0 | sort -z | while IFS= read -r -d '' q; do
  { grep -E '^Volume=/netapp/' "$q" || true; } | while IFS= read -r line; do
    host=${line#Volume=}; host=${host%%:*}          # /netapp/<slug>_data/<db>
    db=${host##*/}
    name=$(basename "$q"); [[ $q == *-addon/* ]] && name="$name (addon)"
    printf '  %-36s %-30s %-26s %s\n' "$name" "vol_${SLUG_UNDER}_${db}" "/${SLUG_UNDER}_${db}" "$host"
  done
done
