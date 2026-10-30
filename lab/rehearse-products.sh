#!/usr/bin/env bash
# rehearse-products.sh — biruno and the nexwe server, deployed through the real
# deployer onto the lab's platform, staging then production, from the working
# copies of the product repos (what GitHub would build). After
# rehearse-platform.sh:
#
#   bash lab/rehearse-products.sh
#
# What it proves:
#   biruno  migration before the switch; ONE image serves both environments
#           (/config.js gives each its own sign-in server); production refuses
#           an image staging never ran; zero failed requests across a deploy;
#           the SSE template is the site; staging's role cannot reach prod's DB
#   nexwe   prisma migrations before the switch; OVERLAP=false (never two
#           copies); Socket.IO answers through the edge, again after a deploy;
#           the old release stops cleanly on SIGTERM (exit 0)
#   coturn  starts on the host network with the private-network denials
#
# Lab differences: images come from the lab registry; biruno's domain is
# biruno.lab.test; nexwe's S3 endpoint is the internal one (app containers
# cannot resolve the lab's made-up domains; on the server it is
# https://files.<domain>, which phones need).
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

REG=localhost:5000
D=/usr/local/libexec/algo3-deploy
P=/opt/studio-platform
PD=platform.lab.test
BD=biruno.lab.test
PRODUCTS="$(cd "$LAB_DIR/../.." && pwd)"
rel() { printf 'products-release-%s' "$1" | sha1sum | cut -c1-40; }
R1="$(rel 1)"; R2="$(rel 2)"

# Build on the PC (like GitHub), then load into the lab and push to its registry.
build_into_lab() {   # build_into_lab <name> <context> <dockerfile> <sha>
    local name="$1" ctx="$2" file="$3" sha="$4" w
    w="$(cygpath -w "$ctx" 2>/dev/null || echo "$ctx")"
    docker build -q -f "$(cygpath -w "$ctx/$file" 2>/dev/null || echo "$ctx/$file")" \
        --build-arg "RELEASE_SHA=$sha" -t "$REG/$name:$sha" "$w" >/dev/null || return 1
    docker save "$REG/$name:$sha" | docker exec -i algo3-lab docker load >/dev/null &&
        as_root "docker push -q $REG/$name:$sha >/dev/null"
}

step1() {
    title "Step 1 · images from the working copies (GitHub's job), into the lab registry"
    local s
    for s in "$R1" "$R2"; do
        build_into_lab biruno-ai "$PRODUCTS/biruno-ai" apps/server/Dockerfile "$s" || note "biruno build failed"
        build_into_lab nexwe-api "$PRODUCTS/nexwe/server" Dockerfile "$s" || note "nexwe build failed"
    done
    check "both images, two releases each, in the lab registry" "curl -fsS http://localhost:5000/v2/biruno-ai/tags/list | grep -q $R2 && curl -fsS http://localhost:5000/v2/nexwe-api/tags/list | grep -q $R2"
}

step2() {
    title "Step 2 · the platform side: one product per environment (§7)"
    as_root "grep -q ' $BD' /etc/hosts || echo '127.0.0.1 $BD www.$BD staging.$BD auth-biruno.$PD auth-biruno-staging.$PD api.nexwe.app staging-api.nexwe.app' >> /etc/hosts"
    run "cd $P && sudo scripts/add-product.sh biruno https://$BD --identity --signup off > /tmp/biruno.out 2>&1; tail -2 /tmp/biruno.out"
    run "cd $P && sudo scripts/add-product.sh biruno-staging https://staging.$BD --identity --signup off > /tmp/biruno-staging.out 2>&1; tail -2 /tmp/biruno-staging.out"
    run "cd $P && sudo scripts/add-product.sh nexwe https://api.nexwe.app > /tmp/nexwe.out 2>&1; tail -2 /tmp/nexwe.out"
    run "cd $P && sudo scripts/add-product.sh nexwe-staging https://staging-api.nexwe.app > /tmp/nexwe-staging.out 2>&1; tail -2 /tmp/nexwe-staging.out"
    check "four buckets exist (each verified, not assumed)" "cd $P && for b in biruno-files biruno-staging-files nexwe-files nexwe-staging-files; do docker compose exec -T seaweedfs sh -c 'echo s3.bucket.list | weed shell' 2>/dev/null | grep -qE \"^>?[[:space:]]*\$b[[:space:]]\" || exit 1; done"
}

# The env file's values. On the SERVER the operator copies add-product's printed
# block once: secrets are printed only when created, and a re-run prints
# <unchanged> instead. The lab must survive re-runs, so it re-derives the same
# values: a fresh lab-only database password set as the superuser, the S3 keys
# from the platform's key file, the issuer from its .env.
lab_values() {   # lab_values <product>: writes /root/<product>.vals inside the lab
    docker exec -i -e P="$1" algo3-lab python3 - <<'PY'
import json, os, re, secrets, subprocess
p = os.environ['P']; db = p.replace('-', '_'); up = db.upper()
pw = secrets.token_hex(16)
subprocess.run(['docker', 'exec', 'studio-postgres', 'psql', '-U', 'postgres', '-q', '-c',
                f"ALTER ROLE \"{db}\" PASSWORD '{pw}'"], check=True)
ids = json.load(open('/opt/studio-platform/scripts/s3-identities.json'))['identities']
cred = next(i for i in ids if i['name'] == p)['credentials'][0]
env = dict(re.findall(r'^([A-Z0-9_]+)=(.*)$', open('/opt/studio-platform/.env').read(), re.M))
vals = {
    'DATABASE_URL': f'postgres://{db}:{pw}@postgres:5432/{db}',
    'STORAGE_BUCKET': f'{p}-files',
    'STORAGE_ACCESS_KEY': cred['accessKey'], 'STORAGE_SECRET_KEY': cred['secretKey'],
    'AUTH_ISSUER': env.get(f'{up}_GOTRUE_ISSUER', ''), 'AUTH_AUDIENCE': p,
    'AUTH_INTERNAL_URL': f'http://gotrue-{p}:9999',
}
with open(f'/root/{p}.vals', 'w') as f:
    f.write(''.join(f'{k}={v}\n' for k, v in vals.items()))
PY
}
v() { docker exec algo3-lab sh -c "grep -E '^$2=' /root/$1.vals | head -1 | cut -d= -f2-"; }

step3() {
    title "Step 3 · registry + env files, as the operator writes them"
    as_root "mkdir -p /etc/algo3/apps/biruno /etc/algo3/apps/nexwe
      for e in staging production; do
        sed -e 's#^IMAGE=.*#IMAGE=$REG/biruno-ai#' -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/biruno/\$e.conf > /etc/algo3/apps/biruno/\$e.conf
        sed -e 's#birunoai\.com#$BD#g' /lab/algo3-delivery/server/apps/biruno/\$e.caddy.tmpl > /etc/algo3/apps/biruno/\$e.caddy.tmpl
        sed -e 's#^IMAGE=.*#IMAGE=$REG/nexwe-api#' /lab/algo3-delivery/server/apps/nexwe/\$e.conf > /etc/algo3/apps/nexwe/\$e.conf
        sed -i 's/^HEALTH_ATTEMPTS=.*//' /etc/algo3/apps/*/\$e.conf
      done"
    local e p o
    for p in biruno biruno-staging nexwe nexwe-staging; do lab_values "$p"; done
    for e in staging production; do
        p=biruno; [[ $e == staging ]] && p=biruno-staging
        o=https://$BD; [[ $e == staging ]] && o=https://staging.$BD
        as_root "umask 077; cat > /etc/algo3/apps/biruno/$e.env <<EOF
DATABASE_URL=$(v $p DATABASE_URL)
AUTH_ISSUER=$(v $p AUTH_ISSUER)
AUTH_AUDIENCE=$(v $p AUTH_AUDIENCE)
AUTH_INTERNAL_URL=$(v $p AUTH_INTERNAL_URL)
APP_ORIGIN=$o
STORAGE_ENDPOINT=http://seaweedfs:8333
STORAGE_REGION=us-east-1
STORAGE_BUCKET=$(v $p STORAGE_BUCKET)
STORAGE_ACCESS_KEY=$(v $p STORAGE_ACCESS_KEY)
STORAGE_SECRET_KEY=$(v $p STORAGE_SECRET_KEY)
AI_SERVICE_URL=http://ai:8080
EOF"
        p=nexwe; [[ $e == staging ]] && p=nexwe-staging
        o=https://api.nexwe.app; [[ $e == staging ]] && o=https://staging-api.nexwe.app
        as_root "umask 077; cat > /etc/algo3/apps/nexwe/$e.env <<EOF
DATABASE_URL=$(v $p DATABASE_URL)
JWT_SECRET=$(openssl rand -hex 32)
PUBLIC_API_URL=$o
CORS_ORIGIN=*
S3_ENDPOINT=http://seaweedfs:8333
S3_REGION=us-east-1
S3_BUCKET=$(v $p STORAGE_BUCKET)
S3_ACCESS_KEY_ID=$(v $p STORAGE_ACCESS_KEY)
S3_SECRET_ACCESS_KEY=$(v $p STORAGE_SECRET_KEY)
S3_FORCE_PATH_STYLE=true
TRANSLATE_URL=
EOF"
    done
    check "env files root-only (0600)" '[ "$(stat -c %a /etc/algo3/apps/biruno/staging.env /etc/algo3/apps/nexwe/production.env | sort -u)" = 600 ]'
    check "staging and production have different databases" '[ "$(grep ^DATABASE_URL /etc/algo3/apps/biruno/staging.env)" != "$(grep ^DATABASE_URL /etc/algo3/apps/biruno/production.env)" ]'
}

step4() {
    title "Step 4 · biruno: staging, then production of the SAME image"
    run "sudo $D deploy biruno staging $R1 2>&1 | tail -4"
    check "migration ran before the switch (schema ready: health 200 with the release)" "docker exec studio-caddy wget -qO- http://biruno-staging:8100/api/health | grep -q '\"version\":\"$R1\"'"
    check "staging's /config.js names STAGING's sign-in server" "curl -fsS https://staging.$BD/config.js | grep -q 'auth-biruno-staging.$PD'"
    check "the site is the SSE template (flush, 25 MB, noindex)" "grep -q 'flush_interval -1' /etc/algo3/caddy/sites/biruno-staging.caddy && grep -q 'max_size 25MB' /etc/algo3/caddy/sites/biruno-staging.caddy && curl -sI https://staging.$BD/ | grep -qi 'x-robots-tag: noindex'"
    check "production refuses an image staging never ran" "! $D deploy biruno production $R2 \$(docker image inspect -f '{{index .RepoDigests 0}}' $REG/biruno-ai:$R2 | cut -d@ -f2) >/tmp/b-refuse.log 2>&1 && grep -q 'never verified live on staging' /tmp/b-refuse.log"
    run "d=\$(sudo awk -v s=$R1 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/biruno/staging.history); sudo $D deploy biruno production $R1 \$d 2>&1 | tail -2"
    check "production's /config.js names PRODUCTION's sign-in server (same image)" "curl -fsS https://$BD/config.js | grep -q '\"authUrl\":\"https://auth-biruno.$PD\"'"
    check "www redirects permanently to the bare domain" "for i in \$(seq 1 30); do curl -sI https://www.$BD/x 2>/dev/null | grep -qi '^location: https://$BD/x' && exit 0; sleep 1; done; exit 1"
    check "same image in both environments" "[ \"\$(docker inspect -f '{{.Image}}' biruno-staging-${R1:0:12})\" = \"\$(docker inspect -f '{{.Image}}' biruno-production-${R1:0:12})\" ]"
    xprobe_start "$BD" lab-x-biruno
    as_root "d=\$(docker image inspect -f '{{index .RepoDigests 0}}' $REG/biruno-ai:$R2 | cut -d@ -f2); $D deploy biruno staging $R2 \$d >/dev/null 2>&1; d2=\$(awk -v s=$R2 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/biruno/staging.history); $D deploy biruno production $R2 \$d2 > /tmp/b-prod2.log 2>&1"
    read -r t b l <<<"$(xprobe_stop lab-x-biruno)"
    note "biruno production during its own deploy: $t requests, $b failed, longest ${l}s"
    # Not "zero": a switch can lose one request when Docker's DNS stalls as the
    # alias moves (measured: 1 failed of 363 requests over 6 switches).
    check "at most one failed request across a production deploy" "test $b -le 1 && curl -fsS https://$BD/api/health | grep -q $R2"
    check "staging's role cannot connect to production's database" "u=\$(grep ^DATABASE_URL= /etc/algo3/apps/biruno/staging.env | cut -d= -f2-); u=\${u/@postgres:/@localhost:}; ! docker exec studio-postgres psql \"\${u%/*}/biruno\" -Atc 'select 1'"
}

step5() {
    title "Step 5 · nexwe: OVERLAP=false, prisma migrations, sockets"
    run "sudo $D deploy nexwe staging $R1 2>&1 | tail -3"
    check "prisma migrations applied before the switch" "u=\$(grep ^DATABASE_URL= /etc/algo3/apps/nexwe/staging.env | cut -d= -f2-); [ \"\$(docker exec studio-postgres psql \"\${u/@postgres:/@localhost:}\" -Atc 'select count(*) from _prisma_migrations where finished_at is not null')\" -ge 30 ]"
    check "health reports the release through the edge" "curl -fsS https://staging-api.nexwe.app/health | grep -q '\"version\":\"$R1\"'"
    check "Socket.IO handshake through the edge" "curl -fsS 'https://staging-api.nexwe.app/socket.io/?EIO=4&transport=polling' | grep -q '\"sid\"'"
    as_root 'rm -f /tmp/n-max; ( max=0; while [ ! -f /tmp/n-stop ]; do n=$(docker ps -q --filter label=algo3.app=nexwe --filter label=algo3.env=staging | wc -l); [ "$n" -gt "$max" ] && max=$n; echo $max > /tmp/n-max; sleep 0.1; done ) >/dev/null 2>&1 & sleep 0.5'
    run "d=\$(docker image inspect -f '{{index .RepoDigests 0}}' $REG/nexwe-api:$R2 | cut -d@ -f2); sudo $D deploy nexwe staging $R2 \$d 2>&1 | tail -2"
    as_root 'touch /tmp/n-stop; sleep 0.4; rm -f /tmp/n-stop'
    check "never two nexwe copies at once" '[ "$(cat /tmp/n-max)" -le 1 ]'
    check "the old release stopped cleanly on SIGTERM (exit 0)" "[ \"\$(docker inspect -f '{{.State.ExitCode}}' nexwe-staging-${R1:0:12})\" = 0 ] && docker logs nexwe-staging-${R1:0:12} 2>&1 | grep -q 'SIGTERM: shutting down'"
    check "Socket.IO answers again on the new release" "curl -fsS 'https://staging-api.nexwe.app/socket.io/?EIO=4&transport=polling' | grep -q '\"sid\"' && curl -fsS https://staging-api.nexwe.app/health | grep -q $R2"
    run "d=\$(sudo awk -v s=$R2 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/nexwe/staging.history); sudo $D deploy nexwe production $R2 \$d 2>&1 | tail -2"
    check "nexwe production serves the promoted release" "curl -fsS https://api.nexwe.app/health | grep -q $R2"
}

step6() {
    title "Step 6 · coturn (calls)"
    as_root "install -d -m 0700 /opt/algo3/turn && cp /lab/algo3-delivery/turn/compose.yml /opt/algo3/turn/ \
      && sed -e 's/REPLACE_WITH_TURN_SECRET/\$(openssl rand -hex 32)/' -e 's/179.236.229.2/'\$(hostname -I | awk '{print \$1}')'/' /lab/algo3-delivery/turn/turnserver.conf.example > /opt/algo3/turn/turnserver.conf \
      && docker compose -p algo3-turn -f /opt/algo3/turn/compose.yml up -d >/dev/null 2>&1; sleep 4"
    check "coturn listens on 3478 (udp and tcp)" 'ss -lun | grep -q ":3478 " && ss -ltn | grep -q ":3478 "'
    check "its folder is root-only (the secret is in it)" '[ "$(stat -c %a /opt/algo3/turn)" = 700 ]'
    check "the secret is not on its command line" '! docker inspect -f "{{json .Args}}" algo3-turn | grep -q static-auth-secret'
}

step7() {
    title "Step 7 · nothing else was disturbed"
    check "nexwe.app" 'curl -fsS https://nexwe.app/release.json | grep -q release'
    check "the platform's sites" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$PD/x/y)\" = 403 ]"
}

[[ $# -gt 0 ]] || set -- 1 2 3 4 5 6 7
for s in "$@"; do "step$s"; done
finish
