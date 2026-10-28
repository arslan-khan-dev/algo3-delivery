#!/usr/bin/env bash
# up.sh — (re)create the lab from scratch on this PC (Git Bash) and seed it to
# today's server state. Safe to re-run: it always starts clean.
#
#   bash lab/up.sh                 build + start + seed
#   docker exec -it algo3-lab bash a shell "on the server"
#   docker rm -f algo3-lab         throw it away
set -euo pipefail
export MSYS_NO_PATHCONV=1

lab="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$lab/.." && pwd)"
products="$(cd "$repo/.." && pwd)"
win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

echo "== source of the two nexwe-website releases (from your local repo's history)"
rm -rf "$lab/.work"; mkdir -p "$lab/.work/src"
for sha in 94882418458b9be931479490abf0c625a56050ef f568992edc66e7a85bda69b44138a0f51b94a495; do
    mkdir -p "$lab/.work/src/nexwe-website-$sha"
    git -C "$(win "$products/nexwe-website")" archive "$sha" | tar -x -C "$lab/.work/src/nexwe-website-$sha"
    echo "  $sha"
done

echo "== lab image"
docker build -q -t algo3-lab:latest "$(win "$lab")" >/dev/null

echo "== fresh lab container"
docker rm -f algo3-lab >/dev/null 2>&1 || true
docker volume rm algo3-lab-docker algo3-lab-containerd >/dev/null 2>&1 || true
docker run -d --name algo3-lab --hostname algo3-vps \
    --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /run --tmpfs /run/lock \
    -v algo3-lab-docker:/var/lib/docker \
    -v algo3-lab-containerd:/var/lib/containerd \
    -v "$(win "$repo"):/lab/algo3-delivery:ro" \
    -v "$(win "$products/studio-platform"):/lab/studio-platform:ro" \
    -v "$(win "$lab/.work/src"):/lab/src:ro" \
    algo3-lab:latest >/dev/null

echo "== waiting for systemd"
for _ in $(seq 1 60); do
    state="$(docker exec algo3-lab systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == running || "$state" == degraded ]] && break
    sleep 1
done
echo "  systemd: $state"
[[ "$state" == degraded ]] && docker exec algo3-lab systemctl --failed --no-legend | sed 's/^/  failed unit: /'

docker exec algo3-lab bash /lab/algo3-delivery/lab/seed-today.sh
