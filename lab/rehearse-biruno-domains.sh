#!/usr/bin/env bash
# rehearse-biruno-domains.sh — biruno moves to app.<domain> (web) + api.<domain> (API);
# the old <domain>, www. and staging. keep /api/* (installed desktop builds have
# them baked in) and send everything else to the app with a temporary 302.
# Runs the EXACT server commands, staging then production, on a lab already in
# today's server state (after rehearse-platform-staging.sh):
#
#   bash lab/rehearse-biruno-domains.sh          all steps
#   bash lab/rehearse-biruno-domains.sh 2        one step
#
# What it proves:
#   - the deployer accepts the new registry (template = HOSTNAME + ALIASES) and
#     checks every new name after the switch
#   - the old /api/health never fails during the move (outside probe, 0.1 s)
#   - /config.js gives the web app its API host; CORS lets only the app call it
#   - the sign-in server takes the new site URL with the SAME keys (no logout)
#   - a rollback to the previous release still serves on the new names
#
# Lab differences: birunoai.com is biruno.lab.test; images come from the lab
# registry (built from the biruno-ai working copy, like GitHub would).
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

REG=localhost:5000
D=/usr/local/libexec/algo3-deploy
PD=platform.lab.test
BD=biruno.lab.test
PRODUCTS="$(cd "$LAB_DIR/../.." && pwd)"
R3="$(printf 'biruno-domains-release-3' | sha1sum | cut -c1-40)"
digest_of() { as_root "docker image inspect -f '{{index .RepoDigests 0}}' $REG/biruno-ai:$1 | cut -d@ -f2"; }

step1() {
    title "Step 1 · names in the lab's address book, and the new image (GitHub's job)"
    # Docker rewrites /etc/hosts when the lab restarts, so the made-up names go back in.
    # (/etc/hosts is a mount: rewrite it in place, sed -i cannot replace it.)
    as_root "grep -v 'lab.test' /etc/hosts > /tmp/hosts; cat /tmp/hosts > /etc/hosts; echo '127.0.0.1 $BD www.$BD staging.$BD app.$BD api.$BD staging-app.$BD staging-api.$BD auth-biruno.$PD auth-biruno-staging.$PD files.$PD files-staging.$PD nexwe.app staging-api.nexwe.app' >> /etc/hosts"
    local w; w="$(cygpath -w "$PRODUCTS/biruno-ai" 2>/dev/null || echo "$PRODUCTS/biruno-ai")"
    docker build -q -f "$w/apps/server/Dockerfile" --build-arg "RELEASE_SHA=$R3" -t "$REG/biruno-ai:$R3" "$w" >/dev/null &&
        docker save "$REG/biruno-ai:$R3" | docker exec -i algo3-lab docker load >/dev/null &&
        as_root "docker push -q $REG/biruno-ai:$R3 >/dev/null"
    check "the new image is in the lab registry" "curl -fsS http://localhost:5000/v2/biruno-ai/tags/list | grep -q $R3"
    check "today: staging serves on the OLD name" "curl -fsS https://staging.$BD/api/health | grep -q version"
}

# The registry, as install.sh puts it on the server (lab: image and domain swapped).
registry() {
    as_root "for e in staging production; do
        sed -e 's#^IMAGE=.*#IMAGE=$REG/biruno-ai#' -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/biruno/\$e.conf > /etc/algo3/apps/biruno/\$e.conf
        sed -i 's/^HEALTH_ATTEMPTS=.*//' /etc/algo3/apps/biruno/\$e.conf
        sed -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/biruno/\$e.caddy.tmpl > /etc/algo3/apps/biruno/\$e.caddy.tmpl
      done"
}

# switch <env>: the three server edits, then the deploy (staging) or promotion (production).
switch() {
    local e="$1" dir=/opt/studio-platform svc=gotrue-biruno var=BIRUNO_ORIGIN app=app.$BD api=api.$BD old=$BD auth=auth-biruno.$PD
    if [[ $e == staging ]]; then
        dir=/opt/studio-platform-staging svc=gotrue-biruno-staging var=BIRUNO_STAGING_ORIGIN
        app=staging-app.$BD api=staging-api.$BD old=staging.$BD auth=auth-biruno-staging.$PD
    fi
    as_root "curl -fsS https://$auth/.well-known/jwks.json > /tmp/jwks-before-$e"
    xprobe_start "$old" "lab-x-old-$e" /api/health
    xprobe_start nexwe.app "lab-x-other-$e" /release.json   # the edge reloads once: another site's view

    note "server edit 1: the sign-in server's site URL"
    run "cd $dir && sudo sed -i 's#^$var=.*#$var=https://$app#' .env && sudo docker compose up -d $svc 2>&1 | tail -1"
    note "server edit 2: the app's env file"
    run "sudo sed -i -e 's#^APP_ORIGIN=.*#APP_ORIGIN=https://$app#' -e '/^PUBLIC_API_URL=/d' /etc/algo3/apps/biruno/$e.env && echo 'PUBLIC_API_URL=https://$api' | sudo tee -a /etc/algo3/apps/biruno/$e.env >/dev/null && sudo grep -E '^(APP_ORIGIN|PUBLIC_API_URL)=' /etc/algo3/apps/biruno/$e.env"
    note "server edit 3: the registry (server: sudo bash /opt/algo3/delivery/server/install.sh --app biruno)"
    registry
    if [[ $e == staging ]]; then
        run "sudo $D deploy biruno staging $R3 $(digest_of "$R3") > /tmp/bd-$e.log 2>&1; echo exit \$?; grep -E 'alias|WARNING|live' /tmp/bd-$e.log | tail -6"
    else
        run "d=\$(sudo awk -v s=$R3 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/biruno/staging.history); sudo $D deploy biruno production $R3 \$d > /tmp/bd-$e.log 2>&1; echo exit \$?; grep -E 'alias|WARNING|live' /tmp/bd-$e.log | tail -6"
    fi
    sleep 3
    read -r t b l <<<"$(xprobe_stop "lab-x-old-$e")"
    note "old https://$old/api/health during the whole switch: $t requests, $b failed, longest ${l}s"
    check "installed desktop builds never lost the API (old name, 0 failed of $t)" "[ '$b' = 0 ] && [ '$t' -gt 20 ]"
    read -r t b l <<<"$(xprobe_stop "lab-x-other-$e")"
    note "another site (nexwe.app) during the switch: $t requests, $b failed, longest ${l}s (measured, not a pass/fail)"

    check "the deploy succeeded with no domain warning" "grep -qE 'Deployed biruno/$e $R3|Release $R3 is already live' /tmp/bd-$e.log && ! grep -q WARNING /tmp/bd-$e.log"
    check "the deployer checked each new name" "grep -q 'https://$api (alias) answers' /tmp/bd-$e.log && grep -q 'https://$old (alias) answers' /tmp/bd-$e.log"
    check "app: the web app (200, html)" "curl -fsS https://$app/ | grep -qi '<html'"
    check "app: /config.js names the API host and this env's sign-in server" "curl -fsS https://$app/config.js | grep -q '\"apiUrl\":\"https://$api\"' && curl -fsS https://$app/config.js | grep -q '\"authUrl\":\"https://$auth\"'"
    check "api: /api/health is the new release" "curl -fsS https://$api/api/health | grep -q '\"version\":\"$R3\"'"
    check "api: a page address goes to the app (302)" "[ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://$api/sessions)\" = '302 https://$app/sessions' ]"
    check "old name: pages go to the app with a TEMPORARY 302, path kept" "[ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' 'https://$old/sessions/abc?x=1')\" = '302 https://$app/sessions/abc?x=1' ]"
    check "old name: /api still reaches the API (and a POST is not redirected)" "curl -fsS https://$old/api/health | grep -q $R3 && [ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST https://$old/api/runs)\" != 302 ]"
    check "CORS: the app may call the API with its token" "curl -s -o /dev/null -D - -X OPTIONS -H 'Origin: https://$app' -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization' https://$api/api/me | grep -qi 'access-control-allow-origin: https://$app'"
    check "CORS: the old name is no longer an allowed origin" "! curl -s -o /dev/null -D - -X OPTIONS -H 'Origin: https://$old' -H 'Access-Control-Request-Method: GET' https://$api/api/me | grep -qi 'access-control-allow-origin'"
    check "sign-in server: site URL and allowed return address are the app" "docker inspect \$(docker ps -qf name=$svc\$) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qx 'GOTRUE_SITE_URL=https://$app' && docker inspect \$(docker ps -qf name=$svc\$) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qx 'GOTRUE_URI_ALLOW_LIST=https://$app'"
    check "sign-in server: the SAME signing keys (nobody is logged out)" "curl -fsS https://$auth/.well-known/jwks.json | cmp -s - /tmp/jwks-before-$e"
    if [[ $e == staging ]]; then
        check "staging: never indexed, on every name" "for h in $app $api $old; do curl -sI https://\$h/api/health | grep -qi 'x-robots-tag: noindex' || exit 1; done"
    else
        check "production: www. behaves as the old name" "[ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://www.$BD/)\" = '302 https://$app/' ]"
    fi
}

step2() { title "Step 2 · staging moves"; switch staging; }
step3() { title "Step 3 · production moves (the SAME image staging ran)"; switch production; }

step4() {
    title "Step 4 · rollback drill: the previous release on the new names"
    run "sudo $D rollback biruno production > /tmp/bd-rb.log 2>&1; echo exit \$?; tail -2 /tmp/bd-rb.log"
    check "rolled back: the old release serves the app on app." "curl -fsS https://app.$BD/api/health | grep -qv '$R3' && curl -fsS https://app.$BD/ | grep -qi '<html'"
    check "rolled back: the old app has no apiUrl, so it stays same-origin (works on app.)" "! curl -fsS https://app.$BD/config.js | grep -q apiUrl"
    run "d=\$(sudo awk -v s=$R3 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/biruno/staging.history); sudo $D deploy biruno production $R3 \$d > /tmp/bd-again.log 2>&1; echo exit \$?"
    check "forward again: the new release is live" "curl -fsS https://api.$BD/api/health | grep -q '\"version\":\"$R3\"'"
}

step5() {
    title "Step 5 · nothing else was disturbed"
    check "nexwe.app" 'curl -fsS https://nexwe.app/release.json | grep -q release'
    check "nexwe staging API" 'curl -fsS https://staging-api.nexwe.app/health >/dev/null'
    check "the platform's files site" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$PD/x/y)\" = 403 ]"
}

[[ $# -gt 0 ]] || set -- 1 2 3 4 5
for s in "$@"; do "step$s"; done
finish
