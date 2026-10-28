# algo3-lab — a disposable stand-in for the algo3-vps, for rehearsing every
# server step on a PC first. See lab/README.md.
#
# Ubuntu 24.04 rather than the server's 26.04: Docker Desktop on this PC runs
# cgroup v1, and systemd 259 (26.04) no longer boots on it. Configuration files
# are additionally validated on a real 26.04 image by lab/check-2604.sh.
FROM caddy:2.11.7 AS caddy

FROM ubuntu:24.04
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus openssh-server openssh-client sudo curl ca-certificates \
        python3 iproute2 jq openssl gnupg logrotate unattended-upgrades sshpass procps less \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Host Caddy, the same version the server runs, under the official unit.
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy
RUN groupadd --system caddy \
    && useradd --system --gid caddy --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
COPY files/caddy.service /etc/systemd/system/caddy.service
COPY files/lab-fakehc.py /usr/local/lib/lab/fakehc.py
COPY files/lab-fakehc.service /etc/systemd/system/lab-fakehc.service

# Units that cannot work inside a container.
RUN systemctl mask systemd-udevd.service systemd-udev-trigger.service getty.target \
        console-getty.service systemd-modules-load.service sys-kernel-config.mount \
    && systemctl enable ssh docker caddy lab-fakehc

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
