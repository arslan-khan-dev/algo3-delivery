#!/usr/bin/env bash
# edge/install.sh — install or update the algo3 edge (never starts it).
#
#   sudo bash edge/install.sh
#
# Idempotent. It:
#   - installs compose.yml and Caddyfile into /opt/algo3/edge (backup on change,
#     the Caddyfile validated by Caddy itself first);
#   - creates /opt/algo3/edge/.env from the example ONCE (root, 0600);
#   - creates the shared `studio` and `studio-staging` networks if missing;
#   - copies the host Caddy's certificates + ACME account into the edge's data
#     volume ONCE (only while the volume holds no certificates), so the edge
#     already has every certificate when it takes over 80/443: no issuance
#     during the cutover;
#   - validates the compose file.
# It never runs `up`, never binds 80/443, never stops the host Caddy.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest=/opt/algo3/edge
host_caddy_data=/var/lib/caddy/.local/share/caddy
stamp="$(date +%Y%m%d-%H%M%S)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
command -v docker >/dev/null || die "docker is not installed"

image="$(sed -nE 's/^ *image: *(caddy:[^ ]+).*/\1/p' "$here/compose.yml" | head -1)"
[[ -n "$image" ]] || die "No caddy image in compose.yml"

put() {   # put <src> <dest> <mode>
    if [[ -f "$2" ]] && cmp -s "$1" "$2"; then say "unchanged  $2"; return 0; fi
    [[ -f "$2" ]] && { cp -p "$2" "$2.backup.$stamp"; say "backup     $2.backup.$stamp"; }
    install -o root -g root -m "$3" "$1" "$2.new.$stamp"
    mv -f "$2.new.$stamp" "$2"
    say "installed  $2"
}

echo "Directories"
install -d -o root -g root -m 0755 "$dest" /etc/algo3/caddy /etc/algo3/caddy/sites \
    /etc/algo3/caddy/platform /etc/algo3/caddy/check
say "ok"

echo "Caddyfile (validated by Caddy $image)"
docker run --rm -e ACME_EMAIL=validate@example.com -e EDGE_LAB_OPTIONS= \
    -v "$here/Caddyfile:/etc/caddy/Caddyfile:ro" -v /etc/algo3/caddy:/etc/algo3/caddy:ro \
    "$image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 ||
    die "Caddy rejects edge/Caddyfile; nothing installed"
put "$here/Caddyfile" "$dest/Caddyfile" 0644
put "$here/compose.yml" "$dest/compose.yml" 0644

echo "Settings"
if [[ -f "$dest/.env" ]]; then
    chmod 0600 "$dest/.env"; chown root:root "$dest/.env"
    say "kept       $dest/.env (never overwritten)"
else
    install -o root -g root -m 0600 "$here/.env.example" "$dest/.env"
    say "created    $dest/.env: set ACME_EMAIL before starting the edge"
fi

echo "Networks"
# studio: production's platform and every production app. studio-staging: the
# staging platform and the staging apps that use it. Separate because apps
# find the platform by NAME (postgres, seaweedfs, ai): on one network both
# platforms would answer. The edge joins both.
for net in studio studio-staging; do
    if docker network inspect "$net" >/dev/null 2>&1; then
        say "exists     $net"
    else
        docker network create "$net" >/dev/null
        say "created    $net"
    fi
done

echo "Certificates"
docker volume create algo3-edge-data >/dev/null
if docker run --rm -v algo3-edge-data:/data "$image" sh -c 'test -d /data/caddy/certificates'; then
    say "kept       the edge volume already holds certificates (never overwritten)"
elif [[ -d "$host_caddy_data/certificates" ]]; then
    docker run --rm -v algo3-edge-data:/data -v "$host_caddy_data:/src:ro" "$image" \
        sh -c 'mkdir -p /data/caddy && cp -a /src/. /data/caddy/'
    count="$(docker run --rm -v algo3-edge-data:/data "$image" sh -c 'find /data/caddy/certificates -name "*.crt" | wc -l')"
    say "copied     $count certificate(s) + ACME account from the host Caddy"
else
    say "none       no host Caddy data found; the edge will obtain certificates itself"
fi

echo "Compose"
docker compose -p algo3-edge -f "$dest/compose.yml" config --quiet || die "compose.yml does not validate"
say "validated  $dest/compose.yml"
grep -qE '^ACME_EMAIL=.+@.+' "$dest/.env" || say "NOTE: ACME_EMAIL is empty in $dest/.env"
echo
echo "Not started. See edge/CUTOVER.md for the next step."
