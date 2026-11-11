#!/usr/bin/env bash
# rehearse-platform-staging.sh — a STAGING studio-platform next to production,
# the staging products moved onto it, and the platform deployed by CI
# (KIND=stack), with the exact server commands. After rehearse-products.sh (the
# lab then has the edge, production's platform with biruno, biruno-staging,
# nexwe and nexwe-staging, and their apps deployed):
#
#   bash lab/rehearse-platform-staging.sh          all steps
#   bash lab/rehearse-platform-staging.sh 6 7      some
#
# What it proves:
#   - the edge joins the staging network with a measured blip, nothing else moves
#   - production's platform takes the new code with no container recreated
#     except Stalwart (it joins the staging network for staging's mail)
#   - two platforms on one host never answer for each other's names
#   - a staging product moves with its users, rows, files and keys intact,
#     and its app keeps working with only its network and files address changed
#   - CI deploys the platform: staging first, production only what staging ran,
#     a hand edit stops a deploy, a broken release puts the previous one back,
#     and production's sites never fail while staging changes
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

D=platform.lab.test
P=/opt/studio-platform
S=/opt/studio-platform-staging
REG=localhost:5000/studio-platform
BD=biruno.lab.test
fake_sha() { printf 'platform-release-%s' "$1" | sha1sum | cut -c1-40; }
A="$(fake_sha A)"; B="$(fake_sha B)"; C="$(fake_sha C)"
ci_deploy() {   # ci_deploy <env> <sha> [digest]: the workflow's deploy step, shared --any-app key
    as_root "printf 'app=studio-platform\n%s\n%s\n' $2 ${3:-} | sed '/^\$/d' | ssh -T -i /root/ci_any_$1 -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/ci_known_hosts algo3-deploy@127.0.0.1"
}
# ci_deploy's output is captured HERE (the runner's side), so these checks run here too.
hcheck() {
    if bash -c "$2" >/dev/null 2>&1; then pass=$((pass + 1)); printf '  [32mPASS[0m %s
' "$1"
    else failed=$((failed + 1)); printf '  [31mFAIL[0m %s
' "$1"; fi
}
digest_of() { as_root "docker image inspect --format '{{index .RepoDigests 0}}' $REG:$1 | cut -d@ -f2"; }
# Run in the lab: the platform containers that must survive an update, with their ids.
IDS="docker ps --format '{{.Names}} {{.ID}}' | grep -E '^studio-(postgres|seaweedfs|gotrue-[a-z-]+|mail-templates) ' | sort"

step0() {
    title "Step 0 · the lab's names (a restarted lab loses /etc/hosts)"
    as_root "grep -q 'files-staging.$D' /etc/hosts || echo '127.0.0.1 nexwe.app www.nexwe.app staging.nexwe.app hc.lab files.$D files-staging.$D mail.$D auth-demo.$D auth-demo-staging.$D $BD www.$BD staging.$BD auth-biruno.$D auth-biruno-staging.$D api.nexwe.app staging-api.nexwe.app' >> /etc/hosts"
    as_root 'for i in $(seq 1 60); do [ -z "$(docker ps --format "{{.Status}}" | grep -E "starting|unhealthy")" ] && break; sleep 3; done'
    check "nexwe.app serves" 'curl -fsS -o /dev/null https://nexwe.app/'
    check "production's platform is up (files.$D refuses unsigned: 403)" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$D/x/y)\" = 403 ]"
}

step1() {
    title "Step 1 · algo3-delivery update, and the edge joins studio-staging"
    run "rm -rf ~/stage/algo3-delivery && mkdir -p ~/stage && tar -C /lab --exclude=.git --exclude=lab/.work -czf - algo3-delivery | tar -xzf - -C ~/stage"
    run "sudo rm -rf /opt/algo3/delivery && sudo cp -a ~/stage/algo3-delivery /opt/algo3/delivery && sudo chown -R root:root /opt/algo3/delivery"
    note "(rsync: algo3-deploy-stack copies releases with it; Ubuntu servers usually have it)"
    run "command -v rsync >/dev/null || sudo apt-get install -y -qq rsync >/dev/null; rsync --version | head -1"
    run "sudo bash /opt/algo3/delivery/server/install.sh --app studio-platform | tail -3"
    run "sudo bash /opt/algo3/delivery/edge/install.sh | grep -E 'studio|installed|Done'"
    xprobe_start nexwe.app lab-x-edge
    run "sudo docker compose -p algo3-edge -f /opt/algo3/edge/compose.yml up -d 2>&1 | tail -2"
    as_root 'for i in $(seq 1 60); do [ "$(docker inspect -f "{{.State.Health.Status}}" studio-caddy)" = healthy ] && break; sleep 1; done'
    sleep 3
    read -r t b l <<<"$(xprobe_stop lab-x-edge)"
    note "nexwe.app while the edge was recreated: $t requests, $b failed, longest ${l}s"
    check "the stack deployer is installed" 'test -x /usr/local/libexec/algo3-deploy-stack'
    check "the edge is on studio AND studio-staging" "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' studio-caddy | grep -qw studio && docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' studio-caddy | grep -qw studio-staging"
    check "nexwe.app, biruno and auth-biruno still serve" "curl -fsS -o /dev/null https://nexwe.app/ && curl -fsS -o /dev/null https://$BD/ && curl -fsS https://auth-biruno.$D/.well-known/jwks.json | grep -q kty"
}

step2() {
    title "Step 2 · production's platform takes the new code by hand, one last time (deploy.md §9)"
    as_root "$IDS > /tmp/ids.before"
    run "rm -rf ~/stage/studio-platform && tar -C /lab --exclude=.git --exclude=node_modules --exclude=.env --exclude=scripts/s3-identities.json -czf - studio-platform | tar -xzf - -C ~/stage"
    run "sudo rsync -a --chown=root:root --exclude .env --exclude scripts/s3-identities.json --exclude identities.yml --exclude restore ~/stage/studio-platform/ $P/"
    note "(production's .env: Stalwart joins studio-staging for staging's mail)"
    run "sudo sed -i 's#^COMPOSE_FILE=.*#COMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml:compose.stalwart-staging.yml#' $P/.env"
    xprobe_start nexwe.app lab-x-prod
    run "cd $P && sudo docker compose up -d --build --wait --wait-timeout 300 2>&1 | grep -E 'Recreat|Started|Error' | tail -8"
    run "cd $P && sudo scripts/edge-sites.sh | tail -3"
    read -r t b l <<<"$(xprobe_stop lab-x-prod)"
    note "nexwe.app during production's update + one edge reload: $t requests, $b failed, longest ${l}s"
    as_root "$IDS > /tmp/ids.after"
    check "no postgres, seaweedfs, gotrue or mail-templates container was recreated" 'diff /tmp/ids.before /tmp/ids.after'
    check "Stalwart is on both networks, as mail.$D" "docker inspect -f '{{json .NetworkSettings.Networks}}' studio-stalwart | python3 -c 'import json,sys; n=json.load(sys.stdin); sys.exit(0 if \"mail.$D\" in (n[\"studio-staging\"][\"Aliases\"] or []) and \"studio\" in n else 1)'"
    check "the edge reaches services by container name" "grep -q 'reverse_proxy studio-seaweedfs:8333' /etc/algo3/caddy/platform/studio-platform.caddy && grep -q 'reverse_proxy studio-gotrue-biruno:9999' /etc/algo3/caddy/platform/studio-platform.caddy"
    check "files.$D 403 and auth-biruno-staging still serve" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$D/x/y)\" = 403 ] && curl -fsS https://auth-biruno-staging.$D/.well-known/jwks.json | grep -q kty"
}

step3() {
    title "Step 3 · the staging platform (deploy.md, 'Two platforms')"
    run "sudo rm -rf $S && sudo cp -a ~/stage/studio-platform $S && sudo chown -R root:root $S"
    run "sudo sh -c 'cd $S && cp .env.example .env && chmod 600 .env && node scripts/generate-jwt-keys.mjs >> .env && node scripts/generate-secrets.mjs >> .env 2>/dev/null'"
    # Production values, and the SAME mail account as production (one Stalwart).
    as_root "cd $S && python3 - <<'PY'
import re
prod = {}
for l in open('$P/.env'):
    m = re.match(r'^([A-Z0-9_]+)=(.*)$', l.rstrip('\n'))
    if m: prod[m.group(1)] = m.group(2)
vals = {
    'COMPOSE_FILE': 'docker-compose.yml:docker-compose.staging.yml',
    'COMPOSE_PROJECT_NAME': 'studio-platform-staging', 'STUDIO_INSTANCE': 'studio-staging',
    'STUDIO_NETWORK': 'studio-staging', 'STUDIO_FILES_HOST': 'files-staging.$D',
    'STUDIO_DOMAIN': '$D', 'COMPOSE_PROFILES': '',
    'GOTRUE_SITE_URL': 'https://atlas.$D', 'GOTRUE_URI_ALLOW_LIST': 'https://atlas.$D',
    'GOTRUE_SMTP_HOST': 'mail.$D', 'GOTRUE_SMTP_PORT': '465',
    'AI_MODEL': prod.get('AI_MODEL', 'lab/model'), 'AI_PROVIDER_API_KEY': prod.get('AI_PROVIDER_API_KEY', 'lab-dummy'),
}
for k in ('GOTRUE_SMTP_USER', 'GOTRUE_SMTP_PASS', 'GOTRUE_SMTP_ADMIN_EMAIL'):
    vals[k] = prod[k]
lines = [l.rstrip('\n') for l in open('.env')] + [f'{k}={v}' for k, v in vals.items()]
last = {}
for i, l in enumerate(lines):
    m = re.match(r'^([A-Z0-9_]+)=', l)
    if m: last[m.group(1)] = i
out = [l for i, l in enumerate(lines) if not (re.match(r'^([A-Z0-9_]+)=', l) and last[re.match(r'^([A-Z0-9_]+)=', l).group(1)] != i)]
open('.env', 'w').write('\n'.join(out) + '\n')
PY"
    check "staging runs exactly the core" "cd $S && [ \"\$(docker compose config --services | sort | tr '\n' ' ')\" = 'ai mail-templates postgres seaweedfs ' ]"
    xprobe_start nexwe.app lab-x-stg
    run "cd $S && sudo docker compose up -d --build --wait --wait-timeout 300 2>&1 | tail -3"
    run "cd $S && sudo scripts/harden-db.sh && sudo scripts/edge-sites.sh | tail -3"
    read -r t b l <<<"$(xprobe_stop lab-x-stg)"
    note "nexwe.app while the staging platform started: $t requests, $b failed, longest ${l}s"
    check "staging's containers carry its own names" "docker inspect studio-staging-postgres studio-staging-seaweedfs >/dev/null"
    check "on studio, 'postgres' is ONLY production's" "[ \"\$(docker run --rm --network studio busybox:1.37 nslookup postgres 2>/dev/null | grep -c '^Address: ')\" = 1 ] && docker run --rm --network studio busybox:1.37 nslookup postgres | grep -q \"\$(docker inspect -f '{{.NetworkSettings.Networks.studio.IPAddress}}' studio-postgres)\""
    check "on studio-staging, 'postgres' is ONLY staging's" "[ \"\$(docker run --rm --network studio-staging busybox:1.37 nslookup postgres 2>/dev/null | grep -c '^Address: ')\" = 1 ] && docker run --rm --network studio-staging busybox:1.37 nslookup postgres | grep -q \"\$(docker inspect -f '{{index .NetworkSettings.Networks \"studio-staging\" \"IPAddress\"}}' studio-staging-postgres)\""
    # The lab's Stalwart is not configured to accept mail (proven on the server
    # instead), so the lab proves the path: the same container, by the same
    # name, reached the same way as from production's network.
    check "on studio-staging, mail.$D IS production's Stalwart" "docker run --rm --network studio-staging busybox:1.37 nslookup mail.$D | grep -q \"\$(docker inspect -f '{{index .NetworkSettings.Networks \"studio-staging\" \"IPAddress\"}}' studio-stalwart)\""
    check "port 465 answers the same from both networks" "a=\$(docker run --rm --network studio busybox:1.37 nc -z -w 3 mail.$D 465 && echo open || echo closed); b=\$(docker run --rm --network studio-staging busybox:1.37 nc -z -w 3 mail.$D 465 && echo open || echo closed); [ \"\$a\" = \"\$b\" ]"
    check "files-staging.$D 403 through the edge; files.$D still 403" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files-staging.$D/x/y)\" = 403 ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$D/x/y)\" = 403 ]"
    check "staging has no mail. site of its own" "! grep -q '^mail\\.' /etc/algo3/caddy/platform/studio-staging-platform.caddy"
}

step4() {
    title "Step 4 · move biruno-staging and nexwe-staging, with their data"
    # Marker data on production's platform, as staging testers would leave it.
    run "cd $P && sudo node scripts/create-user.mjs biruno-staging tester@$BD 2>&1 | grep -v password | tail -1"
    as_root "docker exec studio-postgres psql -U postgres -d nexwe_staging -q -c 'create table if not exists lab_marker(n int); truncate lab_marker; insert into lab_marker select generate_series(1,7)'"
    as_root "cd $P && read -r k s < <(node -e 'const i=JSON.parse(require(\"fs\").readFileSync(\"scripts/s3-identities.json\")).identities.find(x=>x.name===\"nexwe-staging\").credentials[0]; console.log(i.accessKey, i.secretKey)')
             echo 'a photo from a staging chat' > /tmp/photo.txt
             docker run --rm --network studio -v /tmp/photo.txt:/photo.txt:ro curlimages/curl:8.11.1 -fsS --aws-sigv4 aws:amz:us-east-1:s3 --user \"\$k:\$s\" -T /photo.txt http://seaweedfs:8333/nexwe-staging-files/chat/photo.txt"
    note "(the staging apps stop: staging only, for the move)"
    run "sudo docker ps --format '{{.Names}}' | grep -E '^(nexwe|biruno)-staging-[0-9a-f]{12}\$' | xargs -r sudo docker stop | tail -2"
    run "cd $P && sudo scripts/move-product.sh nexwe-staging $S 2>&1 | tail -6"
    run "cd $P && sudo scripts/move-product.sh biruno-staging $S 2>&1 | tail -6"
    run "cd $P && sudo scripts/move-product.sh biruno-staging $S --finish 2>&1 | tail -4"
    check "nexwe_staging's rows came along (7)" "docker exec studio-staging-postgres psql -U postgres -d nexwe_staging -Atc 'select count(*) from lab_marker' | grep -qx 7"
    check "biruno-staging's tester came along" "docker exec studio-staging-postgres psql -U postgres -d auth_biruno_staging -Atc \"select count(*) from auth.users where email='tester@$BD'\" | grep -qx 1"
    check "the app's OWN database password works on staging's postgres" "u=\$(grep -E '^DATABASE_URL=' /etc/algo3/apps/nexwe/staging.env | cut -d= -f2-); docker exec studio-staging-postgres psql \"\${u/@postgres:/@localhost:}\" -Atc 'select current_user' | grep -qx nexwe_staging"
    check "the photo is readable on staging with the SAME S3 key" "cd $S && read -r k s < <(node -e 'const i=JSON.parse(require(\"fs\").readFileSync(\"scripts/s3-identities.json\")).identities.find(x=>x.name===\"nexwe-staging\").credentials[0]; console.log(i.accessKey, i.secretKey)'); docker run --rm --network studio-staging curlimages/curl:8.11.1 -fsS --aws-sigv4 aws:amz:us-east-1:s3 --user \"\$k:\$s\" http://seaweedfs:8333/nexwe-staging-files/chat/photo.txt | grep -q 'staging chat'"
    check "auth-biruno-staging is served by STAGING's GoTrue, same key as before" "grep -q 'reverse_proxy studio-staging-gotrue-biruno-staging:9999' /etc/algo3/caddy/platform/studio-staging-platform.caddy && ! grep -q 'auth-biruno-staging' /etc/algo3/caddy/platform/studio-platform.caddy && curl -fsS https://auth-biruno-staging.$D/.well-known/jwks.json | grep -q kty"
    check "production's GoTrue for biruno-staging is gone; biruno's stays" "! docker inspect studio-gotrue-biruno-staging >/dev/null 2>&1 && curl -fsS https://auth-biruno.$D/.well-known/jwks.json | grep -q kty"
    check "a second move is refused (nothing overwritten)" "cd $P && ! scripts/move-product.sh nexwe-staging $S 2>&1 && scripts/move-product.sh nexwe-staging $S 2>&1 | grep -q 'already exists'"
}

step5() {
    title "Step 5 · the staging apps move to studio-staging"
    # nexwe reaches storage by the PUBLIC address on the server (S3_ENDPOINT=
    # https://files.<domain>; the lab's uses the internal name, so this is a
    # no-op here). biruno uses http://seaweedfs:8333: the network change is enough.
    run "sudo sed -i 's#^S3_ENDPOINT=https://files\\.$D\$#S3_ENDPOINT=https://files-staging.$D#' /etc/algo3/apps/nexwe/staging.env"
    note "(on the server: sudo bash /opt/algo3/delivery/server/install.sh --app nexwe, then --app biruno."
    note " The lab writes the same files with its registry and domain names, as rehearse-products.sh does.)"
    as_root "for e in staging production; do
        sed -e 's#^IMAGE=.*#IMAGE=localhost:5000/biruno-ai#' -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/biruno/\$e.conf > /etc/algo3/apps/biruno/\$e.conf
        sed -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/biruno/\$e.caddy.tmpl > /etc/algo3/apps/biruno/\$e.caddy.tmpl
        sed -e 's#^IMAGE=.*#IMAGE=localhost:5000/nexwe-api#' /lab/algo3-delivery/server/apps/nexwe/\$e.conf > /etc/algo3/apps/nexwe/\$e.conf
        sed -i 's/^HEALTH_ATTEMPTS=.*//' /etc/algo3/apps/*/\$e.conf
      done"
    check "the staging apps are registered on studio-staging" "grep -qx NETWORKS=studio-staging /etc/algo3/apps/nexwe/staging.conf && grep -qx NETWORKS=studio-staging /etc/algo3/apps/biruno/staging.conf"
    as_root "docker ps --format '{{.Names}} {{.ID}}' | grep -E -- '-production-' | sort > /tmp/prodapps.before"
    local app live sha
    for app in nexwe biruno; do
        live="$(as_root "cat /var/lib/algo3/$app/staging.live")"
        sha="$(as_root "docker inspect -f '{{index .Config.Labels \"algo3.release\"}}' $live")"
        note "($app staging: recreated from release ${sha:0:12} on the new network)"
        run "sudo docker rm -f $live >/dev/null && sudo /usr/local/libexec/algo3-deploy deploy $app staging $sha 2>&1 | tail -2"
    done
    check "staging-api.nexwe.app answers /health" 'curl -fsS https://staging-api.nexwe.app/health | grep -q version'
    check "staging.$BD answers" "curl -fsS -o /dev/null https://staging.$BD/"
    check "both staging apps are on studio-staging only" "for a in nexwe biruno; do n=\$(docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' \"\$(cat /var/lib/algo3/\$a/staging.live)\"); [ \"\$n\" = 'studio-staging ' ] || exit 1; done"
    as_root "docker ps --format '{{.Names}} {{.ID}}' | grep -E -- '-production-' | sort > /tmp/prodapps.after"
    check "no production app container changed" 'diff /tmp/prodapps.before /tmp/prodapps.after'
}

step6() {
    title "Step 6 · CI deploys the platform (KIND=stack)"
    note "(CI's job: bundle images. A = the code installed now, B = a change, C = broken)"
    as_root "rm -rf /root/bundle && cp -a ~algo3/stage/studio-platform /root/bundle"
    as_root "cd /root/bundle && docker build -q -f Dockerfile.bundle -t $REG:$A . >/dev/null && docker push -q $REG:$A >/dev/null
             echo '# release B: a comment' >> docker-compose.yml && docker build -q -f Dockerfile.bundle -t $REG:$B . >/dev/null && docker push -q $REG:$B >/dev/null
             sed -i 's#image: caddy:2.8.4-alpine#image: caddy:0.0.0-no-such-tag#' docker-compose.yml && docker build -q -f Dockerfile.bundle -t $REG:$C . >/dev/null && docker push -q $REG:$C >/dev/null"
    check "the bundle carries no secrets" "id=\$(docker create $REG:$A); docker cp \$id:/bundle /tmp/bundle-a >/dev/null; docker rm \$id >/dev/null; ! test -e /tmp/bundle-a/.env && ! test -e /tmp/bundle-a/scripts/s3-identities.json && ! test -e /tmp/bundle-a/.git"
    as_root "sed -i 's#^IMAGE=.*#IMAGE=$REG#' /etc/algo3/apps/studio-platform/*.conf"
    note "(the shared deploy keys, as on the server: --any-app staging / production)"
    as_root 'for env in staging production; do [ -f /root/ci_any_$env ] || ssh-keygen -q -t ed25519 -N "" -C ci-any-$env -f /root/ci_any_$env; done
             ssh-keyscan -t ed25519 127.0.0.1 2>/dev/null > /root/ci_known_hosts
             install -d -o algo3-deploy -g algo3-deploy -m 700 /home/algo3-deploy/.ssh
             { for env in staging production; do printf "restrict,command=\"/usr/local/sbin/algo3-deploy-ssh --any-app %s\" %s\n" $env "$(cat /root/ci_any_$env.pub)"; done; } > /home/algo3-deploy/.ssh/authorized_keys
             chown algo3-deploy: /home/algo3-deploy/.ssh/authorized_keys; chmod 600 /home/algo3-deploy/.ssh/authorized_keys
             grep -q "AllowUsers.*algo3-deploy" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null || { printf "AllowUsers algo3-deploy\n" > /etc/ssh/sshd_config.d/10-algo3.conf; systemctl reload ssh; }'
    run "sudo /usr/local/libexec/algo3-deploy-stack adopt studio-platform staging $A 2>&1 | tail -1"
    run "sudo /usr/local/libexec/algo3-deploy-stack adopt studio-platform production $A 2>&1 | tail -1"
    local dB dC; dB="$(digest_of "$B")"; dC="$(digest_of "$C")"
    ci_deploy production "$B" "$dB" > /tmp/out.prod-early 2>&1
    hcheck "production refused B: never verified on staging" "grep -q 'never verified live on staging' /tmp/out.prod-early"
    sed 's/^/      /' /tmp/out.prod-early | tail -2
    xprobe_start nexwe.app lab-x-ci1
    as_root "docker rm -f lab-x-files >/dev/null 2>&1; docker run -d --name lab-x-files --network studio curlimages/curl:8.11.1 sh -c 'while true; do printf \"%s \" \$(date +%s.%N | cut -c1-14); curl -s -o /dev/null -w \"%{http_code}\n\" --max-time 1 http://seaweedfs:8333/ | sed s/403/200/; sleep 0.1; done' >/dev/null"
    ci_deploy staging "$B" "$dB" | tail -3
    read -r t b l <<<"$(xprobe_stop lab-x-ci1)"
    read -r ft fb _ <<<"$(as_root 'docker logs lab-x-files; docker rm -f lab-x-files >/dev/null' | probe_stats)"
    note "during the staging deploy: nexwe.app $t requests, $b failed; production storage $ft requests, $fb failed"
    check "staging runs B" "grep -q 'release B' $S/docker-compose.yml && grep -q $B /var/lib/algo3/studio-platform/staging.current"
    check "production is still A" "! grep -q 'release B' $P/docker-compose.yml"
    check "production never failed during the staging deploy" "[ '$b' = 0 ] && [ '$fb' = 0 ]"
    as_root "$IDS > /tmp/ids.before"
    xprobe_start nexwe.app lab-x-ci2
    ci_deploy production "$B" "$dB" | tail -3
    read -r t b l <<<"$(xprobe_stop lab-x-ci2)"
    note "during the production deploy: nexwe.app $t requests, $b failed, longest ${l}s"
    as_root "$IDS > /tmp/ids.after"
    check "production runs B, promoted by digest" "grep -q 'release B' $P/docker-compose.yml && grep -q \"$B $dB\" /var/lib/algo3/studio-platform/production.current"
    check "a change that touches no service recreates nothing" 'diff /tmp/ids.before /tmp/ids.after'
    note "(a hand edit on staging, then a deploy)"
    as_root "echo '# edited by hand' >> $S/docker-compose.yml"
    ci_deploy staging "$C" "$dC" > /tmp/out.drift 2>&1
    hcheck "the deploy is refused and names the file" "grep -q '^  docker-compose.yml' /tmp/out.drift && grep -q 'Commit them to the repo' /tmp/out.drift"
    check "nothing changed on staging" "grep -q '# edited by hand' $S/docker-compose.yml && grep -q $B /var/lib/algo3/studio-platform/staging.current"
    as_root "sed -i '/# edited by hand/d' $S/docker-compose.yml"
    note "(a broken release: one of its images does not exist)"
    ci_deploy staging "$C" "$dC" > /tmp/out.broken 2>&1
    sed 's/^/      /' /tmp/out.broken | grep -E 'restoring|running again|did not' | tail -3
    check "the broken release failed and B is back" "grep -q $B /var/lib/algo3/studio-platform/staging.current && grep -q 'release B' $S/docker-compose.yml && ! grep -q no-such-tag $S/docker-compose.yml"
    check "every staging service is running again" "cd $S && [ \"\$(docker compose ps -a --format '{{.Service}} {{.State}}' | grep -vc ' running\$')\" = 0 ]"
    check "the failure is recorded" "grep -q 'app=studio-platform env=staging result=rolled-back release=$C' /var/log/algo3/deploys.log"
    check "staging's secrets were never touched" "grep -q '^STUDIO_INSTANCE=studio-staging' $S/.env && grep -q nexwe-staging $S/scripts/s3-identities.json"
}

step7() {
    title "Step 7 · everything the edge served still serves"
    check "nexwe.app" 'curl -fsS -o /dev/null https://nexwe.app/'
    check "biruno production" "curl -fsS -o /dev/null https://$BD/"
    check "auth-biruno (production's GoTrue)" "curl -fsS https://auth-biruno.$D/.well-known/jwks.json | grep -q kty"
    check "api.nexwe.app (production API)" 'curl -fsS https://api.nexwe.app/health | grep -q version'
    check "staging-api.nexwe.app (on the staging platform)" 'curl -fsS https://staging-api.nexwe.app/health | grep -q version'
    check "files.$D and files-staging.$D both 403" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$D/x/y)\" = 403 ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files-staging.$D/x/y)\" = 403 ]"
}

step8() {
    title "Step 8 · drop the old staging copies from production's platform (move-product.sh --drop-source)"
    note "(the platform's new move-product.sh, as CI would bring it)"
    as_root "install -m 0755 /lab/studio-platform/scripts/move-product.sh $P/scripts/move-product.sh"
    local all_b staging_b
    read -r all_b staging_b < <(as_root "echo \$(grep -c '^BIRUNO_[A-Z0-9_]*=' $P/.env) \$(grep -c '^BIRUNO_STAGING_' $P/.env)")
    check "refused for a product that was never moved (demo-staging)" "cd $P && ! scripts/move-product.sh demo-staging $S --drop-source 2>/tmp/out.d && grep -q 'move it first' /tmp/out.d && docker exec studio-postgres psql -U postgres -Atc \"select 1 from pg_database where datname='demo_staging'\" | grep -qx 1"
    as_root "docker run -d --rm --name lab-holder --network studio postgres:17-alpine sleep 600 >/dev/null; docker exec -d lab-holder sh -c \"PGPASSWORD=\$(grep -E '^POSTGRES_PASSWORD=' $P/.env | tail -1 | cut -d= -f2-) psql -h postgres -U postgres -d nexwe_staging -c 'select pg_sleep(60)'\"
             for _ in \$(seq 1 30); do [ \"\$(docker exec studio-postgres psql -U postgres -Atc \"select count(*) from pg_stat_activity where datname='nexwe_staging'\")\" -ge 1 ] && break; sleep 1; done"
    check "refused while something is connected to the old database" "cd $P && ! scripts/move-product.sh nexwe-staging $S --drop-source 2>/tmp/out.c && grep -q 'connection' /tmp/out.c"
    # The server side of that query outlives its client: end it, as an app's stop would.
    as_root "docker rm -f lab-holder >/dev/null; docker exec studio-postgres psql -U postgres -Atqc \"select pg_terminate_backend(pid) from pg_stat_activity where datname='nexwe_staging'\" >/dev/null"
    run "cd $P && sudo scripts/move-product.sh nexwe-staging $S --drop-source 2>&1 | tail -6"
    run "cd $P && sudo scripts/move-product.sh biruno-staging $S --drop-source 2>&1 | tail -6"
    local d
    for d in nexwe_staging biruno_staging auth_biruno_staging; do
        check "$d gone from production, still on staging" "! docker exec studio-postgres psql -U postgres -Atc \"select 1 from pg_database where datname='$d'\" | grep -q 1 && docker exec studio-staging-postgres psql -U postgres -Atc \"select 1 from pg_database where datname='$d'\" | grep -qx 1"
    done
    check "their roles gone from production" "! docker exec studio-postgres psql -U postgres -Atc \"select rolname from pg_roles where rolname in ('nexwe_staging','biruno_staging','gotrue_biruno_staging')\" | grep -q ."
    check "biruno's own databases untouched" "docker exec studio-postgres psql -U postgres -Atc \"select count(*) from pg_database where datname in ('biruno','auth_biruno')\" | grep -qx 2"
    check "buckets gone from production, still on staging" "cd $P && ! docker compose exec -T seaweedfs sh -c 'echo s3.bucket.list | weed shell' 2>/dev/null | grep -qE '(nexwe|biruno)-staging-files' && cd $S && [ \"\$(docker compose exec -T seaweedfs sh -c 'echo s3.bucket.list | weed shell' 2>/dev/null | grep -cE '(nexwe|biruno)-staging-files')\" = 2 ]"
    check "S3 identities gone from production only" "! grep -qE '\"(nexwe|biruno)-staging\"' $P/scripts/s3-identities.json && grep -q '\"nexwe-staging\"' $S/scripts/s3-identities.json && grep -q '\"biruno\"' $P/scripts/s3-identities.json"
    check "production .env: staging lines, tokens, issuers gone; biruno's own $((all_b - staging_b)) kept" "! grep -qE '^(BIRUNO|NEXWE)_STAGING_' $P/.env && ! grep -qE '(=|,)(nexwe|biruno)-staging[:|]' $P/.env && [ \"\$(grep -c '^BIRUNO_[A-Z0-9_]*=' $P/.env)\" = $((all_b - staging_b)) ] && grep -qE '(=|,)biruno:' $P/.env"
    check "mail templates moved out of production into the backup" "! test -e $P/mail-templates/biruno-staging && ls -d /root/biruno-staging-moved-*/mail-templates >/dev/null && test -d $S/mail-templates/biruno-staging"
    check "backups readable: every dump lists, files saved" "for f in /root/nexwe-staging-moved-*/nexwe_staging.dump /root/biruno-staging-moved-*/biruno_staging.dump /root/biruno-staging-moved-*/auth_biruno_staging.dump; do docker exec -i studio-postgres pg_restore --list < \$f >/dev/null || exit 1; done; [ \"\$(find /root/nexwe-staging-moved-*/files -type f | wc -l)\" -ge 1 ]"
    check "the photo is still readable on staging" "cd $S && read -r k s < <(node -e 'const i=JSON.parse(require(\"fs\").readFileSync(\"scripts/s3-identities.json\")).identities.find(x=>x.name===\"nexwe-staging\").credentials[0]; console.log(i.accessKey, i.secretKey)'); docker run --rm --network studio-staging curlimages/curl:8.11.1 -fsS --aws-sigv4 aws:amz:us-east-1:s3 --user \"\$k:\$s\" http://seaweedfs:8333/nexwe-staging-files/chat/photo.txt | grep -q 'staging chat'"
    check "a second run is refused (nothing to drop)" "cd $P && ! scripts/move-product.sh nexwe-staging $S --drop-source 2>/tmp/out.e && grep -q 'already dropped' /tmp/out.e"
    check "every production platform service is running" "cd $P && [ \"\$(docker compose ps -a --format '{{.Service}} {{.State}}' | grep -vc ' running\$')\" = 0 ]"
    step7
}

[[ $# -gt 0 ]] || set -- 0 1 2 3 4 5 6 7 8
for s in "$@"; do "step$s"; done
finish
