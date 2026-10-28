#!/usr/bin/env bash
# seed-today.sh — runs INSIDE the lab as root. Recreates the algo3-vps as the
# inventory of 2026-10-28 found it, so every rehearsal starts from the real
# starting point:
#
#   host Caddy (systemd) on 80/443 → nexwe.app 127.0.0.1:8081, staging :8083
#   nexwe-website / nexwe-staging running f568992; *-rollback exited (9488241)
#   no /etc/docker/daemon.json; PasswordAuthentication yes; AllowUsers zain algo3
#   users algo3 (sudo), algo3-deploy (no docker group), zain
#   the old nexwe deploy wrapper + sudoers rule
#
# Lab-only differences, each marked LAB below: Caddy issues certificates from
# its own local CA (no Let's Encrypt here), images come from a local registry
# instead of ghcr.io, and algo3 has passwordless sudo for scripting.
set -Eeuo pipefail
OLD=94882418458b9be931479490abf0c625a56050ef
NEW=f568992edc66e7a85bda69b44138a0f51b94a495
REG=localhost:5000
step() { printf '\n== %s\n' "$*"; }

[[ -f /etc/lab/seeded ]] && { echo "already seeded"; exit 0; }
mkdir -p /etc/lab

step "users"
id algo3 >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo algo3
id algo3-deploy >/dev/null 2>&1 || useradd -m -s /bin/bash algo3-deploy
id zain >/dev/null 2>&1 || useradd -m -s /bin/bash zain
echo 'algo3:lab-only-password' | chpasswd
echo 'algo3 ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/90-lab-algo3          # LAB
chmod 0440 /etc/sudoers.d/90-lab-algo3

step "sshd as on the server"
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
grep -q '^AllowUsers' /etc/ssh/sshd_config || printf '\nAllowUsers zain algo3\n' >> /etc/ssh/sshd_config
sshd -t && systemctl restart ssh

step "names (the lab's DNS)"
cat >> /etc/hosts <<'EOF'
127.0.0.1 nexwe.app www.nexwe.app staging.nexwe.app hc.lab
EOF

step "stand-in healthchecks.io at https://hc.lab:8443 (LAB)"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=hc.lab' -addext 'subjectAltName=DNS:hc.lab' \
    -keyout /etc/lab/fakehc.key -out /etc/lab/fakehc.crt 2>/dev/null
cp /etc/lab/fakehc.crt /usr/local/share/ca-certificates/lab-fakehc.crt
update-ca-certificates >/dev/null
systemctl restart lab-fakehc

step "old nexwe deploy setup (stand-in: the lab never runs it)"
mkdir -p /usr/local/libexec
cat > /usr/local/libexec/deploy-nexwe <<'EOF'
#!/usr/bin/env bash
# LAB stand-in for the server's installed deploy-nexwe (not exercised here).
echo "old deploy-nexwe stand-in: $*"
EOF
cat > /usr/local/sbin/nexwe-deploy-wrapper <<'EOF'
#!/usr/bin/env bash
# LAB stand-in for the server's nexwe-deploy-wrapper.
exec /usr/local/libexec/deploy-nexwe "$@"
EOF
chmod 0755 /usr/local/libexec/deploy-nexwe /usr/local/sbin/nexwe-deploy-wrapper
cat > /etc/sudoers.d/algo3-nexwe-deploy <<'EOF'
# Permit algo3-deploy to invoke only the NexWe deployment wrapper.
# No command-line arguments are permitted.
algo3-deploy ALL=(root) NOPASSWD: /usr/local/sbin/nexwe-deploy-wrapper ""
EOF
chmod 0440 /etc/sudoers.d/algo3-nexwe-deploy
visudo -c >/dev/null

step "host Caddy, as on the server"
mkdir -p /etc/caddy/sites-enabled
cat > /etc/caddy/Caddyfile <<'EOF'
# LAB: certificates from Caddy's local CA instead of Let's Encrypt.
{
	local_certs
}

# Algo3 central Caddy configuration.
# Each product has its own site file in sites-enabled.
import /etc/caddy/sites-enabled/*.caddy
EOF
cat > /etc/caddy/sites-enabled/nexwe.caddy <<'EOF'
nexwe.app {
        encode zstd gzip
        reverse_proxy 127.0.0.1:8081
}

www.nexwe.app {
        redir https://nexwe.app{uri} permanent
}
EOF
cat > /etc/caddy/sites-enabled/staging.nexwe.caddy <<'EOF'
staging.nexwe.app {
    encode zstd gzip
    header X-Robots-Tag "noindex, nofollow, noarchive"
    reverse_proxy 127.0.0.1:8083
}
EOF
sed 's/8083/8082/' /etc/caddy/sites-enabled/staging.nexwe.caddy > /etc/caddy/sites-enabled/staging.nexwe.caddy.backup.sKT8Sx
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
systemctl restart caddy

step "local registry and the two nexwe-website releases (LAB: instead of ghcr.io)"
until docker info >/dev/null 2>&1; do sleep 1; done
docker run -d --name lab-registry --restart unless-stopped -p 127.0.0.1:5000:5000 registry:2 >/dev/null
for sha in "$OLD" "$NEW"; do
    docker build -q --build-arg "RELEASE_SHA=$sha" -t "$REG/nexwe-website:$sha" "/lab/src/nexwe-website-$sha" >/dev/null
    docker push -q "$REG/nexwe-website:$sha" >/dev/null
    echo "built and pushed $REG/nexwe-website:$sha"
done

step "today's containers"
run() { docker run -d --name "$1" --restart unless-stopped -p "127.0.0.1:$2:80" "$REG/nexwe-website:$3" >/dev/null; }
run nexwe-website-rollback 8080 "$OLD"; docker stop nexwe-website-rollback >/dev/null
run nexwe-staging-rollback 8082 "$OLD"; docker stop nexwe-staging-rollback >/dev/null
run nexwe-website 8081 "$NEW"
run nexwe-staging 8083 "$NEW"
docker run --name gifted_herschel hello-world >/dev/null 2>&1 || true

step "trust Caddy's local CA (LAB), then check both sites"
for _ in $(seq 1 30); do
    [[ -f /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]] && break
    curl -sk -o /dev/null https://nexwe.app/ || true
    sleep 1
done
cp /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt /usr/local/share/ca-certificates/lab-caddy-host.crt
update-ca-certificates >/dev/null
for _ in $(seq 1 30); do curl -fsS -o /dev/null https://nexwe.app/ && break; sleep 1; done
for host in nexwe.app staging.nexwe.app; do
    printf '%-20s %s  %s\n' "$host" "$(curl -s -o /dev/null -w '%{http_code}' "https://$host/")" "$(curl -s "https://$host/release.json")"
done

touch /etc/lab/seeded
step "seeded: the lab now matches the server's starting state"
