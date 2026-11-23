# Delivery on CircleCI

The CircleCI twin of `.github/workflows/deploy-app.yml`. The pipeline lives in
**one place**, the orb `circleci/orb.yml` in this repo (published as
`algo3/delivery`), and the settings in **one place**, the CircleCI context
`algo3-deploy`. A product repo only names its app: see
`examples/circleci-config.yml`, about 10 lines.

On CircleCI: **biruno-landing** (since 2026-11-23). Every other product still
uses GitHub Actions until it is moved.

## How it works

```
push staging ─► build image :<sha> once ─► scan ─► deploy staging
push main    ─► find the staging commit with the same code ─► deploy its exact image to production
```

- **The orb is read from CircleCI's orb registry**, not from GitHub, your Mac
  or the VPS. `circleci orb publish` uploads `circleci/orb.yml` there; this
  repo is the source of truth for what was published.
- **The VPS only has the server side** (`server/`, installed with
  `install.sh`): the `--any-app` deploy keys, the forced command, the registry
  in `server/apps/<app>/`. It is the same for GitHub and CircleCI. The server
  refuses a production release that was not live on staging
  (`PROMOTE_FROM=staging`), and only finishes a deploy once the public URL
  serves the new release.
- **Deploys need nothing on your Mac.** The CircleCI CLI is only needed to
  publish a new orb version.

Not covered yet: repos that ship several services
(`examples/deliver-multi-service.yml`), `tree-path` monorepos, and running
tests (`validate-command`). Those repos stay on GitHub Actions for now.

## What is already set up

| Piece | Where | Notes |
|---|---|---|
| Orb `algo3/delivery` (private) | CircleCI orb registry, namespace `algo3` | source: `circleci/orb.yml` |
| Context `algo3-deploy` | CircleCI → Organization Settings → Contexts | the six variables below |
| CircleCI deploy keys | VPS: `~algo3-deploy/.ssh/authorized_keys`, lines ending `circleci-staging` / `circleci-production` | `--any-app`: one pair works for every app |

Variables in the context:

| Name | Value |
|---|---|
| `GHCR_USER` | `arslan-khan-dev` |
| `GHCR_TOKEN` | classic GitHub token with only `write:packages` |
| `VPS_HOST` | server IP |
| `VPS_KNOWN_HOSTS` | the `ssh-keyscan -t ed25519 <server-ip>` line |
| `DEPLOY_SSH_KEY_STAGING_B64` | the staging private key, base64 on one line |
| `DEPLOY_SSH_KEY_PRODUCTION_B64` | the production private key, base64 on one line |

Upkeep:

- **`GHCR_TOKEN` expires** if it was created with an expiry date. Deploys then
  fail at "Log in to GHCR". Create a new token and replace it in the context.
- **To replace the deploy keys** (lost or leaked), on any machine:
  ```bash
  ssh-keygen -t ed25519 -N "" -C circleci-staging    -f ~/circleci-staging
  ssh-keygen -t ed25519 -N "" -C circleci-production -f ~/circleci-production
  echo "restrict,command=\"/usr/local/sbin/algo3-deploy-ssh --any-app staging\" $(cat ~/circleci-staging.pub)" > ~/circleci-keys.txt
  echo "restrict,command=\"/usr/local/sbin/algo3-deploy-ssh --any-app production\" $(cat ~/circleci-production.pub)" >> ~/circleci-keys.txt
  scp ~/circleci-keys.txt algo3@<server-ip>:/tmp/circleci-keys.txt
  ssh -t algo3@<server-ip> 'sudo tee -a ~algo3-deploy/.ssh/authorized_keys < /tmp/circleci-keys.txt > /dev/null && rm /tmp/circleci-keys.txt && sudo ssh-keygen -lf ~algo3-deploy/.ssh/authorized_keys'
  ```
  Put `base64 -i ~/circleci-staging` and `base64 -i ~/circleci-production`
  into the context, remove the old `circleci-*` lines on the server, then delete
  the key files from your machine.

## Onboard a new repo

An agent can do steps 2–3: point it at `docs/circleci-agent.md` and the repo's path.

1. **Server:** the app is registered, as for GitHub: `server/apps/<app>/staging.conf`
   and `production.conf` (with `PROMOTE_FROM=staging`), DNS, and
   `sudo ./install.sh --app <app>` (see `docs/app-contract.md`). No new keys or
   variables are needed.
2. **Config:** copy `examples/circleci-config.yml` to `<repo>/.circleci/config.yml`
   and set `app:`. Add `image: ghcr.io/arslan-khan-dev/<name>` only when the
   image name is not the repo name (biruno → `biruno-ai`).
3. **Turn GitHub Actions off** without losing it:
   ```bash
   mkdir -p .github/workflows-disabled
   git mv .github/workflows/deliver.yml .github/workflows-disabled/deliver.yml
   ```
4. **Commit and push to `staging`.**
5. **CircleCI → Projects → Set up project** on the repo, using the existing
   config on branch `staging`. If nothing runs, click **Trigger Pipeline** on
   `staging`. When `<staging-url>/release.json` shows the commit, merge
   `staging` into `main` and push.

Watch runs in the CircleCI dashboard (pick the project and branch), or from the
repo's folder with `circleci run list`.

**Going back to GitHub Actions** for a repo: move `deliver.yml` back to
`.github/workflows/`, delete `.circleci/`, push to `staging`, and stop the
project in CircleCI (Project Settings → Stop Building). The GitHub repository
secrets must still be there.

Common errors and their causes: see the table at the end of `docs/circleci-agent.md`.

## Changing the pipeline

Edit `circleci/orb.yml`, then:

```bash
circleci orb validate circleci/orb.yml
circleci orb publish increment circleci/orb.yml algo3/delivery --bump patch   # 1.0.0 → 1.0.1
```

Then commit and push this repo, so it matches what was published. Product
repos use `algo3/delivery@1`, so they pick up any `1.x` on their next run. A
breaking change gets `--bump major` (→ 2.0.0), and each repo moves to `@2` when
it is ready.

Setting up the CLI on a new machine:

```bash
brew install circleci
# copy a token from CircleCI → User Settings → Personal API Tokens, then:
circleci setup --no-prompt --host https://circleci.com --token "$(pbpaste)"
```
