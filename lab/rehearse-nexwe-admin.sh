#!/usr/bin/env bash
# rehearse-nexwe-admin.sh — the NEXWE admin dashboard (nexwe repo, apps/admin) onboarded and deployed through the
# real deployer, staging then production, from the working copy (what GitHub would build). After
# rehearse-platform.sh / rehearse-products.sh (the edge must be running):
#
#   bash lab/rehearse-nexwe-admin.sh
#
# What it proves: the registry files install with install.sh --app; staging and production serve the SAME image,
# each on its own hostname, with the release marker; deep links work (client-side routes); the strict headers
# (CSP, no framing, noindex) reach the browser through the edge; production refuses an image staging never ran.
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

REG=localhost:5000
D=/usr/local/libexec/algo3-deploy
PRODUCTS="$(cd "$LAB_DIR/../.." && pwd)"
RUN="$(date +%s)"
R1="$(printf 'nexwe-admin-%s-1' "$RUN" | sha1sum | cut -c1-40)"
R2="$(printf 'nexwe-admin-%s-2' "$RUN" | sha1sum | cut -c1-40)"

build_into_lab() {   # build_into_lab <sha>
    local ctx="$PRODUCTS/nexwe/apps/admin" w
    w="$(cygpath -w "$ctx" 2>/dev/null || echo "$ctx")"
    docker build -q --build-arg "RELEASE_SHA=$1" -t "$REG/nexwe-admin:$1" "$w" >/dev/null || return 1
    docker save "$REG/nexwe-admin:$1" | docker exec -i algo3-lab docker load >/dev/null &&
        as_root "docker push -q $REG/nexwe-admin:$1 >/dev/null"
}
digest() { echo "\$(sudo docker image inspect -f '{{index .RepoDigests 0}}' $REG/nexwe-admin:$1 | cut -d@ -f2)"; }

title "Step 1 · two releases from the working copy, into the lab registry"
for s in "$R1" "$R2"; do build_into_lab "$s" || note "build failed for $s"; done
check "both releases in the lab registry" "curl -fsS http://localhost:5000/v2/nexwe-admin/tags/list | grep -q $R1 && curl -fsS http://localhost:5000/v2/nexwe-admin/tags/list | grep -q $R2"

title "Step 2 · registry files, as on the server (install.sh --app), images from the lab registry"
run "cd /lab/algo3-delivery/server && sudo ./install.sh --app nexwe-admin 2>&1 | grep -E 'Registry|nexwe-admin|Done' | head -6"
as_root "sed -i 's#^IMAGE=.*#IMAGE=$REG/nexwe-admin#' /etc/algo3/apps/nexwe-admin/staging.conf /etc/algo3/apps/nexwe-admin/production.conf
  grep -q ' admin.nexwe.app' /etc/hosts || echo '127.0.0.1 staging-admin.nexwe.app admin.nexwe.app' >> /etc/hosts"
# Never run checks against the real server: both names must point at the lab.
for n in staging-admin.nexwe.app admin.nexwe.app; do
    as_root "getent hosts $n | grep -q '^127\.0\.0\.1 '" || { echo "STOP: $n does not point at the lab; refusing to run checks against a real server"; exit 1; }
done
check "both environments registered, production promotes only from staging" "grep -q '^PROMOTE_FROM=staging' /etc/algo3/apps/nexwe-admin/production.conf && grep -q '^HOSTNAME=staging-admin.nexwe.app' /etc/algo3/apps/nexwe-admin/staging.conf"

title "Step 3 · staging"
run "sudo $D deploy nexwe-admin staging $R1 $(digest "$R1") 2>&1 | tail -3"
check "staging serves the release marker through the edge" "curl -fsS https://staging-admin.nexwe.app/release.json | grep -q '\"release\":\"$R1\"'"
check "a deep link answers the app (client-side route)" "curl -fsS https://staging-admin.nexwe.app/users/some-id | grep -q '<div id=\"root\">'"
check "strict headers reach the browser (CSP, no framing, noindex)" "h=\$(curl -sI https://staging-admin.nexwe.app/); echo \"\$h\" | grep -qi '^content-security-policy:.*frame-ancestors .none.' && echo \"\$h\" | grep -qi '^x-frame-options: DENY' && echo \"\$h\" | grep -qi '^x-robots-tag: noindex'"
check "the page itself is never cached (a new release shows on reload)" "curl -sI https://staging-admin.nexwe.app/ | grep -qi '^cache-control: no-store'"

title "Step 4 · production: only the image staging verified"
check "production refuses an image staging never ran" "! $D deploy nexwe-admin production $R2 $(digest "$R2") >/tmp/na-refuse.log 2>&1 && grep -q 'never verified live on staging' /tmp/na-refuse.log"
run "d=\$(sudo awk -v s=$R1 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/nexwe-admin/staging.history); sudo $D deploy nexwe-admin production $R1 \$d 2>&1 | tail -2"
check "production serves the same release" "curl -fsS https://admin.nexwe.app/release.json | grep -q '\"release\":\"$R1\"'"
check "same image in both environments" "[ \"\$(docker inspect -f '{{.Image}}' nexwe-admin-staging-${R1:0:12})\" = \"\$(docker inspect -f '{{.Image}}' nexwe-admin-production-${R1:0:12})\" ]"
check "production: 64 MB memory limit" "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' nexwe-admin-production-${R1:0:12})\" = 67108864 ]"

title "Step 5 · a second release through staging, then production"
run "sudo $D deploy nexwe-admin staging $R2 $(digest "$R2") 2>&1 | tail -2"
run "d=\$(sudo awk -v s=$R2 '\$2==s {d=\$3} END {print d}' /var/lib/algo3/nexwe-admin/staging.history); sudo $D deploy nexwe-admin production $R2 \$d 2>&1 | tail -2"
check "production moved to the second release" "curl -fsS https://admin.nexwe.app/release.json | grep -q '\"release\":\"$R2\"'"

finish
