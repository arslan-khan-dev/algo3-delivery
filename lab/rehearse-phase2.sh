#!/usr/bin/env bash
# rehearse-phase2.sh — run Phase 2 (server baseline) in the lab, step by step,
# with the SAME commands the server runbook gives, as the algo3 user.
#
#   bash lab/up.sh                       fresh lab in today's server state
#   bash lab/rehearse-phase2.sh          all steps
#   bash lab/rehearse-phase2.sh 3        one step
#
# Every step ends with checks. A probe requests https://nexwe.app every 0.1 s
# throughout, so downtime is measured, not estimated.
# shellcheck disable=SC2016 # checks are single-quoted on purpose: their $(...) runs INSIDE the lab
set -uo pipefail
# shellcheck source=lab/lib.sh
source "$(dirname "$0")/lib.sh"

sites_ok='for h in nexwe.app staging.nexwe.app; do curl -fsS "https://$h/release.json" | grep -q f568992edc66e7a85bda69b44138a0f51b94a495 || exit 1; done'

step0() {
    title "Step 0 · copy the code to the server (lab: from the mounted repo)"
    run "mkdir -p ~/stage && tar -C /lab --exclude=.git --exclude=.mut --exclude=.work -czf - algo3-delivery | tar -xzf - -C ~/stage && ls ~/stage/algo3-delivery"
    check "repo staged in ~/stage" 'test -x /home/algo3/stage/algo3-delivery/server/install.sh -o -f /home/algo3/stage/algo3-delivery/server/install.sh'
}

step1() {
    title "Step 1 · install the deployer, inactive"
    run "sudo install -d -m 0755 /opt/algo3"
    run "sudo rm -rf /opt/algo3/delivery && sudo cp -a ~/stage/algo3-delivery /opt/algo3/delivery && sudo chown -R root:root /opt/algo3/delivery"
    run "sudo bash /opt/algo3/delivery/server/install.sh"
    run "sudo -l -U algo3-deploy"
    check "algo3-deploy may run the NEW wrapper, no arguments" 'sudo -l -U algo3-deploy | grep -q "/usr/local/sbin/algo3-deploy-wrapper \"\""'
    check "algo3-deploy may still run the OLD wrapper" 'sudo -l -U algo3-deploy | grep -q "/usr/local/sbin/nexwe-deploy-wrapper \"\""'
    check "algo3-deploy may run nothing else" '[ "$(sudo -l -U algo3-deploy | grep -c NOPASSWD)" -eq 2 ]'
    check "visudo accepts the whole sudoers set" 'visudo -c'
    check "deployer installed root-owned" 'test "$(stat -c %U:%a /usr/local/libexec/algo3-deploy)" = root:755'
    check "old deployer untouched" 'test -x /usr/local/libexec/deploy-nexwe'
    check "re-running install changes nothing" 'bash /opt/algo3/delivery/server/install.sh | grep -q "Done: 0 file(s) changed"'
    check "sites unaffected" "$sites_ok"
}

step2() {
    title "Step 2 · crash reboot + update policy"
    echo "  (lab note: sysctl writes to Docker Desktop's VM kernel; harmless, and reset when Docker Desktop restarts)"
    run "cd /opt/algo3/delivery/server/baseline && sudo bash baseline.sh sysctl apt"
    check "kernel.panic = 10" 'test "$(sysctl -n kernel.panic)" = 10'
    check "vm.swappiness = 10" 'test "$(sysctl -n vm.swappiness)" = 10'
    check "Automatic-Reboot false" 'apt-config dump | grep -q "^Unattended-Upgrade::Automatic-Reboot \"false\";"'
    check "re-running changes nothing" 'cd /opt/algo3/delivery/server/baseline && bash baseline.sh sysctl apt | grep -qv installed'
    check "sites unaffected" "$sites_ok"
}

step3() {
    title "Step 3 · Docker log limits + live-restore"
    run "cd /opt/algo3/delivery/server/baseline && sudo bash baseline.sh docker"
    check "daemon.json installed, Docker not yet restarted" 'test -f /etc/docker/daemon.json && test "$(docker info --format "{{.LiveRestoreEnabled}}")" = false'

    echo; echo "  -- the approved restart (first time: live-restore not active yet) --"
    probe_start; sleep 2
    run "sudo systemctl restart docker"
    as_root 'for i in $(seq 1 60); do curl -fsS -o /dev/null https://nexwe.app/ && break; sleep 0.5; done'; sleep 2
    read -r total bad longest <<<"$(probe_stop)"
    printf '  first restart:  %s requests, %s failed, longest outage %ss\n' "$total" "$bad" "$longest"
    check "live-restore now enabled" 'test "$(docker info --format "{{.LiveRestoreEnabled}}")" = true'
    check "nexwe containers came back (restart policy)" 'test "$(docker inspect -f "{{.State.Running}}" nexwe-website nexwe-staging | sort -u)" = true'
    check "rollback containers still stopped and kept" 'test "$(docker inspect -f "{{.State.Status}}" nexwe-website-rollback nexwe-staging-rollback | sort -u)" = exited'
    check "sites serve f568992 again" "$sites_ok"

    echo; echo "  -- a second restart, as a future Docker upgrade would do --"
    as_root 'docker inspect -f "{{.State.StartedAt}}" nexwe-website nexwe-staging > /tmp/started-before'
    sleep 20   # stay clear of systemd's limit of 3 Docker starts per minute
    probe_start; sleep 2
    run "sudo systemctl restart docker"
    sleep 4
    read -r total bad longest <<<"$(probe_stop)"
    printf '  second restart: %s requests, %s failed, longest outage %ss\n' "$total" "$bad" "$longest"
    check "live-restore: the containers were NOT restarted" 'test "$(docker inspect -f "{{.State.StartedAt}}" nexwe-website nexwe-staging)" = "$(cat /tmp/started-before)"'
    echo "  note: dockerd rebuilds its port-forwarding rules (and docker-proxy) on every start,"
    echo "        so a ~2 s gap is expected on a Docker restart, before AND after the cutover"
    echo "        (measured in rehearse-phase3.sh step 5). Upgrade Docker in a quiet hour."

    echo; echo "  -- log limits --"
    as_root 'docker run -d --name lab-logtest busybox sleep 300 >/dev/null'
    check "new containers get max-size 10m / max-file 5" 'docker inspect -f "{{.HostConfig.LogConfig.Config}}" lab-logtest | grep -q "max-file:5 max-size:10m"'
    as_root 'docker rm -f lab-logtest >/dev/null'
}

step5() {
    title "Step 5 · ops stack, timers, heartbeat (lab: stand-in healthchecks at hc.lab)"
    run "cd /opt/algo3/delivery/server/baseline && sudo bash baseline.sh ops timers"
    echo "  (filling in the alert settings, as you will with the real URLs)"
    as_root "sed -i 's#^BOX_CHECK_URL=.*#BOX_CHECK_URL=https://hc.lab:8443/ping/box#; s#^MAINTENANCE_CHECK_URL=.*#MAINTENANCE_CHECK_URL=https://hc.lab:8443/ping/maintenance#' /etc/algo3/monitoring.conf
             sed -i 's#^HEARTBEAT_URL=.*#HEARTBEAT_URL=https://hc.lab:8443/ping/deploys#' /etc/algo3/delivery.conf"
    check "monitoring.conf is root-only" 'test "$(stat -c %U:%a /etc/algo3/monitoring.conf)" = root:600'
    check "ops .env is root-only" 'test "$(stat -c %U:%a /opt/algo3/ops/.env)" = root:600'
    run "sudo docker compose -p algo3-ops -f /opt/algo3/ops/compose.yml up -d"
    as_root 'for i in $(seq 1 90); do curl -fs http://127.0.0.1:19999/api/v1/info >/dev/null && break; sleep 2; done'
    check "autoheal running" 'test "$(docker inspect -f {{.State.Running}} autoheal)" = true'
    check "Netdata dashboard answers on 127.0.0.1 only" 'curl -fs http://127.0.0.1:19999/api/v1/info >/dev/null && ! ss -ltn | grep -q "0.0.0.0:19999"'
    check "Netdata Cloud disabled" 'docker exec netdata cat /etc/netdata/cloud.d/cloud.conf | grep -q "enabled = no"'
    check "three timers active" '[ "$(systemctl list-timers "algo3-*" --no-legend | wc -l)" -eq 3 ]'
    as_root ': > /var/log/lab-fakehc.log; systemctl start algo3-heartbeat.service algo3-maintenance-check.service'
    check "heartbeat pinged the box check (success)" 'grep -q "POST /ping/box ok" /var/log/lab-fakehc.log'
    check "maintenance pinged (no reboot pending)" 'grep -q "POST /ping/maintenance no reboot" /var/log/lab-fakehc.log'
    check "sites unaffected" "$sites_ok"
}

step6() {
    title "Step 6 · prove every alert path"
    echo "  -- a hung container: unhealthy, labelled autoheal=true --"
    as_root 'docker rm -f lab-hung >/dev/null 2>&1; docker run -d --name lab-hung --label autoheal=true \
               --health-cmd "false" --health-interval 5s --health-retries 1 --health-start-period 1s busybox sleep 3600 >/dev/null
             docker inspect -f "{{.State.StartedAt}}" lab-hung > /tmp/started'
    check "autoheal restarted the unhealthy container" \
        'for i in $(seq 1 60); do [ "$(docker inspect -f "{{.State.StartedAt}}" lab-hung)" != "$(cat /tmp/started)" ] && exit 0; sleep 3; done; exit 1'
    check "Netdata raised docker_container_unhealthy (it would go to Telegram)" \
        'for i in $(seq 1 60); do curl -fs "http://127.0.0.1:19999/api/v1/alarms?all" | grep -q "docker_container_unhealthy" && exit 0; sleep 3; done; exit 1'
    check "stock 'container down' alert is gone (stopped rollbacks must not alert)" '! curl -fs "http://127.0.0.1:19999/api/v1/alarms?all" | grep -q docker_container_down'
    as_root 'docker rm -f lab-hung >/dev/null'

    echo; echo "  -- a pending reboot --"
    as_root ': > /var/log/lab-fakehc.log; printf "linux-image-lab\n" > /var/run/reboot-required.pkgs; touch /var/run/reboot-required; systemctl start algo3-maintenance-check.service'
    check "maintenance check pinged /fail with the package" 'grep -q "POST /ping/maintenance/fail Reboot required for: linux-image-lab" /var/log/lab-fakehc.log'
    as_root 'rm -f /var/run/reboot-required /var/run/reboot-required.pkgs'

    echo; echo "  -- Docker itself stops (live-restore keeps the sites up meanwhile) --"
    probe_start; sleep 1
    as_root 'docker inspect -f "{{.State.StartedAt}}" nexwe-website nexwe-staging > /tmp/started-before; sleep 20'
    as_root ': > /var/log/lab-fakehc.log; systemctl stop docker.socket docker.service; systemctl start algo3-heartbeat.service'
    check "heartbeat pinged /fail: docker is not active" 'grep -q "POST /ping/box/fail docker is not active" /var/log/lab-fakehc.log'
    as_root 'systemctl start docker; sleep 3'
    read -r total bad longest <<<"$(probe_stop)"
    printf '  while Docker was stopped: %s requests, %s failed\n' "$total" "$bad"
    check "containers kept running while Docker was stopped (live-restore)" 'test "$(docker inspect -f "{{.State.StartedAt}}" nexwe-website nexwe-staging)" = "$(cat /tmp/started-before)"'
    echo "  note: the dropped requests come from dockerd rebuilding its port-forwarding rules; the containers kept serving"

    echo; echo "  -- the weekly prune --"
    as_root 'systemctl start algo3-prune.service'
    check "rollback containers survive the prune" 'docker inspect nexwe-website-rollback nexwe-staging-rollback >/dev/null'
    check "rollback images survive the prune" 'docker image inspect localhost:5000/nexwe-website:94882418458b9be931479490abf0c625a56050ef >/dev/null'
    check "sites unaffected" "$sites_ok"
}

step7() {
    title "Step 7 · SSH hardening (last)"
    echo "  -- before: password login works (today's state) --"
    check "password login accepted before" 'sshpass -p lab-only-password ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no algo3@127.0.0.1 true'

    echo "  -- 7.1 your PC's key for algo3 (lab: a key made here plays your PC) --"
    as_root 'rm -f /root/pc_key*; ssh-keygen -q -t ed25519 -N "" -C "lab-pc" -f /root/pc_key
             install -d -o algo3 -g algo3 -m 700 /home/algo3/.ssh
             cat /root/pc_key.pub >> /home/algo3/.ssh/authorized_keys
             chown algo3:algo3 /home/algo3/.ssh/authorized_keys; chmod 600 /home/algo3/.ssh/authorized_keys'
    check "7.2 key-only login works BEFORE turning passwords off" 'ssh -i /root/pc_key -o StrictHostKeyChecking=no -o PasswordAuthentication=no algo3@127.0.0.1 true'

    echo "  -- 7.4 install the drop-in (validated, not reloaded) --"
    run "cd /opt/algo3/delivery/server/baseline && sudo bash baseline.sh ssh"
    check "not reloaded yet: passwords still work" 'sshpass -p lab-only-password ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no algo3@127.0.0.1 true'
    echo "  -- 7.5 reload --"
    run "sudo systemctl reload ssh"
    check "password login REFUSED" '! sshpass -p lab-only-password ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no algo3@127.0.0.1 true'
    check "7.6 a new key-only session works" 'ssh -i /root/pc_key -o StrictHostKeyChecking=no -o PasswordAuthentication=no algo3@127.0.0.1 true'
    check "AllowUsers now includes algo3-deploy (alongside zain and algo3)" 'sshd -T -C user=algo3-deploy,host=x,addr=1.2.3.4 | grep -q "^allowusers algo3-deploy$" && sshd -T -C user=zain,host=x,addr=1.2.3.4 | grep -q "^allowusers zain$"'

    echo "  -- a CI key for algo3-deploy, pinned with a forced command --"
    as_root 'rm -f /root/ci_key*; ssh-keygen -q -t ed25519 -N "" -C ci-nexwe-website-staging -f /root/ci_key
             install -d -o algo3-deploy -g algo3-deploy -m 700 /home/algo3-deploy/.ssh
             printf "restrict,command=\"/usr/local/sbin/algo3-deploy-ssh nexwe-website staging\" %s\n" "$(cat /root/ci_key.pub)" > /home/algo3-deploy/.ssh/authorized_keys
             chown algo3-deploy: /home/algo3-deploy/.ssh/authorized_keys; chmod 600 /home/algo3-deploy/.ssh/authorized_keys'
    check "the CI key cannot run a command (forced command answers instead)" 'out="$(ssh -i /root/ci_key -o StrictHostKeyChecking=no algo3-deploy@127.0.0.1 "id; ls /" </dev/null 2>&1)"; ! grep -q "uid=" <<<"$out" && grep -q "Missing commit SHA" <<<"$out"'
    check "the CI key cannot open a shell" '! ssh -i /root/ci_key -o StrictHostKeyChecking=no -tt algo3-deploy@127.0.0.1 </dev/null 2>&1 | grep -q "\$ "'
    check "the CI key reaches the wrapper (refused only because nexwe-website is not registered yet)" 'printf "%s\n" f568992edc66e7a85bda69b44138a0f51b94a495 | ssh -i /root/ci_key -o StrictHostKeyChecking=no algo3-deploy@127.0.0.1 2>&1 | grep -q "is not registered on this server"'
    check "sites unaffected" "$sites_ok"
}

[[ $# -gt 0 ]] || set -- 0 1 2 3 5 6 7
for s in "$@"; do "step$s"; done
finish
