#!/usr/bin/env bash
# Fill in this app's site port — the port users type to reach it before it
# has a domain name, http://<server-ip>:PORT — everywhere in this bundle.
#
# Usage:   ./set-port.sh <port>          e.g.  ./set-port.sh 8081
#
# Every site-port reference in the docs, the Caddy snippet and
# app.env.example uses the same placeholder. This swaps it for the number,
# so the README / checklist commands are copy-paste ready and NEXTAUTH_URL
# in app.env.example already carries the port.
#
# Pick a free port first (README "Ports"). Run on the server and this also
# checks the port is free before changing anything.
set -euo pipefail

cd "$(dirname "$0")"

PH='<site-port>'
PORT=${1:-}

if [[ ! $PORT =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
  echo "usage: $0 <port>   — a number from 1024 to 65535, e.g. 8081" >&2
  exit 1
fi
case $PORT in
  3000|5432|27017)
    echo "$PORT is a port used inside the pods (app / Postgres / Mongo), not a site port. Pick another." >&2
    exit 1 ;;
esac

if ! grep -rqIF --exclude='*.sh' -- "$PH" .; then
  echo "No site-port placeholders left in $(pwd) — the port is already set." >&2
  echo "To change it, replace the old number by hand (grep -rn ':<old port>' .) or start from a fresh copy of the bundle." >&2
  exit 1
fi

# On the server, refuse a port that's already taken.
if [[ -f ~/deploy/caddy/Caddyfile ]]; then
  taken=""
  ss -ltnH "sport = :$PORT" | grep -q . && taken+=" something is listening on it;"
  grep -qE ":$PORT\b" ~/deploy/caddy/Caddyfile && taken+=" the Caddyfile already uses it;"
  podman ps -a --format '{{.Ports}}' | grep -q ":$PORT->" && taken+=" a container publishes it;"
  if [[ -n $taken ]]; then
    echo "Port $PORT is taken:$taken pick another. Nothing changed." >&2
    exit 1
  fi
  echo "Port $PORT is free on this server."
else
  echo "Not on the server (no ~/deploy/caddy/Caddyfile), so $PORT wasn't checked."
  echo "Make sure it's free there — README \"Ports\", step 1."
fi

mapfile -t files < <(grep -rlIF --exclude='*.sh' -- "$PH" . | sort)
sed -i "s/$PH/$PORT/g" "${files[@]}"

if grep -rnIF --exclude='*.sh' -- "$PH" .; then
  echo "Some placeholders weren't replaced — fix the hits above by hand." >&2
  exit 1
fi

echo "OK — site port set to $PORT in:"
printf '  %s\n' "${files[@]}"
echo
echo "Next: publish it from Caddy, open the firewall, and add the Caddyfile block — README \"Ports\", steps 3–5."
