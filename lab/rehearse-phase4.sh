#!/usr/bin/env bash
# rehearse-phase4.sh — automated deploys of nexwe-website, in the lab, after
# rehearse-phase3.sh. The lab plays the GitHub runner: it builds release images
# from the CURRENT nexwe-website working tree, then deploys exactly as the
# reusable workflow does — `printf 'sha\ndigest\n' | ssh algo3-deploy@server`
# with a key pinned to one app/env.
#
#   bash lab/rehearse-phase4.sh            all steps (needs Phase 2 + 3 done)
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

OLD=f568992edc66e7a85bda69b44138a0f51b94a495
fake_sha() { printf 'lab-release-%s' "$1" | sha1sum | cut -c1-40; }
R1="$(fake_sha 1)"; R2="$(fake_sha 2)"; R3="$(fake_sha 3)"; BAD="$(fake_sha bad)"; SICK="$(fake_sha sick)"
REG=localhost:5000/nexwe-website
products="$(cd "$LAB_DIR/../.." && pwd)"

serves() { printf 'curl -fsS https://%s/release.json | grep -q %s' "$1" "$2"; }   # check body
ci_deploy() {   # ci_deploy <env> <sha> <digest>: what the workflow's deploy step runs
    as_root "printf '%s\n%s\n' $2 $3 | ssh -T -i /root/ci_$1 -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1"
}
digest_of() { as_root "docker image inspect --format '{{index .RepoDigests 0}}' $REG:$1 | cut -d@ -f2"; }

step1() {
    title "Step 1 · the CI side: release images built from the current nexwe-website tree"
    tar -C "$products/nexwe-website" --exclude=node_modules --exclude=dist --exclude=.git --exclude=.vite -cf - . |
        docker exec -i algo3-lab sh -c 'rm -rf /root/nexwe-src && mkdir -p /root/nexwe-src && tar -xf - -C /root/nexwe-src'
    as_root 'cp -a /root/nexwe-src /root/nexwe-sick && printf ":80 {\n\trespond 500\n}\n" > /root/nexwe-sick/Caddyfile'
    local sha
    for sha in "$R1" "$R2" "$R3"; do
        as_root "docker build -q --build-arg RELEASE_SHA=$sha -t $REG:$sha /root/nexwe-src >/dev/null && docker push -q $REG:$sha >/dev/null"
    done
    note "(BAD: an image whose release.json names a different commit than its tag)"
    as_root "docker build -q --build-arg RELEASE_SHA=$R1 -t $REG:$BAD /root/nexwe-src >/dev/null && docker push -q $REG:$BAD >/dev/null"
    note "(SICK: an image that answers 500, so its healthcheck fails)"
    as_root "docker build -q --build-arg RELEASE_SHA=$SICK -t $REG:$SICK /root/nexwe-sick >/dev/null && docker push -q $REG:$SICK >/dev/null"
    check "release images built from the new Dockerfile carry a HEALTHCHECK" "docker image inspect -f '{{json .Config.Healthcheck.Test}}' $REG:$R1 | grep -q wget"
    check "base image is the pinned Caddy 2.11.7" "docker run --rm $REG:$R1 caddy version | grep -q '^v2.11.7'"
}

step2() {
    title "Step 2 · deploy keys: one per environment, each pinned to a forced command"
    as_root 'for env in staging production; do rm -f /root/ci_$env /root/ci_$env.pub; ssh-keygen -q -t ed25519 -N "" -C ci-nexwe-website-$env -f /root/ci_$env; done
             ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null > /root/ci_known_hosts'
    note "(on the server you paste the two PUBLIC keys; this is the command shape)"
    as_root 'install -d -o algo3-deploy -g algo3-deploy -m 700 /home/algo3-deploy/.ssh
             { printf "restrict,command=\"/usr/local/sbin/algo3-deploy-ssh nexwe-website staging\" %s\n" "$(cat /root/ci_staging.pub)"
               printf "restrict,command=\"/usr/local/sbin/algo3-deploy-ssh nexwe-website production\" %s\n" "$(cat /root/ci_production.pub)"
             } > /home/algo3-deploy/.ssh/authorized_keys
             chown algo3-deploy: /home/algo3-deploy/.ssh/authorized_keys; chmod 600 /home/algo3-deploy/.ssh/authorized_keys'
    check "exactly two keys, both forced-command pinned" '[ "$(grep -c "^restrict,command=\"/usr/local/sbin/algo3-deploy-ssh nexwe-website " /home/algo3-deploy/.ssh/authorized_keys)" -eq 2 ] && [ "$(wc -l < /home/algo3-deploy/.ssh/authorized_keys)" -eq 2 ]'
    check "a deploy key cannot run commands" 'out="$(ssh -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 "id" </dev/null 2>&1)"; ! grep -q uid= <<<"$out"'
    check "an unknown host key is refused (no blind trust)" '! printf "x\n" | ssh -T -i /root/ci_staging -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null algo3-deploy@127.0.0.1 2>/dev/null'
}

step3() {
    title "Step 3 · push to staging → automatic staging deploy"
    local d1; d1="$(digest_of "$R1")"
    xprobe_start nexwe.app lab-xprobe-prod; xprobe_start staging.nexwe.app lab-xprobe-stg
    as_root ': > /var/log/lab-fakehc.log'
    ci_deploy staging "$R1" "$d1"
    read -r pt pb _ <<<"$(xprobe_stop lab-xprobe-prod)"; read -r st sb sl <<<"$(xprobe_stop lab-xprobe-stg)"
    note "staging deploy — production: $pt requests, $pb failed | staging: $st requests, $sb failed, longest ${sl}s"
    check "staging serves R1" "$(serves staging.nexwe.app "$R1")"
    check "production untouched (still $OLD)" "$(serves nexwe.app "$OLD")"
    check "zero failed requests on production during a staging deploy" "test $pb -eq 0"
    check "zero failed requests on STAGING across its own switch" "test $sb -eq 0"
    check "the new release container is healthy and autoheal-labelled" "test \"\$(docker inspect -f '{{.State.Health.Status}} {{index .Config.Labels \"autoheal\"}}' nexwe-website-staging-${R1:0:12})\" = 'healthy true'"
    check "previous staging release retained, stopped" "test \"\$(docker inspect -f {{.State.Status}} nexwe-website-staging-${OLD:0:12})\" = exited"
    check "deploys heartbeat pinged" 'grep -q "/ping/deploys " /var/log/lab-fakehc.log'
    check "deploy ran as a systemd unit and is logged" 'journalctl --no-pager -u "algo3-deploy-nexwe-website-staging-*" | grep -q "Deployed nexwe-website/staging" && grep -q "env=staging result=ok release='"$R1"'" /var/log/algo3/deploys.log'
}

step4() {
    title "Step 4 · merge to main → production promotion of the SAME digest"
    local d1 d2; d1="$(digest_of "$R1")"; d2="$(digest_of "$R2")"
    xprobe_start nexwe.app lab-xprobe-prod
    ci_deploy production "$R1" "$d1"
    read -r pt pb pl <<<"$(xprobe_stop lab-xprobe-prod)"
    note "production deploy: $pt requests, $pb failed, longest ${pl}s"
    check "production serves R1" "$(serves nexwe.app "$R1")"
    check "zero failed requests on production across the switch" "test $pb -eq 0"
    note "-- the gate: R2 was never on staging --"
    check "production refuses a release staging never ran" "! printf '%s\n%s\n' $R2 $d2 | ssh -T -i /root/ci_production -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1"
    check "production still serves R1" "$(serves nexwe.app "$R1")"
    check "the production key can only deploy production" "printf '%s\n%s\n' $R1 $d1 | ssh -T -i /root/ci_production -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 2>&1 | grep -q 'production'"
}

step5() {
    title "Step 5 · failure drills on staging (the live release must stay up)"
    local db ds; db="$(digest_of "$BAD")"; ds="$(digest_of "$SICK")"
    xprobe_start staging.nexwe.app lab-xprobe-stg
    check "wrong release marker: refused, and CI is told why" "out=\"\$(printf '%s\n%s\n' $BAD $db | ssh -T -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 2>&1)\"; rc=\$?; [ \$rc -ne 0 ] && grep -q 'does not report release' <<<\"\$out\""
    check "unhealthy image: refused" "! printf '%s\n%s\n' $SICK $ds | ssh -T -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 >/dev/null 2>&1"
    check "image that does not exist: refused" "! printf '%s\n' 0123456789abcdef0123456789abcdef01234567 | ssh -T -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 >/dev/null 2>&1"
    read -r st sb _ <<<"$(xprobe_stop lab-xprobe-stg)"
    note "staging during three refused deploys: $st requests, $sb failed"
    check "staging never dropped a request" "test $sb -eq 0"
    check "staging still serves R1" "$(serves staging.nexwe.app "$R1")"
    check "no failed release container left behind" "! docker inspect nexwe-website-staging-${BAD:0:12} nexwe-website-staging-${SICK:0:12} >/dev/null 2>&1"
    check "each refusal logged as recovered" '[ "$(grep -c "env=staging result=failed.*detail=recovered" /var/log/algo3/deploys.log)" -ge 3 ]'
}

step6() {
    title "Step 6 · SSH dies mid-deploy; and two deploys at once"
    local d2 d3; d2="$(digest_of "$R2")"; d3="$(digest_of "$R3")"
    note "-- the runner's connection is killed 3 s into a deploy --"
    as_root "printf '%s\n%s\n' $R2 $d2 | timeout -s KILL 3 ssh -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 >/dev/null 2>&1; true"
    as_root 'for i in $(seq 1 60); do systemctl list-units --no-legend "algo3-deploy-nexwe-website-staging-*" | grep -q . || exit 0; sleep 2; done; exit 1'
    check "the deploy finished anyway: staging serves R2" "$(serves staging.nexwe.app "$R2")"
    check "and it is logged ok" "grep -q 'env=staging result=ok release=$R2' /var/log/algo3/deploys.log"
    note "-- two deploys started together --"
    as_root "(printf '%s\n%s\n' $R3 $d3 | ssh -T -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 >/tmp/c1 2>&1) &
             sleep 0.5
             printf '%s\n%s\n' $R3 $d3 | ssh -T -i /root/ci_staging -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1 >/tmp/c2 2>&1
             wait"
    check "one of two concurrent deploys refused by the lock" 'grep -q "Another deploy or rollback" /tmp/c1 /tmp/c2'
    check "the other one succeeded: staging serves R3" "$(serves staging.nexwe.app "$R3")"
}

step7() {
    title "Step 7 · emergency rollback (admin), and retention"
    xprobe_start nexwe.app lab-xprobe-prod
    run "sudo /usr/local/libexec/algo3-deploy rollback nexwe-website production"
    read -r pt pb pl <<<"$(xprobe_stop lab-xprobe-prod)"
    note "rollback: $pt requests, $pb failed, longest ${pl}s"
    check "production rolled back to $OLD" "$(serves nexwe.app "$OLD")"
    check "zero failed requests during the rollback" "test $pb -eq 0"
    run "sudo /usr/local/libexec/algo3-deploy rollback nexwe-website production"
    check "rolling back again returns to R1" "$(serves nexwe.app "$R1")"
    run "sudo /usr/local/libexec/algo3-deploy status nexwe-website staging"
    check "staging keeps exactly one rollback (live + 1)" '[ "$(docker ps -a --filter label=algo3.app=nexwe-website --filter label=algo3.env=staging -q | wc -l)" -eq 2 ]'
    check "production keeps exactly one rollback (live + 1)" '[ "$(docker ps -a --filter label=algo3.app=nexwe-website --filter label=algo3.env=production -q | wc -l)" -eq 2 ]'
}

[[ $# -gt 0 ]] || set -- 1 2 3 4 5 6 7
for s in "$@"; do "step$s"; done
finish
