# The lab: rehearse every server step on your PC first

`algo3-lab` is a disposable container that stands in for the algo3-vps. It has
real systemd, sshd, Docker and a host Caddy, and it is seeded to **the
server's state as inventoried on 2026-10-28**:

- nexwe-website and staging on `127.0.0.1:8081` / `:8083`;
- the rollback containers, stopped;
- no Docker log limits;
- SSH that still accepts passwords;
- the old deploy wrapper.

```bash
bash lab/up.sh                      # fresh lab in today's server state (~3 min)
bash lab/rehearse-phase2.sh         # Phase 2, every step, with checks (~5 min)
bash lab/rehearse-phase2.sh 3       # a single step
bash lab/rehearse-phase3.sh         # Phase 3: the edge cutover (after phase 2)
bash lab/rehearse-phase4.sh         # Phase 4: automated deploys + drills (after phase 3)
docker exec -it algo3-lab bash      # look around "on the server"
docker rm -f algo3-lab              # throw it away
docker run --rm -v "$PWD/server/baseline:/b:ro" -v "$PWD/lab/check-2604.sh:/check.sh:ro" \
    ubuntu:26.04 bash /check.sh     # sshd + apt files on the server's exact release
```

## How the lab differs from the server, and why

| Lab | Server | Why |
| --- | --- | --- |
| Ubuntu 24.04 (systemd 255) | Ubuntu 26.04 (systemd 259) | This PC's Docker uses cgroup v1, which systemd 259 cannot boot on. `check-2604.sh` validates the sshd and apt files on 26.04 separately. |
| Caddy `local_certs` | Let's Encrypt | There is no public DNS in the lab. |
| Images from `localhost:5000` | `ghcr.io/arslan-khan-dev/…` | There is no GHCR token in the lab. The images are built from the same commits. |
| healthchecks stand-in at `https://hc.lab:8443` | healthchecks.io | The lab records every ping in `/var/log/lab-fakehc.log`. |
| `algo3` has passwordless sudo | sudo with a password | The lab is scripted. |
| The old `deploy-nexwe` is a stand-in | The real installed script | The lab never runs the old deployer. |
| `sysctl` writes reach Docker Desktop's VM | The server's kernel | This is harmless. Docker Desktop resets it on restart. |

## What the rehearsals measured (2026-10-29)

Downtime is measured by an **external probe**: a separate container reaching
the lab over the network, the way real visitors arrive. It makes ~6 requests a
second, and a probe that records nothing fails every check.

| Moment | Requests failed | Longest outage |
| --- | --- | --- |
| Phase 2: the one approved Docker restart (turns on live-restore) | ~35–40 % | **~4 s** |
| Any later Docker restart, before or after the cutover | ~20 % | **~1.6–2 s** |
| Phase 3: installing the edge, bootstrap deploys | 0 | 0 |
| Phase 3: **the cutover** (host Caddy → edge) | ~35 % | **~2–2.5 s** |
| Phase 3: rolling the cutover back / forward again | | ~1–1.5 s each |
| Phase 4: a staging deploy, seen from production **and** from staging | **0** | 0 |
| Phase 4: production promotion, rollback | **0** | 0 |
| Phase 4: three refused deploys (bad marker, unhealthy, missing image) | **0** | 0 |

What these numbers changed:

1. **Every Caddy reload drops about one new connection in three, on every
   site.** That was measured with forced reloads, and turning off HTTP/3 or
   setting a grace period did not help. So **deploys do not reload Caddy.**
   - The edge points at a stable alias per app and environment, and the
     deployer moves that alias between release containers.
   - A short `dial_timeout` plus `lb_try_duration` in the site template retries
     the rare request that lands on a stopping release.
   - In 20 switches across 401 requests nothing failed; 5 requests took about
     0.5 s.
2. **A Docker restart pauses traffic even after the cutover.** dockerd rebuilds
   its port-forwarding rules every time it starts. live-restore keeps the
   containers running, but packets can't reach them for ~1.7 s. **Upgrade
   Docker in a quiet hour.** (An earlier note here said the cutover removes
   this gap. The measurement showed that was wrong.)
3. **The certificate does not change at the cutover.** The serial is the same
   before and after, because the host Caddy's certificates are copied into the
   edge beforehand.

Also verified:

- OpenSSH `AllowUsers` lines accumulate, checked on Ubuntu 26.04 / OpenSSH 10.2.
- Killing the CI's SSH connection mid-deploy does not stop the deploy.
- The second of two concurrent deploys is refused by the lock, and CI is told
  why.
