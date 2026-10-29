#!/usr/bin/env bash
# test-templates.sh — prove each starter Dockerfile really works: build its
# sample app (examples/apps/), start it, wait for Docker's HEALTHCHECK to say
# healthy, check the app reports the exact RELEASE_SHA, and stop it gracefully.
#
#   bash templates/test-templates.sh            (needs Docker; pulls base images)
# shellcheck disable=SC2015 # "cond && ok || bad": ok always returns 0, so bad never also runs
set -uo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.." || exit 1
root="$(pwd)"; products="$(cd .. && pwd)"
win() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }
SHA="$(printf 'template-test' | sha1sum | cut -c1-40)"
pass=0; failed=0
ok()   { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

# name | template | context | in-container check command (prints the body)
cases=(
  "static|static.Dockerfile|$products/nexwe-website|wget -q -O - http://127.0.0.1/release.json"
  "node-api|node-api.Dockerfile|$root/examples/apps/node-api|node -e \"fetch('http://127.0.0.1:3000/healthz').then(r=>r.text()).then(t=>console.log(t))\""
  "python-api|python.Dockerfile|$root/examples/apps/python-api|python -c \"import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/healthz').read().decode())\""
  "go-api|go.Dockerfile|$root/examples/apps/go-api|wget -q -O - http://127.0.0.1:8080/healthz"
  "worker|worker.Dockerfile|$root/examples/apps/worker|"
)

for c in "${cases[@]}"; do
    IFS='|' read -r name tmpl ctx probe <<<"$c"
    printf '\n\033[1m%s\033[0m (%s)\n' "$name" "$tmpl"
    img="algo3-template-test-$name"
    if ! docker build -q -f "$(win "$root/templates/dockerfiles/$tmpl")" --build-arg "RELEASE_SHA=$SHA" -t "$img" "$(win "$ctx")" >/dev/null 2>"/tmp/build-$name.log"; then
        bad "builds"; tail -5 "/tmp/build-$name.log"; continue
    fi
    ok "builds"
    docker rm -f "$img" >/dev/null 2>&1
    docker run -d --name "$img" "$img" >/dev/null
    health=""
    for _ in $(seq 1 60); do
        health="$(docker inspect -f '{{.State.Health.Status}}' "$img" 2>/dev/null)"
        [[ "$health" == healthy || "$health" == unhealthy ]] && break
        sleep 1
    done
    [[ "$health" == healthy ]] && ok "HEALTHCHECK reports healthy" || { bad "HEALTHCHECK reports '$health'"; docker logs --tail 10 "$img"; }
    if [[ -n "$probe" ]]; then
        body="$(docker exec "$img" sh -c "$probe" 2>&1)"
        [[ "$body" == *"$SHA"* ]] && ok "serves its release ($SHA)" || bad "release not served: $body"
    else
        docker logs "$img" 2>&1 | grep -q "tick $SHA" && ok "runs, knows its release" || bad "worker did not log its release"
    fi
    user="$(docker exec "$img" id -u 2>/dev/null)"
    [[ "$user" != 0 ]] && ok "runs as non-root (uid $user)" || { [[ "$name" == static ]] && ok "static: Caddy serves files only" || bad "runs as root"; }
    t0=$(date +%s%N); docker stop -t 15 "$img" >/dev/null; t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 )); code="$(docker inspect -f '{{.State.ExitCode}}' "$img")"
    (( ms < 10000 )) && ok "stops gracefully on SIGTERM (${ms} ms, exit $code)" || bad "slow stop: ${ms} ms (SIGTERM ignored?)"
    docker rm -f "$img" >/dev/null 2>&1
done

printf '\n\033[1mnode-api: release command (migration) into a named volume\033[0m\n'
img=algo3-template-test-node-api
docker volume rm -f algo3-template-test-data >/dev/null 2>&1
if docker run --rm -v algo3-template-test-data:/data --entrypoint node "$img" dist/migrate.js | grep -q "migrated to schema 2"; then
    ok "migration runs as the non-root user and writes to /data"
else bad "migration failed"; fi
docker run -d --name "$img" -v algo3-template-test-data:/data "$img" >/dev/null
sleep 2
body="$(docker exec "$img" node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>r.text()).then(t=>console.log(t))")"
[[ "$body" == *'"schema":2'* ]] && ok "the app sees the migrated schema" || bad "app does not see the migration: $body"
docker rm -f "$img" >/dev/null 2>&1; docker volume rm -f algo3-template-test-data >/dev/null 2>&1

printf '\nnextjs.Dockerfile is not built here (it needs a real Next.js app); it follows the node-api pattern.\n'
printf '\n\033[1mTemplates: %s passed, %s failed\033[0m\n' "$pass" "$failed"
[[ $failed -eq 0 ]]
