# Phase 3: move nexwe.app from the host Caddy to `algo3-edge`

Run on the VPS as `algo3`, one step at a time, and paste the output back
before the next step. Rehearsed end to end in the lab (`lab/rehearse-phase3.sh`).

| Measured in the lab | |
| --- | --- |
| Installing the edge, bootstrap deploys | **0** failed requests |
| The cutover (step 3) | **~2–2.5 s** with no answer (3 runs: 2.1, 2.3, 2.4 s) |
| Rolling the cutover back (step 4) | **~1–1.5 s** |
| Same certificate before and after | yes: copied, never re-issued |

**Prerequisites:**
- Phase 2 done: the deployer is installed, Docker has live-restore, and the alerts are working.
- The current code is staged in `~/stage` (Phase 2 step 0, run again for the latest code).

## Step 1: install the edge on dry-run ports. *No production effect.*

```bash
sudo rm -rf /opt/algo3/delivery && sudo cp -a ~/stage/algo3-delivery /opt/algo3/delivery && sudo chown -R root:root /opt/algo3/delivery
sudo bash /opt/algo3/delivery/server/install.sh
sudo bash /opt/algo3/delivery/edge/install.sh
sudo sed -i 's/^ACME_EMAIL=.*/ACME_EMAIL=you@your-domain/' /opt/algo3/edge/.env     # your real address
sudo docker compose -p algo3-edge -f /opt/algo3/edge/compose.yml up -d
sudo docker inspect -f '{{.State.Health.Status}}' studio-caddy                       # wait for: healthy
```

The edge installer:
- creates the `studio` network;
- **copies the host Caddy's certificates and ACME account into the edge's volume**;
- prints how many certificates it copied (expect at least 2).

The edge now listens on 18080/18443 only. The host Caddy still owns 80/443.

## Step 2: register nexwe-website, then deploy the live release through the new deployer. *No production effect.*

```bash
sudo bash /opt/algo3/delivery/server/install.sh --app nexwe-website
sudo sed -i 's/^PUBLIC_CHECK_PORT=.*/PUBLIC_CHECK_PORT=18443/' /etc/algo3/delivery.conf
sudo /usr/local/libexec/algo3-deploy deploy nexwe-website staging f568992edc66e7a85bda69b44138a0f51b94a495
digest=$(sudo awk '$2=="f568992edc66e7a85bda69b44138a0f51b94a495" {d=$3} END {print d}' /var/lib/algo3/nexwe-website/staging.history); echo "$digest"
sudo /usr/local/libexec/algo3-deploy deploy nexwe-website production f568992edc66e7a85bda69b44138a0f51b94a495 "$digest"
curl -fsS --resolve nexwe.app:18443:127.0.0.1 https://nexwe.app:18443/release.json
```

- **What these commands do:** they start **new** containers for today's release, labelled and on the `studio` network, and the deployer checks them through the edge on port 18443.
- **The promotion gate:** production accepts the release because staging verified the same sha and digest a minute earlier.
- **What doesn't change:** the old containers (`nexwe-website`, `nexwe-staging`) keep serving the public through the host Caddy.

## Step 3: the cutover. **Production: ~2–2.5 s. Approve first, pick a quiet moment.**

```bash
sudo sed -i '/^EDGE_HTTP_PORT=/d; /^EDGE_HTTPS_PORT=/d' /opt/algo3/edge/.env
sudo systemctl stop caddy && sudo docker compose -p algo3-edge -f /opt/algo3/edge/compose.yml up -d
for i in $(seq 1 30); do curl -fsS -o /dev/null https://nexwe.app/ && break; sleep 0.5; done
for h in nexwe.app staging.nexwe.app; do curl -fsS https://$h/release.json; echo; done
sudo sed -i 's/^PUBLIC_CHECK_PORT=.*/PUBLIC_CHECK_PORT=443/' /etc/algo3/delivery.conf
sudo systemctl disable caddy
```

The wait loop (line 3) matters. Docker reports the edge "Started" before Caddy
inside it is listening, so a check in the first milliseconds fails with
`curl: (7) Failed to connect … after 2 ms` even when the cutover is fine. That
happened on the real cutover (2026-10-30). The loop tries for up to 15 s and
continues as soon as the site answers.

**Check from your PC:**
- `https://nexwe.app` and `https://staging.nexwe.app` load;
- `https://www.nexwe.app` redirects;
- the browser shows the same certificate as before.

## Step 4: if anything is wrong, roll back. *~1–1.5 s*

```bash
sudo docker compose -p algo3-edge -f /opt/algo3/edge/compose.yml stop && sudo systemctl start caddy
```

The old containers are still running on 8081/8083, untouched, so the host Caddy serves them again immediately. Running step 3 again moves forward.

## Step 5: after 48 hours of stable running. *No production effect.*

```bash
sudo docker stop nexwe-website nexwe-staging          # kept, not removed
sudo rm /etc/sudoers.d/algo3-nexwe-deploy && sudo visudo -c
```

The old wrapper and script stay on disk until you decide to remove them.

**Docker upgrades from now on:** a Docker restart pauses traffic for ~1.5–2 s, even though the containers keep running (live-restore). Do Docker upgrades in a quiet hour.
