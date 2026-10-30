# Step-by-step guide: rehearse everything in the lab, then do it on the server

This guide covers the whole process in order: what to test, how to build the
lab, every phase step by step (what it does, what is checked, whether it touches
production), how to do the same steps by hand, how to break things on purpose,
and how each lab step maps to the server.

**The rule behind all of it:** every server step is run in the lab first, with
the same commands, and must pass there before it is run on the server.

```
 your PC                                            the VPS
 ───────────────────────────────────────            ─────────────────────
 Level 1  fast tests (no lab)        ~5 min
 Level 2  the lab: a fake VPS in Docker,
          seeded to look like the server today
          ├─ Phase 2  baseline + monitoring  ──► same commands ──► Phase 2
          ├─ Phase 3  edge cutover           ──► same commands ──► Phase 3
          ├─ Phase 4  automatic deploys      ──► same commands ──► Phase 4
          └─ Apps     other app types + domains (future products)
```

---

## 0. Before you start

| You need | Check it with |
| --- | --- |
| Docker Desktop, running | `docker info` prints a server section |
| Git Bash (all commands below are Git Bash, not PowerShell) | `bash --version` |
| The three repos side by side in `D:\Algo3\Products\`: `algo3-delivery`, `nexwe-website` (with its git history), `studio-platform` | `ls /d/Algo3/Products` |
| About 10 GB free disk, and an internet connection for the first build | |

**In every new Git Bash window, run these two lines first:**

```bash
export MSYS_NO_PATHCONV=1
cd /d/Algo3/Products/algo3-delivery
```

`MSYS_NO_PATHCONV=1` stops Git Bash from rewriting Linux paths. Without it,
`docker exec … -w /home/algo3` reaches Docker as a Windows path such as
`C:/Program Files/Git/home/algo3`, and fails with `Cwd must be an absolute
path`. The same rewriting breaks `-v …:/src` mounts. The lab scripts set it
themselves; your own commands need it.

The lab uses your **working tree** (uncommitted changes included). The server
should only ever get **committed** code (see section 9).

---

## 1. Level 1: the fast tests (no lab needed)

Run these whenever the code changes. They prove the logic; the lab then proves
the real system.

```bash
# The deployer: 293 cases, with docker/curl faked. Every failure path, e.g.
# "the new release is unhealthy, so the old one must still be serving".
docker run --rm -v "$PWD/server:/src:ro" python:3.12-slim \
  bash -c 'apt-get update -qq && apt-get install -y -qq sudo >/dev/null && bash /src/test/run.sh'

# The server baseline: every config file checked by the real tool that reads it.
docker run --rm -v "$PWD/server/baseline:/b:ro" ubuntu:24.04 bash /b/test/baseline-test.sh

# The starter Dockerfiles: build each sample app, check health, non-root, clean stop.
bash templates/test-templates.sh

# Static checks: shell scripts and the GitHub workflow.
docker run --rm -v "$PWD/server:/mnt:ro" koalaman/shellcheck:v0.11.0 -x bin/* install.sh test/run.sh
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12 -no-color
```

**Expected:** `passed: 293  failed: 0`, `passed: 27  failed: 0`,
`Templates: 27 passed, 0 failed`, and no output from the two linters.

> These need `export MSYS_NO_PATHCONV=1` from section 0, or the `/src` mounts
> point at the wrong place.

---

## 2. Level 2: build the lab

```bash
bash lab/up.sh          # about 3 minutes; always starts from scratch
```

`up.sh` creates a container called `algo3-lab` that behaves like the VPS:

- real **systemd**, **sshd**, **Docker** inside it, and the **host Caddy** on 80/443;
- the users `algo3` (you, the admin) and `algo3-deploy` (CI's account);
- the two nexwe containers serving release `f568992`, plus the two `-rollback`
  containers holding `9488241`, all built from your nexwe-website history;
- passwords still allowed for SSH, and the old deploy wrapper installed.

That matches the inventory of the real server from 2026-10-28. Where the lab
has to differ, `lab/README.md` lists every difference and why. The important
ones: Ubuntu 24.04 instead of 26.04, Caddy's local certificates instead of
Let's Encrypt, images from `localhost:5000` instead of GHCR, and a stand-in for
healthchecks.io at `https://hc.lab:8443`.

**Look around, as if you were on the server:**

```bash
docker exec -it -u algo3 -w /home/algo3 algo3-lab bash   # you, as algo3
docker exec -it algo3-lab bash                           # as root
```

Inside, try the same things you would on the VPS:

```bash
docker ps                                   # the nexwe containers
systemctl status caddy                      # the host Caddy
curl -s https://nexwe.app/release.json      # which release is live
```

`exit` leaves the lab. `docker rm -f algo3-lab` throws it away.

---

## 3. How a rehearsal script works

Each phase has a script that runs the phase **step by step**, with the server
runbook's commands, **as the `algo3` user**, then checks the result.

```bash
bash lab/rehearse-phase2.sh       # every step of Phase 2
bash lab/rehearse-phase2.sh 3     # only step 3
bash lab/rehearse-phase2.sh 2 3   # steps 2 and 3
```

How to read what it prints:

| You see | It means |
| --- | --- |
| `════ Step 3 · …` | a step starts |
| `$ sudo bash baseline.sh docker` (dim) | **the exact command you will type on the server** |
| `PASS …` / `FAIL …` | one check: what must be true after the step |
| `CUTOVER: 55 requests, 19 failed, longest outage 2.1s` | the probe's measurement (below) |
| `Rehearsal: 49 passed, 0 failed` | the summary: anything other than 0 failed means stop |

**The probe** measures downtime instead of guessing it. A separate container
requests `https://nexwe.app` about 6 times a second **from outside the lab**,
the way real visitors arrive, and reports how many requests failed and the
longest gap. A probe that records too few requests fails every check, so a
broken probe can never pass by accident.

**Order matters.** Phases build on each other: Phase 3 needs Phase 2's result,
Phase 4 and Apps need Phase 3's. To rehearse a later phase, run the earlier
ones first on the same lab. Everything, from scratch:

```bash
bash lab/up.sh && for p in phase2 phase3 phase4 apps; do bash lab/rehearse-$p.sh; done
```

That takes about 25 minutes. Last result (2026-10-29): 49/49, 31/31, 34/34, 29/29.

---

## 4. Phase 2: server baseline and monitoring

**Goal:** the server restarts itself after a crash, logs can't fill the disk,
Docker can restart without stopping containers, and every failure raises an
alert. **The websites keep serving throughout, except one ~4 s moment.**

```bash
bash lab/rehearse-phase2.sh        # or step by step: … 0, then … 1, etc.
```

| Step | What it does | Main checks | Effect on production |
| --- | --- | --- | --- |
| **0** | Copy the code to `~/stage` | repo staged | none |
| **1** | Install the deployer, **inactive** (`server/install.sh`) | `algo3-deploy` may run only the new and old wrappers; `visudo` accepts it; re-running changes nothing | none |
| **2** | Reboot after a kernel panic, no automatic reboots (`baseline.sh sysctl apt`) | `kernel.panic = 10`, `Automatic-Reboot false` | none |
| **3** | Docker log limits and **live-restore** (`baseline.sh docker`, then `systemctl restart docker`) | containers come back; a **second** restart does not restart them; new containers get 10 MB × 5 logs | **~4 s outage, once**: the restart that turns live-restore on. **Needs your approval on the server.** |
| **5** | Monitoring: autoheal, Netdata, three timers (`baseline.sh ops timers`, `docker compose … up -d`) | Netdata answers on 127.0.0.1 only, Cloud off; heartbeat and maintenance pings arrive | none |
| **6** | **Prove every alert path** | an unhealthy container is restarted by autoheal and Netdata alerts; a pending reboot pings `/fail`; Docker stopped makes the heartbeat fail; prune never removes rollbacks | none (lab-only drills) |
| **7** | SSH: keys only, last (`baseline.sh ssh`, then `systemctl reload ssh`) | a key login works **before** passwords go off; afterwards passwords are refused and a **new** key session works | none, if done in this order |

There is no step 4: it was folded into step 3.

**What the numbers mean** (step 3): the first restart costs about 4 s. Later
restarts still cost about 2 s, because Docker rebuilds its port-forwarding
rules every time it starts. live-restore keeps the containers running, but not
that forwarding.

---

## 5. Phase 3: move the websites to the new edge

**Goal:** replace the host Caddy (a systemd service) with `algo3-edge`, one
Caddy container that serves every product, without re-issuing certificates.

```bash
bash lab/rehearse-phase3.sh
```

| Step | What it does | Main checks | Effect on production |
| --- | --- | --- | --- |
| **0** | Refresh the code, re-run `install.sh` | | none |
| **1** | Install the edge on **dry-run ports 18080/18443** (`edge/install.sh`, `docker compose … up -d`) | the host certificates were copied into the edge; edge healthy; the host Caddy still owns 443; **0 failed requests** | none |
| **2** | Register nexwe-website, deploy the **live** release through the new deployer, checked via 18443 | labelled release containers; staging has its noindex header; host Caddy still serving | none |
| **3** | **THE CUTOVER**: stop the host Caddy, start the edge on 80/443, disable the host Caddy | outage **under 3 s**; **same certificate serial before and after**; `www` redirects; traffic really goes to the new containers | **~2 s outage. Needs your approval.** |
| **4** | Rollback drill: back to the host Caddy, then forward again | each direction under 3 s | ~1 s each (on the server, only if needed) |
| **5** | A Docker restart after the cutover | the edge and releases were not restarted (live-restore) | ~2 s (the same as section 4) |

The real runbook with the server's own values is `edge/CUTOVER.md`.

---

## 6. Phase 4: automatic deploys of nexwe-website

**Goal:** a push to `staging` deploys staging, and a merge to `main` deploys the
**same image** to production, with zero failed requests. Here the lab **plays
GitHub Actions**: it builds release images from your current nexwe-website tree
and deploys exactly as the workflow does, over SSH with keys pinned to one app
and environment.

```bash
bash lab/rehearse-phase4.sh
```

| Step | What it does | Main checks |
| --- | --- | --- |
| **1** | Build release images (the CI side) | pinned Caddy, HEALTHCHECK present |
| **2** | Two deploy keys, one per environment, each **pinned to a forced command** | a key can't run commands; an unknown host key is refused |
| **3** | "Push to staging": automatic staging deploy | staging serves the new release; **0 failed requests on staging and on production**; heartbeat pinged; logged |
| **4** | "Merge to main": production promotion of the **same digest** | 0 failed requests; production **refuses** a release staging never ran; the production key can't deploy staging |
| **5** | Failure drills: wrong release marker, unhealthy image, missing image | each refused, with the reason sent back to CI; staging never drops a request |
| **6** | SSH dies mid-deploy; two deploys at once | the deploy finishes anyway; the second is refused by the lock |
| **7** | Emergency rollback, and retention | rollback with 0 failed requests; exactly one rollback kept per environment |

What the lab can't test: GitHub Actions itself, the GHCR login, and Let's
Encrypt. Those are proven by the first real staging run
(`docs/rollout-nexwe-website.md`).

---

## 7. Apps: future products (any app type, their own domains)

**Goal:** prove the platform handles more than static sites, before biruno-ai,
the nexwe API and Atlas arrive.

```bash
bash lab/rehearse-apps.sh
```

| Step | What it proves |
| --- | --- |
| **1** | Three sample apps are built with the starter Dockerfiles in `templates/` |
| **2** | They're registered the way a real product would be |
| **3** | **Node API, its own domains** (`api.lab.test` + alias `api.other.test` + `www` redirect, site generated): migration runs before the switch; data lives in a volume; 0 failed requests; a **failing migration** is refused and the old release keeps serving; rollback doesn't re-run the migration |
| **4** | **Python, internal**: on its own private network, no public site, reached by name |
| **5** | **Worker** with `OVERLAP=false`: never two copies at once |
| **6** | **One domain, one owner**: an app claiming `nexwe.app` is refused; certificate monitoring lists every product's domains |

---

## 8. Doing it by hand (to really learn it)

The scripts type for you. To learn it, type the commands yourself in the lab,
exactly as you will on the server, then check the result.

**1. Fresh lab, and a shell as `algo3`:**

```bash
bash lab/up.sh
docker exec -it -u algo3 -w /home/algo3 algo3-lab bash
```

**2. Watch the site in a second Git Bash window** (this is your own probe):

```bash
docker exec algo3-lab bash -c 'while true; do printf "%s " "$(curl -s -o /dev/null -w "%{http_code}" --max-time 1 https://nexwe.app/)"; sleep 0.2; done'
```

You'll see a stream of `200`s. Anything else is a failed request; `000` means
no answer at all. Leave it running through every step: it shows you downtime as
it happens.

**3. Stage the code** (in the lab it comes from the mounted repo; on the server it comes from your PC, see section 9):

```bash
mkdir -p ~/stage && tar -C /lab --exclude=.git --exclude=.mut --exclude=.work -czf - algo3-delivery | tar -xzf - -C ~/stage
```

**4. Then run each step's commands from the tables above.** The exact commands
are in the scripts (the `run "…"` lines) and in the runbooks. Phase 2 starts
like this:

```bash
sudo install -d -m 0755 /opt/algo3
sudo rm -rf /opt/algo3/delivery && sudo cp -a ~/stage/algo3-delivery /opt/algo3/delivery && sudo chown -R root:root /opt/algo3/delivery
sudo bash /opt/algo3/delivery/server/install.sh
sudo -l -U algo3-deploy          # expect exactly two NOPASSWD lines
```

**5. Check it yourself** after each step: the "Main checks" column says what
must be true. Useful commands:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
sudo /usr/local/libexec/algo3-deploy status nexwe-website production
tail -n 20 /var/log/algo3/deploys.log
journalctl -u 'algo3-deploy-*' --since today --no-pager | tail -40
systemctl list-timers 'algo3-*'
curl -s http://127.0.0.1:19999/api/v1/alarms | head   # Netdata's active alerts
```

**6. To compare with the script afterwards,** run that step's checks:
`bash lab/rehearse-phase2.sh 2` re-runs step 2 and its checks. Steps 1, 2 and 5
are safe to repeat. Step 3 restarts Docker again, and the cutover steps assume
the state before them, so for those start again from `up.sh`.

### Break it on purpose

Each of these drills is in the scripts. By hand, it's where you learn how the system defends itself.

| Do this (in the lab) | Expect |
| --- | --- |
| After Phase 4 (when a rollback release exists): `docker stop nexwe-website-production-<sha12>`, the live release (`docker ps` shows the name) | the site stops answering; `sudo /usr/local/libexec/algo3-deploy rollback nexwe-website production` brings the retained release back within seconds (or `docker start` the stopped one) |
| Deploy a SHA that doesn't exist: `sudo /usr/local/libexec/algo3-deploy deploy nexwe-website staging 0123456789abcdef0123456789abcdef01234567` | refused ("Could not pull"); the live release untouched; logged as `recovered` |
| Two deploys at once (two windows) | the second says "Another deploy or rollback … is running" |
| After Phase 2: `sudo systemctl stop docker`, then `sudo systemctl start algo3-heartbeat.service` (the timer would otherwise wait up to 5 min), then `sudo systemctl start docker` | `cat /var/log/lab-fakehc.log` shows `POST /ping/box/fail docker is not active` |
| After the Apps rehearsal: add `ALIASES=nexwe.app` to `/etc/algo3/apps/demo-api/staging.conf` and deploy demo-api | refused before anything is pulled: "nexwe.app is already claimed by nexwe-website/production" |

---

## 9. Moving to the server

The commands are the same, and the steps run in the same order. The differences:

| | Lab | Server |
| --- | --- | --- |
| How the code arrives | `tar` from the mounted repo | from your PC over SSH (below); **committed code only** |
| Certificates | local, issued by the lab's own Caddy | Let's Encrypt, copied from the host Caddy at the cutover |
| Images | `localhost:5000` | `ghcr.io/arslan-khan-dev/…` |
| Alerts | stand-in at `hc.lab` | healthchecks.io and UptimeRobot, by email (real accounts) |
| sudo | no password | your password |
| Approval | none | **steps that affect production need your go-ahead** (marked below) |

**Rhythm:** one step at a time. Read its output, compare it with what the lab
showed, and only then continue. If anything differs from the lab, stop and
share the output.

**Getting the code onto the server** (from Git Bash on your PC, after
committing; `git archive` sends only committed files, never `.env` or lab
leftovers):

```bash
cd /d/Algo3/Products
git -C algo3-delivery archive --format=tar.gz --prefix=algo3-delivery/ HEAD \
  | ssh algo3@<vps> 'rm -rf ~/stage/algo3-delivery && mkdir -p ~/stage && tar -xzf - -C ~/stage'
```

### Phase 2 on the server

Before you start, create the free alert accounts. **Every alert arrives by
email**; there is no mail server on the VPS.

1. **healthchecks.io**: four checks. It emails you when one goes "down".
   - `box`: period 5 min, grace 10 min.
   - `maintenance`: period 1 day, grace 2 h.
   - `deploys`: period **365 days** (the maximum), grace 1 day.
   - `server-alerts`: period **365 days**, grace 1 day. Netdata pings it.

   The last two receive pings only when something happens, so a long period
   avoids a false "down" after a quiet week. A ping to `/fail` alerts
   immediately, whatever the period.
2. **UptimeRobot**: one HTTPS monitor each for `nexwe.app` and `staging.nexwe.app`.

| Step | On the server, as `algo3` | Approval |
| --- | --- | --- |
| 0 | the `git archive … \| ssh …` command above | |
| 1 | `sudo install -d -m 0755 /opt/algo3`, then copy to `/opt/algo3/delivery` and `sudo bash /opt/algo3/delivery/server/install.sh` (as in section 8) | |
| 2 | `cd /opt/algo3/delivery/server/baseline && sudo bash baseline.sh sysctl apt` | |
| 3 | `sudo bash baseline.sh docker`, **then** `sudo systemctl restart docker` | **yes: ~4 s outage** |
| 5 | `sudo bash baseline.sh ops timers`. Fill in `/etc/algo3/monitoring.conf` (the `box` and `maintenance` URLs), `HEARTBEAT_URL` in `/etc/algo3/delivery.conf` (the `deploys` URL) and `ALGO3_ALERTS_CHECK_URL` in `/opt/algo3/ops/.env` (the `server-alerts` URL). Then `sudo docker compose -p algo3-ops -f /opt/algo3/ops/compose.yml up -d` | |
| 6 | Check the alerts arrive. `sudo systemctl start algo3-heartbeat.service algo3-maintenance-check.service` pings `box` and `maintenance` now; both turn green. Netdata's own test, `sudo docker exec netdata /usr/libexec/netdata/plugins.d/alarm-notify.sh test`, turns `server-alerts` "down" then "up", so you get **two emails** | |
| 7 | SSH last, below | |

**Step 7, keys only.** Do this in order, and keep your current session open
until the last check passes:

```bash
# On your PC
ssh-keygen -t ed25519 -f ~/.ssh/algo3_vps
ssh-copy-id -i ~/.ssh/algo3_vps.pub algo3@<vps>
ssh -i ~/.ssh/algo3_vps -o PasswordAuthentication=no algo3@<vps> true && echo KEY LOGIN OK
```

Only once that prints `KEY LOGIN OK`:

```bash
# On the server
cd /opt/algo3/delivery/server/baseline && sudo bash baseline.sh ssh   # checks sshd -t, does NOT reload
sudo systemctl reload ssh
```

Then, from a **new** PC window: the key login works, and a password login is refused.

> **`zain`:** after step 7, `zain` can log in only with a key too. Make sure
> `zain` has one in `~zain/.ssh/authorized_keys` first, or `zain` is locked out
> of password login.

### Phase 3 on the server

Follow `edge/CUTOVER.md` step by step. Step 3, the cutover, is the one that
needs approval. Before it, add `SERVER_IPS=<the VPS's public IP>` to
`/etc/algo3/delivery.conf`, so every deploy checks the domains' DNS.

### Phase 4 on the server

Follow `docs/rollout-nexwe-website.md`: push algo3-delivery to GitHub with tag
`v1`, create the two deploy keys and the repository secrets and variables, then let a push to
`staging` deploy. The first merge to `main` deploys production: **ask before
it.**

---

## 10. When something goes wrong in the lab

| Symptom | Cause and fix |
| --- | --- |
| `up.sh` fails at "waiting for systemd" | Docker Desktop restarted or is short of memory. Restart Docker Desktop, then `bash lab/up.sh` again. |
| Docker inside the lab fails with an overlay error | The containerd volume is stale. `up.sh` recreates it; run it again. |
| `Cwd must be an absolute path`, or a path like `C:/Program Files/Git/…` in an error | Git Bash rewrote a Linux path. Run `export MSYS_NO_PATHCONV=1` in that window (section 0). |
| `the input device is not a TTY` on `docker exec -it` | That Git Bash window isn't a real terminal. Prefix the command with `winpty`, or use Windows Terminal. |
| Every probe check fails and the probe reports 999 | The probe recorded fewer than 10 requests, so it didn't really run. Look at `docker logs lab-xprobe`. |
| One phase fails after you changed code | Run the Level 1 tests first: they pinpoint most problems in seconds. |
| You want a clean slate | `docker rm -f algo3-lab`, then `bash lab/up.sh` |

**Clean up completely** (frees the disk space):

```bash
docker rm -f algo3-lab lab-xprobe 2>/dev/null
docker volume rm algo3-lab-docker algo3-lab-containerd
```
