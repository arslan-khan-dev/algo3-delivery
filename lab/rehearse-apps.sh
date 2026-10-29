#!/usr/bin/env bash
# rehearse-apps.sh — the deployer with apps that are NOT static sites, in the
# lab, after rehearse-phase3.sh (the edge serves 80/443):
#
#   demo-api     KIND=web       Node API (templates/dockerfiles/node-api.Dockerfile)
#                               migration as RELEASE_COMMAND, a persistent volume;
#                               a second product on ITS OWN domains: primary,
#                               alias and www redirect, site generated (no template)
#   demo-py      KIND=internal  Python/FastAPI on its OWN network, no public site
#   demo-worker  KIND=worker    Node worker, OVERLAP=false (never two at once)
#
# Images are built from examples/apps/ with the starter Dockerfiles.
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

rel() { printf 'apps-release-%s' "$1" | sha1sum | cut -c1-40; }
R1="$(rel 1)"; R2="$(rel 2)"; R3="$(rel 3)"
REG=localhost:5000
D=/usr/local/libexec/algo3-deploy
T=/lab/algo3-delivery/templates/dockerfiles
A=/lab/algo3-delivery/examples/apps

step1() {
    title "Step 1 · build each app, twice, with the starter Dockerfiles"
    local sha
    for sha in "$R1" "$R2" "$R3"; do
        as_root "docker build -q -f $T/node-api.Dockerfile --build-arg RELEASE_SHA=$sha -t $REG/demo-api:$sha $A/node-api >/dev/null && docker push -q $REG/demo-api:$sha >/dev/null"
        as_root "docker build -q -f $T/python.Dockerfile --build-arg RELEASE_SHA=$sha -t $REG/demo-py:$sha $A/python-api >/dev/null && docker push -q $REG/demo-py:$sha >/dev/null"
        as_root "docker build -q -f $T/worker.Dockerfile --build-arg RELEASE_SHA=$sha -t $REG/demo-worker:$sha $A/worker >/dev/null && docker push -q $REG/demo-worker:$sha >/dev/null"
    done
    check "nine images in the lab registry" "[ \"\$(curl -fsS http://localhost:5000/v2/demo-api/tags/list | grep -o $R3)\" = $R3 ]"
}

step2() {
    title "Step 2 · register the three apps (as each app's registry files would)"
    as_root 'echo "127.0.0.1 api.lab.test api.other.test www.api.lab.test" >> /etc/hosts; docker network inspect demo-private >/dev/null 2>&1 || docker network create demo-private >/dev/null
        mkdir -p /etc/algo3/apps/demo-api /etc/algo3/apps/demo-py /etc/algo3/apps/demo-worker
        cat > /etc/algo3/apps/demo-api/staging.conf <<EOF
KIND=web
IMAGE=localhost:5000/demo-api
HOSTNAME=api.lab.test
ALIASES=api.other.test
REDIRECTS=www.api.lab.test
CONTAINER_PORT=3000
HEALTH_PATH=/healthz
RELEASE_PATH=/healthz
RELEASE_KEY=version
RELEASE_COMMAND=node dist/migrate.js
VOLUMES=demo-api-data:/data
MEM_LIMIT=128m
EOF
        cat > /etc/algo3/apps/demo-py/staging.conf <<EOF
KIND=internal
IMAGE=localhost:5000/demo-py
CONTAINER_PORT=8000
HEALTH_PATH=/healthz
RELEASE_PATH=/healthz
RELEASE_KEY=version
NETWORKS=demo-private
MEM_LIMIT=256m
EOF
        cat > /etc/algo3/apps/demo-worker/staging.conf <<EOF
KIND=worker
IMAGE=localhost:5000/demo-worker
OVERLAP=false
MEM_LIMIT=128m
EOF'
    check "registered" 'test -f /etc/algo3/apps/demo-worker/staging.conf'
}

step3() {
    title "Step 3 · Node API (web): migration, volume, zero-downtime switch"
    run "sudo $D deploy demo-api staging $R1 | tail -4"
    xprobe_start api.lab.test lab-x-api
    as_root "$D deploy demo-api staging $R2 > /tmp/api-r2.log 2>&1"
    read -r t b l <<<"$(xprobe_stop lab-x-api)"
    note "second deploy, seen from outside: $t requests, $b failed, longest ${l}s"
    check "zero failed requests across the switch" "test $b -eq 0"
    check "the migration ran BEFORE the new release started" 'awk "/Running the release command/{m=NR} /Starting demo-api-staging-/{s=NR} END{exit !(m && s && m < s)}" /tmp/api-r2.log'
    check "public answer comes from R2 (release marker)" "curl -fsS https://api.lab.test/healthz | grep -q '\"version\":\"$R2\"'"
    check "the migration's result is visible to the app (volume)" "curl -fsS https://api.lab.test/healthz | grep -q '\"schema\":2'"
    check "the site was generated from the settings (no template)" 'test ! -e /etc/algo3/apps/demo-api/staging.caddy.tmpl && grep -q "^api.lab.test, api.other.test {" /etc/algo3/caddy/sites/demo-api-staging.caddy'
    check "the alias serves the same release" "curl -fsS https://api.other.test/healthz | grep -q '\"version\":\"$R2\"'"
    check "www redirects permanently to the primary domain" 'curl -sI https://www.api.lab.test/x | grep -qi "^location: https://api.lab.test/x"'
    check "the deploy checked the alias and the redirect" 'grep -q "api.other.test (alias) answers" /tmp/api-r2.log && grep -q "www.api.lab.test redirects to https://api.lab.test/" /tmp/api-r2.log'
    check "nexwe.app is untouched by the other product" "curl -fsS -o /dev/null https://nexwe.app/"
    check "volume mounted on the release" "docker inspect -f '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' demo-api-staging-${R2:0:12} | grep -q 'demo-api-data:/data'"
    as_root "sed -i 's#^RELEASE_COMMAND=.*#RELEASE_COMMAND=node dist/no-such-migration.js#' /etc/algo3/apps/demo-api/staging.conf"
    check "a failing migration refuses the deploy" "! $D deploy demo-api staging $R3 >/tmp/api-r3.log 2>&1 && grep -q 'Release command .*nothing was switched' /tmp/api-r3.log"
    check "and R3 was never started" "! docker inspect demo-api-staging-${R3:0:12} >/dev/null 2>&1"
    check "R2 still serves" "curl -fsS https://api.lab.test/healthz | grep -q '\"version\":\"$R2\"'"
    as_root "sed -i 's#^RELEASE_COMMAND=.*#RELEASE_COMMAND=node dist/migrate.js#' /etc/algo3/apps/demo-api/staging.conf"
    xprobe_start api.lab.test lab-x-api
    run "sudo $D rollback demo-api staging | tee /tmp/api-rb.log | tail -2"
    read -r t b l <<<"$(xprobe_stop lab-x-api)"
    note "rollback: $t requests, $b failed"
    check "rollback to R1 with zero failed requests" "test $b -eq 0 && curl -fsS https://api.lab.test/healthz | grep -q '\"version\":\"$R1\"'"
    check "rollback did not re-run the migration" "grep -q 'Rolled back\|rollback' /tmp/api-rb.log && ! grep -q 'Running the release command' /tmp/api-rb.log"
}

step4() {
    title "Step 4 · Python API (internal) on its own network"
    run "sudo $D deploy demo-py staging $R1 | tail -2"
    run "sudo $D deploy demo-py staging $R2 | tail -2"
    check "no public site was created" 'test ! -e /etc/algo3/caddy/sites/demo-py-staging.caddy'
    check "consumers on demo-private reach it by its stable name, on R2" \
        "docker run --rm --network demo-private busybox wget -q -O - http://demo-py-staging:8000/healthz | grep -q '\"version\":\"$R2\"'"
    check "it is NOT on the edge's network (isolated)" "! docker inspect -f '{{json .NetworkSettings.Networks}}' demo-py-staging-${R2:0:12} | grep -q '\"studio\"'"
    check "previous release stopped, kept" "[ \"\$(docker inspect -f {{.State.Status}} demo-py-staging-${R1:0:12})\" = exited ]"
}

step5() {
    title "Step 5 · worker with OVERLAP=false: never two copies"
    run "sudo $D deploy demo-worker staging $R1 | tail -2"
    as_root 'rm -f /tmp/overlap.max; ( max=0; while [ ! -f /tmp/overlap.stop ]; do n=$(docker ps -q --filter label=algo3.app=demo-worker | wc -l); [ $n -gt $max ] && max=$n; echo $max > /tmp/overlap.max; sleep 0.1; done ) >/dev/null 2>&1 &
             sleep 0.5'
    run "sudo $D deploy demo-worker staging $R2 | tail -3"
    as_root 'touch /tmp/overlap.stop; sleep 0.4; rm -f /tmp/overlap.stop'
    check "at most one worker ran at any moment" '[ "$(cat /tmp/overlap.max)" -le 1 ]'
    check "R2 runs and is healthy" "[ \"\$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' demo-worker-staging-${R2:0:12})\" = 'running healthy' ]"
    check "R1 stopped, kept for rollback" "[ \"\$(docker inspect -f {{.State.Status}} demo-worker-staging-${R1:0:12})\" = exited ]"
    check "the worker has no network alias (nothing routes to it)" "! docker inspect -f '{{json .NetworkSettings.Networks}}' demo-worker-staging-${R2:0:12} | grep -q demo-worker-staging\\\""
    run "sudo $D status demo-worker staging"
}

step6() {
    title "Step 6 · one domain, one owner; certificates watched for every product"
    as_root 'mkdir -p /etc/algo3/apps/demo-clash && printf "IMAGE=localhost:5000/demo-api
HOSTNAME=demo-clash.lab.test
ALIASES=nexwe.app
CONTAINER_PORT=3000
HEALTH_PATH=/healthz
" > /etc/algo3/apps/demo-clash/staging.conf'
    check "an app claiming nexwe.app is refused, naming the owner" "! $D deploy demo-clash staging $R1 >/tmp/clash.log 2>&1 && grep -q 'nexwe.app is already claimed by nexwe-website/production' /tmp/clash.log"
    check "and nothing was started for it" "! docker ps -a --format '{{.Names}}' | grep -q demo-clash"
    check "nexwe.app still serves" "curl -fsS -o /dev/null https://nexwe.app/"
    as_root 'rm -rf /etc/algo3/apps/demo-clash'
    run "sudo /usr/local/sbin/algo3-cert-watch"
    check "certificate checks cover both products' domains" 'for d in nexwe.app www.nexwe.app staging.nexwe.app api.lab.test api.other.test www.api.lab.test; do grep -q "source: https://$d:443" /opt/algo3/ops/netdata/go.d/x509check.conf || exit 1; done'
    run "sudo $D status demo-api staging"
}

[[ $# -gt 0 ]] || set -- 1 2 3 4 5 6
for s in "$@"; do "step$s"; done
finish
