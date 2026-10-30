#!/usr/bin/env bash
# rehearse-platform.sh — studio-platform's core on the "server", next to the
# edge, with studio-platform/docs/deploy.md's exact commands, run as algo3.
# After rehearse-phase3.sh (the edge owns 80/443):
#
#   bash lab/up.sh && bash lab/rehearse-phase2.sh 0 1 2 3 5 6 && bash lab/rehearse-phase3.sh
#   bash lab/rehearse-platform.sh
#
# What it proves, beyond "it starts":
#   - only the core runs on a small server (no ocr/clamav/translate/atlas, no Caddy)
#   - the platform's sites go live through the EDGE, validated first, and a
#     second run changes nothing (no reload)
#   - a domain a deployed app already owns is refused
#   - staging and production of one product are isolated: database, files,
#     and login service (own key, issuer, audience)
#   - a backup is restored into a scratch database closed to other roles,
#     with the same rows
#   - the websites the edge already serves keep serving
#
# Lab differences: the off-site bucket is a second SeaweedFS (lab-offsite) on
# the studio network; certificates come from the edge's local CA; Stalwart
# starts but cannot deliver mail out of the lab (proven on the server).
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

D=platform.lab.test
P=/opt/studio-platform

step1() {
    title "Step 1 · code and prerequisites (docs/deploy.md §1, §3)"
    run "rm -rf ~/stage/studio-platform && mkdir -p ~/stage && tar -C /lab --exclude=.git --exclude=node_modules --exclude=.env --exclude=scripts/s3-identities.json -czf - studio-platform | tar -xzf - -C ~/stage"
    run "sudo rm -rf $P && sudo cp -a ~/stage/studio-platform $P && sudo chown -R root:root $P"
    run "sudo apt-get update -qq && sudo apt-get install -y -qq nodejs >/dev/null && node --version"
    as_root "grep -q '$D' /etc/hosts || echo '127.0.0.1 files.$D mail.$D auth-demo.$D auth-demo-staging.$D' >> /etc/hosts"
    check "code in $P, root-owned" "test \"\$(stat -c %U $P/docker-compose.yml)\" = root"
    check "node available" 'command -v node'
}

step2() {
    title "Step 2 · secrets (§4) — the lab fills what you will type"
    as_root "cd $P && cp .env.example .env && chmod 600 .env \
        && node scripts/generate-jwt-keys.mjs >> .env && node scripts/generate-secrets.mjs >> .env 2>/dev/null"
    # Production values, then keep the LAST line of each key (the generated
    # values come after the example's dev defaults).
    as_root "cd $P && python3 - <<'PY'
import re
vals = {
    'COMPOSE_FILE': 'docker-compose.yml:docker-compose.prod.yml',
    'STUDIO_DOMAIN': '$D', 'COMPOSE_PROFILES': '',
    'GOTRUE_SITE_URL': 'https://atlas.$D', 'GOTRUE_URI_ALLOW_LIST': 'https://atlas.$D',
    'GOTRUE_SMTP_HOST': 'mail.$D', 'GOTRUE_SMTP_PORT': '587',
    'GOTRUE_SMTP_USER': 'no-reply@$D', 'GOTRUE_SMTP_PASS': 'lab-only-not-a-secret',
    'GOTRUE_SMTP_ADMIN_EMAIL': 'no-reply@$D',
    'AI_MODEL': 'lab/model', 'AI_PROVIDER_API_KEY': 'lab-dummy',
    'RESTIC_REPOSITORY': 's3:http://lab-offsite:8333/backups',
    'BACKUP_S3_ACCESS_KEY': 'labbackup', 'BACKUP_S3_SECRET_KEY': 'labbackupsecret', 'BACKUP_HOUR_UTC': '2',
}
lines = [l.rstrip('\n') for l in open('.env')] + [f'{k}={v}' for k, v in vals.items()]
last = {}
for i, l in enumerate(lines):
    m = re.match(r'^([A-Z0-9_]+)=', l)
    if m: last[m.group(1)] = i
out = [l for i, l in enumerate(lines) if not (re.match(r'^([A-Z0-9_]+)=', l) and last[re.match(r'^([A-Z0-9_]+)=', l).group(1)] != i)]
open('.env', 'w').write('\n'.join(out) + '\n')
PY"
    # The off-site bucket's stand-in: a second SeaweedFS on the studio network,
    # WITH an access key like any real bucket (anonymous SeaweedFS mangles
    # restic's signed uploads: they retry forever).
    as_root 'mkdir -p /root/offsite && printf "%s" "{\"identities\":[{\"name\":\"lab\",\"credentials\":[{\"accessKey\":\"labbackup\",\"secretKey\":\"labbackupsecret\"}],\"actions\":[\"Admin\",\"Read\",\"Write\",\"List\",\"Tagging\"]}]}" > /root/offsite/s3.json
             docker rm -f lab-offsite >/dev/null 2>&1
             docker run -d --name lab-offsite --network studio -v /root/offsite/s3.json:/s3.json:ro chrislusf/seaweedfs:3.97 server -s3 -s3.config=/s3.json >/dev/null
             for i in $(seq 1 60); do docker run --rm --network studio curlimages/curl:8.11.1 -s -o /dev/null http://lab-offsite:8333/ && break; sleep 2; done; sleep 5'
    check ".env root-only" "test \"\$(stat -c %a $P/.env)\" = 600"
    check "exactly the core would start" "cd $P && [ \"\$(docker compose config --services | sort | tr '\n' ' ')\" = 'ai backup mail-templates postgres seaweedfs stalwart ' ]"
    check "nothing published except loopback operator ports" "cd $P && docker compose config --format json | python3 -c 'import json,sys; c=json.load(sys.stdin); bad=[(s,p) for s,v in c[\"services\"].items() for p in v.get(\"ports\",[]) if p.get(\"host_ip\")!=\"127.0.0.1\"]; print(bad); sys.exit(1 if bad else 0)'"
}

step3() {
    title "Step 3 · first boot and the public sites through the edge (§5)"
    xprobe_start nexwe.app lab-x-plat
    run "cd $P && sudo docker compose up -d --build 2>&1 | grep -vE 'Pull|Waiting|Download|Extract|Verif|^ *#|Building|Built' | tail -12"
    as_root "cd $P && for i in \$(seq 1 90); do [ -z \"\$(docker compose ps --format '{{.Health}}' | grep -v healthy | grep -v '^\$')\" ] && break; sleep 2; done"
    run "cd $P && sudo docker compose ps --format 'table {{.Name}}\t{{.Status}}'"
    run "cd $P && sudo scripts/harden-db.sh"
    run "cd $P && sudo scripts/edge-sites.sh"
    read -r t b l <<<"$(xprobe_stop lab-x-plat)"
    note "nexwe.app during boot + one edge reload: $t requests, $b failed, longest ${l}s"
    check "the only Caddy is the edge's (no caddy service in this stack)" "[ \"\$(docker inspect -f '{{index .Config.Labels \"com.docker.compose.project\"}}' studio-caddy)\" = algo3-edge ] && ! (cd $P && docker compose ps -a --format '{{.Service}}' | grep -qx caddy)"
    check "services healthy" "cd $P && [ -z \"\$(docker compose ps --format '{{.Health}}' | grep -v '^healthy\$' | grep -v '^\$')\" ]"
    # Health alone missed a service with no healthcheck left in state "Created"
    # (the backup job, when compose gave up waiting for Postgres's first boot).
    check "EVERY service is running (none left 'Created')" "cd $P && [ \"\$(docker compose ps -a --format '{{.Service}} {{.State}}' | grep -vc ' running\$')\" = 0 ]"
    check "files.$D answers through the edge, unsigned refused (403)" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://files.$D/x/y)\" = 403 ]"
    check "mail.$D has a certificate and answers 404" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://mail.$D/)\" = 404 ]"
    # The edge obtains a new certificate in the background after the reload.
    check "the mail certificate is visible to Stalwart" "for i in \$(seq 1 30); do docker exec studio-stalwart sh -c 'ls /caddy-data/caddy/certificates/*/mail.$D/mail.$D.crt' >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1"
    check "a second run changes nothing (no reload)" "cd $P && scripts/edge-sites.sh | grep -q 'unchanged'"
    as_root "mkdir -p /etc/algo3/apps/clash && printf 'IMAGE=x/y\nHOSTNAME=files.$D\n' > /etc/algo3/apps/clash/staging.conf"
    check "a domain a deployed app owns is refused" "cd $P && ! scripts/edge-sites.sh --check 2>&1 && scripts/edge-sites.sh --check 2>&1 | grep -q 'already claimed'"
    as_root 'rm -rf /etc/algo3/apps/clash'
    check "nexwe.app still serves" 'curl -fsS -o /dev/null https://nexwe.app/'
}

step4() {
    title "Step 4 · one product, two environments (§7)"
    run "cd $P && sudo scripts/add-product.sh demo https://demo.lab.test --identity --signup off > /tmp/demo.out 2>&1; tail -4 /tmp/demo.out"
    run "cd $P && sudo scripts/add-product.sh demo-staging https://staging.demo.lab.test --identity --signup off > /tmp/demo-staging.out 2>&1; tail -4 /tmp/demo-staging.out"
    # The printed env blocks, as you will save them into /etc/algo3/apps/<app>/<env>.env
    as_root "for e in demo demo-staging; do grep -E '^(DATABASE_URL|STORAGE_ACCESS_KEY|STORAGE_SECRET_KEY)=' /tmp/\$e.out > /root/\$e.env; done"
    check "auth-demo and auth-demo-staging published through the edge" "grep -q '^auth-demo.$D {' /etc/algo3/caddy/platform/studio-platform.caddy && grep -q '^auth-demo-staging.$D {' /etc/algo3/caddy/platform/studio-platform.caddy"
    check "each login service publishes its own key" "a=\$(curl -fsS https://auth-demo.$D/.well-known/jwks.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"keys\"][0][\"x\"])') && b=\$(curl -fsS https://auth-demo-staging.$D/.well-known/jwks.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"keys\"][0][\"x\"])') && [ -n \"\$a\" ] && [ \"\$a\" != \"\$b\" ]"
    check "different issuer and audience per environment" "[ \"\$(docker exec studio-gotrue-demo printenv GOTRUE_JWT_ISSUER) \$(docker exec studio-gotrue-demo printenv GOTRUE_JWT_AUD)\" = 'https://auth-demo.$D demo' ] && [ \"\$(docker exec studio-gotrue-demo-staging printenv GOTRUE_JWT_ISSUER) \$(docker exec studio-gotrue-demo-staging printenv GOTRUE_JWT_AUD)\" = 'https://auth-demo-staging.$D demo-staging' ]"
    check "the admin API is not reachable from outside (404, both)" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' https://auth-demo.$D/admin/users)\" = 404 ] && [ \"\$(curl -s -o /dev/null -w '%{http_code}' https://auth-demo-staging.$D/admin/users)\" = 404 ]"
    check "staging's role can use staging's database" ". /root/demo-staging.env; docker exec studio-postgres psql \"\${DATABASE_URL/@postgres:/@localhost:}\" -Atc 'select 1' | grep -q 1"
    check "STAGING'S ROLE CANNOT CONNECT TO PRODUCTION'S DATABASE" ". /root/demo-staging.env; u=\${DATABASE_URL/@postgres:/@localhost:}; ! docker exec studio-postgres psql \"\${u%/*}/demo\" -Atc 'select 1'"
    check "staging's S3 key can list staging's bucket" ". /root/demo-staging.env; [ \"\$(docker run --rm --network studio curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' --aws-sigv4 aws:amz:us-east-1:s3 --user \"\$STORAGE_ACCESS_KEY:\$STORAGE_SECRET_KEY\" http://seaweedfs:8333/demo-staging-files/)\" = 200 ]"
    check "STAGING'S S3 KEY IS REFUSED ON PRODUCTION'S BUCKET" ". /root/demo-staging.env; [ \"\$(docker run --rm --network studio curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' --aws-sigv4 aws:amz:us-east-1:s3 --user \"\$STORAGE_ACCESS_KEY:\$STORAGE_SECRET_KEY\" http://seaweedfs:8333/demo-files/)\" = 403 ]"
    check "ocr was NOT started by add-product (profile off)" '! docker ps --format "{{.Names}}" | grep -q studio-ocr'
}

step5() {
    title "Step 5 · backup, then a restore drill (§8)"
    as_root ". /root/demo.env; docker exec studio-postgres psql \"\${DATABASE_URL/@postgres:/@localhost:}\" -q -c 'create table if not exists drill(id int); insert into drill select generate_series(1,42)'"
    run "cd $P && sudo docker compose run --rm backup once 2>&1 | grep -E 'dumped|cycle finished|CYCLE FAILED' | head -8"
    run "cd $P && sudo scripts/restore-drill.sh demo 2>&1 | tail -6"
    check "the restored copy has the same 42 rows" "docker exec studio-postgres psql -U postgres -d demo_restore -Atc 'select count(*) from drill' | grep -qx 42"
    check "the scratch copy is closed to the product's own role" ". /root/demo.env; u=\${DATABASE_URL/@postgres:/@localhost:}; ! docker exec studio-postgres psql \"\${u%/*}/demo_restore\" -Atc 'select 1'"
    run "cd $P && sudo scripts/restore-drill.sh demo --drop"
    check "scratch dropped" "! docker exec studio-postgres psql -U postgres -Atc \"select 1 from pg_database where datname='demo_restore'\" | grep -q 1"
    check "the backup container still holds only the read-only role" "docker compose -f $P/docker-compose.yml -f $P/docker-compose.prod.yml --project-directory $P run --rm --entrypoint printenv backup PGUSER | grep -qx studio_backup"
}

step6() {
    title "Step 6 · everything the edge already served still serves"
    check "nexwe.app" 'curl -fsS https://nexwe.app/release.json | grep -q release'
    check "staging.nexwe.app" 'curl -fsS https://staging.nexwe.app/release.json | grep -q release'
    check "www redirect" 'curl -sI https://www.nexwe.app/ | grep -qi "^location: https://nexwe.app/"'
}

[[ $# -gt 0 ]] || set -- 1 2 3 4 5 6
for s in "$@"; do "step$s"; done
finish
