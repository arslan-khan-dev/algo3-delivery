# Agent guide: move a product repo to CircleCI

You are helping move one product repo from GitHub Actions to CircleCI. The
person gives you this file and the path to the repo. Read `docs/circleci.md`
first for the background. In short:

- The pipeline is the orb in `circleci/orb.yml` in this repo (algo3-delivery).
- The settings are in the CircleCI context `algo3-deploy`, which already exists.
- The server already has CircleCI deploy keys that work for every app.

Your job is only the product repo's files, plus a short hand-off for the person.
Usually that's a 10-line config and one file move. A repo that already works
this way: `../micro-saas/biruno-landing` (`.circleci/config.yml` and
`.github/workflows-disabled/`).

## Rules

- **Don't commit or push** unless the person asks. Show them the changes.
- **Don't touch secrets.** No keys, tokens or `.env` files, and don't ask for them.
- **Don't change the server or this repo** (algo3-delivery) on your own. If the
  app isn't registered, report it and stop.
- **Don't delete the GitHub workflow.** Move it to `.github/workflows-disabled/`
  so it can be restored.
- If something doesn't fit the checks below, stop and explain. Don't improvise
  a custom CircleCI config.

## Steps

### 1 · Read the current GitHub setup

Open `<repo>/.github/workflows/deliver.yml` (or whichever workflow calls
`arslan-khan-dev/algo3-delivery/.github/workflows/deploy-app.yml`). Note:

| Input in the workflow | What you do with it |
|---|---|
| `app` | becomes `app:` in the CircleCI config |
| `image` | set `image:` only if it is **not** `ghcr.io/<owner>/<repo name in lowercase>` |
| `dockerfile` | set `dockerfile:` only if it is not `Dockerfile` |
| `target` | set `target:` if present |
| `validate-image`, `validate-command` | copy both as `validate-image:` and `validate-command:` (quote the command in YAML); `node-version: <v>` becomes `validate-image: node:<v>` |
| `tree-path`, or several jobs calling `deploy-app.yml` | **not supported**: stop, this repo stays on GitHub Actions |
| `context` other than `.` | **not supported**: stop and report |

If there is no such workflow, the repo was never on algo3 delivery. Stop and
point the person to the onboarding checklist in `docs/app-contract.md`.

### 2 · Check the app is registered on the server side

In this repo, check:

- `server/apps/<app>/staging.conf` and `server/apps/<app>/production.conf` exist
- `production.conf` has `PROMOTE_FROM=staging`
- `IMAGE=` in both matches the image from step 1

If anything is missing or doesn't match, stop and report it.

### 3 · Check the Dockerfile follows the contract

The orb passes `--build-arg RELEASE_SHA=<sha>`. The Dockerfile should accept
`ARG RELEASE_SHA`, and for apps with a release marker it should write it where
the server checks it (`RELEASE_PATH` / `RELEASE_KEY` in the `.conf`). It
already worked on GitHub, so this is usually fine. Only report a problem if it
is clearly missing.

### 4 · Write `<repo>/.circleci/config.yml`

Copy `examples/circleci-config.yml` from this repo. Use the orb reference
**exactly as written there** (for example `algo3/delivery@1`), because the
namespace may differ from these docs. Fill in:

```yaml
version: 2.1

orbs:
  algo3: algo3/delivery@1          # as in examples/circleci-config.yml

workflows:
  deliver:
    jobs:
      - algo3/deliver:
          app: <app>
          # validate-image: <image>       only if the workflow has validate-image / node-version (step 1)
          # validate-command: "<command>" only if the workflow has validate-command (step 1)
          # image: ghcr.io/arslan-khan-dev/<name>   only if needed (step 1)
          # dockerfile: <path>                       only if needed
          # target: <stage>                          only if needed
          context: algo3-deploy
          filters: { branches: { only: [staging, main] } }
```

Put a one-line comment at the top saying what the repo deploys and where
(staging and production URLs from the old workflow).

### 5 · Disable the GitHub workflow

```bash
cd <repo>
mkdir -p .github/workflows-disabled
git mv .github/workflows/deliver.yml .github/workflows-disabled/deliver.yml
```

Leave other workflows alone (CI tests, releases, etc.). Only the delivery
workflow moves.

### 6 · Check your work

- Run `circleci config validate .circleci/config.yml --org e45370fa-3c48-4743-84a3-6a6530e05ac9`
  in the repo if the CLI is installed (the private orb only resolves with `--org`).
  Otherwise, at least check the YAML parses.
- Run `git status` and confirm exactly two changes: the new `.circleci/config.yml`
  and the renamed workflow.

### 7 · Hand off to the person

Finish with a short summary: what you changed, anything you reported, then
these steps for them:

1. Commit and push to `staging`:
   `git add -A && git commit -m "CI: deliver with CircleCI" && git push origin staging`
2. CircleCI → **Projects → Set up project** on `<repo>`, using the existing
   config on branch `staging`. If nothing runs, click **Trigger Pipeline** on
   `staging`.
3. Check that `<staging-url>/release.json` (or the app's release path) shows the commit sha.
4. Merge `staging` into `main` and push; check production the same way.

To undo: move the workflow back to `.github/workflows/`, delete `.circleci/`,
push to `staging`, and stop the project in CircleCI.

## Common failures (if the person comes back with an error)

| Error in CircleCI | Cause |
|---|---|
| `Permission denied (publickey…)` on the deploy step | the CircleCI keys are missing from `~algo3-deploy/.ssh/authorized_keys` on the server, or the key value in the context is wrong |
| `denied` / `unauthorized` at "Log in to GHCR" or on push | `GHCR_TOKEN` in the context expired or lacks `write:packages` |
| `must be set (context algo3-deploy)` | `context: algo3-deploy` is missing from the config, or the project isn't allowed to use the context |
| `Cannot find orb` | the orb reference doesn't match `examples/circleci-config.yml`, or the orb isn't published |
| `This code was never on staging` (production) | the code was merged to `main` without a staging run first: push it to `staging`, wait for green, then merge again |
| `was never verified live on staging; refusing to promote` (from the server) | the staging deploy of that commit failed or never ran: fix staging first |
| Scan step fails | fixable CRITICAL vulnerabilities in the image: update the base image or add `apk upgrade` / `apt-get upgrade` in the Dockerfile |
