#!/usr/bin/env bash
# rehearse-phase3.sh — the edge cutover, in the lab, with the runbook's exact
# commands. Run after rehearse-phase2.sh on the same lab:
#
#   bash lab/up.sh && bash lab/rehearse-phase2.sh && bash lab/rehearse-phase3.sh
#
# Downtime is measured by the EXTERNAL probe: a separate container reaching the
# lab over the network, the path real visitors take.
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

NEW=f568992edc66e7a85bda69b44138a0f51b94a495
sites_ok='for h in nexwe.app staging.nexwe.app; do curl -fsS "https://$h/release.json" | grep -q '"$NEW"' || exit 1; done'
edge_up='docker compose -p algo3-edge -f /opt/algo3/edge/compose.yml'

wait_https() { as_root 'for i in $(seq 1 100); do curl -fsS -o /dev/null https://nexwe.app/ && curl -fsS -o /dev/null https://staging.nexwe.app/ && exit 0; sleep 0.2; done; exit 1'; }
serial() { as_root 'echo | openssl s_client -connect 127.0.0.1:443 -servername nexwe.app 2>/dev/null | openssl x509 -noout -serial'; }

step0() {
    title "Step 0 · refresh the code on the server (same commands as Phase 2, steps 0 and 1)"
    run "rm -rf ~/stage && mkdir -p ~/stage && tar -C /lab --exclude=.git --exclude=.mut --exclude=.work -czf - algo3-delivery | tar -xzf - -C ~/stage"
    run "sudo rm -rf /opt/algo3/delivery && sudo cp -a ~/stage/algo3-delivery /opt/algo3/delivery && sudo chown -R root:root /opt/algo3/delivery"
    run "sudo bash /opt/algo3/delivery/server/install.sh | tail -2"
    check "the deployer knows PUBLIC_CHECK_PORT" 'grep -q PUBLIC_CHECK_PORT /usr/local/libexec/algo3-deploy'
}

step1() {
    title "Step 1 · install the edge and start it on DRY-RUN ports (18080/18443)"
    xprobe_start
    run "sudo bash /opt/algo3/delivery/edge/install.sh"
    run "sudo sed -i 's/^ACME_EMAIL=.*/ACME_EMAIL=ops@nexwe.app/' /opt/algo3/edge/.env"
    note "(lab only: local certificates instead of Let's Encrypt)"
    as_root "sed -i 's/^EDGE_LAB_OPTIONS=.*/EDGE_LAB_OPTIONS=local_certs/' /opt/algo3/edge/.env"
    run "sudo $edge_up up -d"
    as_root 'for i in $(seq 1 40); do [ "$(docker inspect -f {{.State.Health.Status}} studio-caddy)" = healthy ] && exit 0; sleep 2; done; exit 1'
    read -r total bad longest <<<"$(xprobe_stop)"
    note "nexwe.app while installing the edge: $total requests, $bad failed"
    check "no effect on the live site" "test $bad -eq 0"
    check "network studio exists" 'docker network inspect studio'
    check "host certificates copied into the edge volume" '[ "$(docker run --rm -v algo3-edge-data:/data busybox sh -c "find /data/caddy/certificates -name \"*.crt\" | wc -l")" -ge 2 ]'
    check "edge is healthy" 'test "$(docker inspect -f {{.State.Health.Status}} studio-caddy)" = healthy'
    check "edge listens on 18443, the host Caddy still owns 443" 'ss -ltnp | grep -q ":18443 " && ss -ltnp | grep ":443 " | grep -q caddy'
    check ".env is root-only" 'test "$(stat -c %U:%a /opt/algo3/edge/.env)" = root:600'
    check "re-running the installer changes nothing and keeps the certificates" 'bash /opt/algo3/delivery/edge/install.sh | grep -q "already holds certificates"'
    check "live sites unaffected" "$sites_ok"
}

step2() {
    title "Step 2 · register nexwe-website, bootstrap deploys through the dry-run edge"
    xprobe_start
    run "sudo bash /opt/algo3/delivery/server/install.sh --app nexwe-website | tail -6"
    note "(lab only: images come from the lab registry instead of ghcr.io)"
    as_root "sed -i 's#^IMAGE=.*#IMAGE=localhost:5000/nexwe-website#' /etc/algo3/apps/nexwe-website/*.conf"
    run "sudo sed -i 's/^PUBLIC_CHECK_PORT=.*/PUBLIC_CHECK_PORT=18443/' /etc/algo3/delivery.conf"
    run "sudo /usr/local/libexec/algo3-deploy deploy nexwe-website staging $NEW"
    run "digest=\$(sudo awk -v s=$NEW '\$2==s {d=\$3} END {print d}' /var/lib/algo3/nexwe-website/staging.history) && echo \"staging verified digest: \$digest\" && sudo /usr/local/libexec/algo3-deploy deploy nexwe-website production $NEW \"\$digest\""
    run "sudo /usr/local/libexec/algo3-deploy status nexwe-website production"
    read -r total bad longest <<<"$(xprobe_stop)"
    note "nexwe.app during both bootstrap deploys: $total requests, $bad failed"
    check "no effect on the live site" "test $bad -eq 0"
    for env in staging production; do
        check "$env: labelled release container on the studio network" \
            "docker inspect -f '{{index .Config.Labels \"algo3.env\"}} {{json .NetworkSettings.Networks}}' nexwe-website-$env-${NEW:0:12} | grep -q '^$env .*\"studio\"'"
    done
    check "the edge serves production on 18443" "curl -fsS --resolve nexwe.app:18443:127.0.0.1 https://nexwe.app:18443/release.json | grep -q $NEW"
    check "the edge serves staging on 18443, with noindex" "curl -fsSI --resolve staging.nexwe.app:18443:127.0.0.1 https://staging.nexwe.app:18443/ | grep -qi 'x-robots-tag: noindex'"
    check "both deploys logged" '[ "$(grep -c "app=nexwe-website.*result=ok" /var/log/algo3/deploys.log)" -eq 2 ]'
    check "host Caddy still serves the old containers" 'systemctl is-active caddy && docker inspect -f {{.State.Running}} nexwe-website | grep -q true'
}

step3() {
    title "Step 3 · THE CUTOVER (production: needs approval on the server)"
    local before after
    before="$(serial)"
    xprobe_start
    run "sudo sed -i '/^EDGE_HTTP_PORT=/d; /^EDGE_HTTPS_PORT=/d' /opt/algo3/edge/.env"
    run "sudo systemctl stop caddy && sudo $edge_up up -d"
    wait_https; sleep 3
    read -r total bad longest <<<"$(xprobe_stop)"
    note "CUTOVER: $total requests, $bad failed, longest outage ${longest}s"
    run "sudo sed -i 's/^PUBLIC_CHECK_PORT=.*/PUBLIC_CHECK_PORT=443/' /etc/algo3/delivery.conf"
    run "sudo systemctl disable caddy"
    after="$(serial)"
    check "cutover outage under 3 s" "python3 -c 'import sys; sys.exit(0 if $longest < 3 else 1)'"
    check "same certificate before and after (no re-issuance): $before" "test '$before' = '$after' -a -n '$before'"
    check "host Caddy stopped and disabled" '! systemctl is-active caddy && ! systemctl is-enabled caddy'
    check "the edge owns 443" 'ss -ltnp | grep ":443 " | grep -qv "\"caddy\""'
    check "sites serve $NEW" "$sites_ok"
    check "www.nexwe.app redirects to nexwe.app" 'curl -sI https://www.nexwe.app/ | grep -qi "^location: https://nexwe.app/"'
    check "staging keeps its noindex header" 'curl -sI https://staging.nexwe.app/ | grep -qi "x-robots-tag: noindex"'
    check "traffic really goes to the NEW containers (old ones stopped for a moment)" \
        'docker stop nexwe-website nexwe-staging >/dev/null && curl -fsS https://nexwe.app/release.json | grep -q '"$NEW"' && curl -fsS https://staging.nexwe.app/release.json | grep -q '"$NEW"'; rc=$?; docker start nexwe-website nexwe-staging >/dev/null; exit $rc'
}

step4() {
    title "Step 4 · rollback drill: back to the host Caddy, then forward again"
    xprobe_start
    run "sudo $edge_up stop && sudo systemctl start caddy"
    wait_https; sleep 3
    read -r total bad longest <<<"$(xprobe_stop)"
    note "ROLLBACK: $total requests, $bad failed, longest outage ${longest}s"
    check "rollback restores service in under 3 s" "python3 -c 'import sys; sys.exit(0 if $longest < 3 else 1)'"
    check "host Caddy serving again" "systemctl is-active caddy && $sites_ok"
    xprobe_start
    run "sudo systemctl stop caddy && sudo $edge_up up -d"
    wait_https; sleep 3
    read -r total bad longest <<<"$(xprobe_stop)"
    note "FORWARD AGAIN: $total requests, $bad failed, longest outage ${longest}s"
    check "forward again in under 3 s" "python3 -c 'import sys; sys.exit(0 if $longest < 3 else 1)'"
    check "the edge serves again" "$sites_ok"
}

step5() {
    title "Step 5 · a Docker restart after the cutover (as a Docker upgrade would do)"
    as_root 'docker inspect -f "{{.State.StartedAt}}" studio-caddy nexwe-website-production-'"${NEW:0:12}"' > /tmp/started-before; sleep 20'
    xprobe_start
    run "sudo systemctl restart docker"
    sleep 6
    read -r total bad longest <<<"$(xprobe_stop)"
    note "DOCKER RESTART after cutover: $total requests, $bad failed, longest outage ${longest}s"
    check "edge and release containers were not restarted (live-restore)" 'test "$(docker inspect -f "{{.State.StartedAt}}" studio-caddy nexwe-website-production-'"${NEW:0:12}"')" = "$(cat /tmp/started-before)"'
    # Measured 2026-10-29: ~1.7 s. dockerd deletes and recreates its port-
    # forwarding rules on every start, so even with live-restore (containers
    # untouched) traffic pauses briefly. Docker restarts happen only when an
    # admin upgrades Docker: do that in a quiet hour.
    check "Docker restart outage under 3 s" "python3 -c 'import sys; sys.exit(0 if $longest < 3 else 1)'"
    check "sites serve $NEW" "$sites_ok"
}

[[ $# -gt 0 ]] || set -- 0 1 2 3 4 5
for s in "$@"; do "step$s"; done
finish
