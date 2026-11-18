#!/usr/bin/env bash
# rehearse-biruno-landing.sh — the marketing site (biruno-landing) takes birunoai.com,
# www. and staging. over from the biruno app. /api/* on those names keeps reaching
# the biruno API (installed desktop builds), and the app's old page addresses go to
# app. with a temporary 302. Runs the EXACT server commands, staging then
# production, on a lab in today's server state (after rehearse-biruno-domains.sh):
#
#   bash lab/rehearse-biruno-landing.sh          all steps
#   bash lab/rehearse-biruno-landing.sh 2        one step
#
# What it proves:
#   - the deployer accepts both registries (template = HOSTNAME + ALIASES, one owner
#     per domain) in the order the server steps use
#   - how long /api on the old name is unanswered during the hand-over (outside
#     probe, 0.1 s): biruno must drop the name before the landing site can add it
#   - the site's own headers (CSP, HSTS, cache) arrive through the edge
#   - a biruno rollback does not take the domain back
#
# Lab differences: birunoai.com is biruno.lab.test; images come from the lab
# registry (built from the biruno-landing working copy, like GitHub would).
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

REG=localhost:5000
D=/usr/local/libexec/algo3-deploy
PD=platform.lab.test
BD=biruno.lab.test
PRODUCTS="$(cd "$LAB_DIR/../.." && pwd)"
# The landing release id is salted by the build (step 1 stores it in the lab), so
# a re-run builds a new release instead of a new digest under an old name.
L="$(docker exec algo3-lab cat /root/landing-release 2>/dev/null)"

# Docker rewrites /etc/hosts when the lab restarts: the made-up names go back in,
# and nothing below runs unless they point at the lab (never at a real server).
names() {
    as_root "grep -v 'lab.test' /etc/hosts > /tmp/hosts; cat /tmp/hosts > /etc/hosts; echo '127.0.0.1 $BD www.$BD staging.$BD app.$BD api.$BD staging-app.$BD staging-api.$BD auth-biruno.$PD auth-biruno-staging.$PD files.$PD files-staging.$PD nexwe.app staging-api.nexwe.app' >> /etc/hosts"
    as_root "getent hosts nexwe.app | grep -q '^127\.0\.0\.1 '" || { echo "STOP: the lab's names are not in its /etc/hosts"; exit 1; }
}

step1() {
    title "Step 1 · the landing image (GitHub's job), and today's state"
    names
    L="$(printf 'biruno-landing-%s' "$(date +%s)" | sha1sum | cut -c1-40)"
    as_root "echo $L > /root/landing-release"
    local w; w="$(cygpath -w "$PRODUCTS/biruno-landing" 2>/dev/null || echo "$PRODUCTS/biruno-landing")"
    docker build -q -f "$w/Dockerfile" --build-arg "RELEASE_SHA=$L" -t "$REG/biruno-landing:$L" "$w" >/dev/null &&
        docker save "$REG/biruno-landing:$L" | docker exec -i algo3-lab docker load >/dev/null &&
        as_root "docker push -q $REG/biruno-landing:$L >/dev/null"
    check "the landing image is in the lab registry" "curl -fsS http://localhost:5000/v2/biruno-landing/tags/list | grep -q $L"
    check "today: the old names belong to biruno (/api answers there)" "curl -fsS https://staging.$BD/api/health | grep -q version && curl -fsS https://$BD/api/health | grep -q version"
}

# The registry, as install.sh puts it on the server (lab: image and domain swapped).
registry() {
    as_root "mkdir -p /etc/algo3/apps/biruno-landing
      for a in biruno biruno-landing; do for e in staging production; do
        img=biruno-ai; [ \$a = biruno-landing ] && img=biruno-landing
        sed -e \"s#^IMAGE=.*#IMAGE=$REG/\$img#\" -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/\$a/\$e.conf > /etc/algo3/apps/\$a/\$e.conf
        sed -i 's/^HEALTH_ATTEMPTS=.*//' /etc/algo3/apps/\$a/\$e.conf
        sed -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/\$a/\$e.caddy.tmpl > /etc/algo3/apps/\$a/\$e.caddy.tmpl
      done; done"
}

# switch <env>: biruno drops the old name (its live release is deployed again, which
# re-draws its site), then the landing site takes it. ONE command line on the server.
switch() {
    local e="$1" old=staging.$BD app=staging-app.$BD api=staging-api.$BD
    [[ $e == production ]] && old=$BD app=app.$BD api=api.$BD
    xprobe_start "$old" "lab-x-old-$e" /api/health
    xprobe_start nexwe.app "lab-x-other-$e" /release.json

    note "server: sudo bash /opt/algo3/delivery/server/install.sh --app biruno; ... --app biruno-landing"
    registry
    local land
    if [[ $e == staging ]]; then
        land="sudo $D deploy biruno-landing staging $L \$(sudo docker image inspect -f '{{index .RepoDigests 0}}' $REG/biruno-landing:$L | cut -d@ -f2)"
    else
        land="sudo $D deploy biruno-landing production $L \$(sudo awk -v s=$L '\$2==s {d=\$3} END {print d}' /var/lib/algo3/biruno-landing/staging.history)"
    fi
    # The server command: the landing image is pulled first, so the gap is only the
    # container's start; biruno's live release is read from the deployer itself.
    run "sudo docker pull -q $REG/biruno-landing:$L >/dev/null; c=\$(sudo $D status biruno $e | awk '/^live:/ {print \$2}'); r=\$(sudo docker inspect -f '{{index .Config.Labels \"algo3.release\"}} {{index .Config.Labels \"algo3.digest\"}}' \$c); echo \"biruno $e live: \$r\"; sudo $D deploy biruno $e \$r > /tmp/bl-biruno-$e.log 2>&1 && $land > /tmp/bl-landing-$e.log 2>&1; echo exit \$?; tail -2 /tmp/bl-landing-$e.log"
    sleep 3
    read -r t b l <<<"$(xprobe_stop "lab-x-old-$e")"
    note "old https://$old/api/health during the hand-over: $t requests, $b failed, longest gap ${l}s"
    check "desktop builds' /api gap on the old name stayed under 15 s" "awk 'BEGIN {exit !($l < 15)}' && [ '$t' -gt 20 ]"
    read -r t b l <<<"$(xprobe_stop "lab-x-other-$e")"
    note "another site (nexwe.app) during the hand-over: $t requests, $b failed, longest ${l}s (measured, not a pass/fail)"

    check "biruno re-drew its site without the old name, no warning" "grep -q 'already live' /tmp/bl-biruno-$e.log && ! grep -q WARNING /tmp/bl-biruno-$e.log && ! grep -E '^[^#[:space:]].*\{\$' /etc/algo3/caddy/sites/biruno-$e.caddy | tr -s ', {' '\n' | grep -qx '$old'"
    check "the landing deploy succeeded with no domain warning" "grep -q 'Deployed biruno-landing/$e $L' /tmp/bl-landing-$e.log && ! grep -q WARNING /tmp/bl-landing-$e.log"
    check "landing: the site is the new release" "curl -fsS https://$old/release.json | grep -q $L && curl -fsS https://$old/ | grep -q BirunoAI"
    check "landing: its own CSP, HSTS and frame headers arrive through the edge" "h=\$(curl -sI https://$old/); echo \"\$h\" | grep -qi \"^content-security-policy: default-src 'self'\" && echo \"\$h\" | grep -qi '^strict-transport-security: max-age=31536000' && echo \"\$h\" | grep -qi '^x-frame-options: DENY'"
    check "landing: HTML revalidates, assets cached a day" "curl -sI https://$old/ | grep -qi '^cache-control: public, max-age=0, must-revalidate' && curl -sI https://$old/assets/css/styles.css | grep -qi '^cache-control: public, max-age=86400'"
    check "landing: an unknown page is its 404 page with status 404" "[ \"\$(curl -s -o /tmp/bl-404 -w '%{http_code}' https://$old/no-such-page)\" = 404 ] && grep -q 'Page not found' /tmp/bl-404"
    check "old name: /api still reaches the biruno API (and a POST is not redirected)" "curl -fsS https://$old/api/health | grep -q version && [ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST https://$old/api/runs)\" != 302 ]"
    check "old name: app pages go to the app with a TEMPORARY 302, path kept" "[ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' 'https://$old/auth/reset?token=abc')\" = '302 https://$app/auth/reset?token=abc' ] && [ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://$old/login)\" = '302 https://$app/login' ]"
    check "the app and the API still answer on their own names" "curl -fsS https://$app/ | grep -qi '<html' && curl -fsS https://$api/api/health | grep -q version"
    if [[ $e == staging ]]; then
        check "staging: never indexed (site and /api)" "curl -sI https://$old/ | grep -qi 'x-robots-tag: noindex' && curl -sI https://$old/api/health | grep -qi 'x-robots-tag: noindex'"
    else
        check "production: indexable (no noindex header)" "! curl -sI https://$old/ | grep -qi 'x-robots-tag'"
        check "www.: pages redirect permanently to the bare name, /api still answers" "[ \"\$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' https://www.$BD/pricing)\" = '301 https://$BD/pricing' ] && curl -fsS https://www.$BD/api/health | grep -q version"
    fi
}

step2() { title "Step 2 · staging: staging.$BD moves to the landing site"; names; switch staging; }
step3() { title "Step 3 · production: $BD and www. move (the SAME image staging ran)"; names; switch production; }

step4() {
    title "Step 4 · biruno keeps away from the landing site's names"
    names
    run "c=\$(sudo $D status biruno production | awk '/^live:/ {print \$2}'); r=\$(sudo docker inspect -f '{{index .Config.Labels \"algo3.release\"}} {{index .Config.Labels \"algo3.digest\"}}' \$c); sudo $D deploy biruno production \$r > /tmp/bl-again.log 2>&1; echo exit \$?"
    check "after biruno redraws its site again, the landing site still serves $BD" "curl -fsS https://$BD/release.json | grep -q $L && curl -fsS https://$BD/api/health | grep -q version && curl -fsS https://app.$BD/ | grep -qi '<html'"
    # One owner per domain: a (throwaway, lab-only) app declaring $BD is refused before anything is pulled.
    check "another app claiming $BD is refused, naming biruno-landing" "mkdir -p /etc/algo3/apps/lab-claim && printf 'IMAGE=$REG/biruno-landing\nHOSTNAME=$BD\n' > /etc/algo3/apps/lab-claim/production.conf; $D deploy lab-claim production $L > /tmp/claim.log 2>&1; rc=\$?; rm -rf /etc/algo3/apps/lab-claim; [ \$rc != 0 ] && grep -q 'already claimed by biruno-landing/production' /tmp/claim.log"
}

step5() {
    title "Step 5 · nothing else was disturbed"
    names
    check "nexwe.app" 'curl -fsS https://nexwe.app/release.json | grep -q release'
    check "nexwe staging API" 'curl -fsS https://staging-api.nexwe.app/health >/dev/null'
    check "the platform's files site" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$PD/x/y)\" = 403 ]"
}

[[ $# -gt 0 ]] || set -- 1 2 3 4 5
for s in "$@"; do "step$s"; done
finish
