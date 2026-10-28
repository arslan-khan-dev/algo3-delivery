#!/usr/bin/env bash
# check-2604.sh — validate the files that sshd and apt read on a real Ubuntu
# 26.04 (the server's release), laid out as on the server: AllowUsers in the
# main sshd_config and cloud-init's PasswordAuthentication yes drop-in.
#   docker run --rm -v "$PWD/server/baseline:/b:ro" ubuntu:26.04 bash /b/../lab/check-2604.sh  (see README)
set -uo pipefail
B=/b; pass=0; failed=0
ok() { if "$@"; then pass=$((pass+1)); else failed=$((failed+1)); echo "FAIL: $*"; fi; }
export DEBIAN_FRONTEND=noninteractive
if ! { apt-get update -qq >/dev/null && apt-get install -y -qq openssh-server unattended-upgrades >/dev/null 2>&1; }; then
    echo "install failed"; exit 1
fi
echo "OpenSSH: $(ssh -V 2>&1)"
ssh-keygen -A >/dev/null; mkdir -p /run/sshd
for u in zain algo3 algo3-deploy; do useradd -m "$u" 2>/dev/null; done
printf '\nAllowUsers zain algo3\n' >> /etc/ssh/sshd_config
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
cp "$B/etc/ssh/sshd_config.d/10-algo3.conf" /etc/ssh/sshd_config.d/
ok sshd -t
for u in algo3 algo3-deploy zain; do
  T="$(sshd -T -C "user=$u,host=x,addr=1.2.3.4")"
  ok grep -qx 'passwordauthentication no' <<<"$T"
  ok grep -qx "allowusers $u" <<<"$T"
done
ok grep -qx 'permitrootlogin no' <<<"$T"
cp "$B/etc/apt/apt.conf.d/52algo3-unattended" /etc/apt/apt.conf.d/
ok grep -qx 'Unattended-Upgrade::Automatic-Reboot "false";' <(apt-config dump)
echo "passed: $pass  failed: $failed"; [[ $failed -eq 0 ]]
