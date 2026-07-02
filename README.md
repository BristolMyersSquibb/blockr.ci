# blockr.ci

[![ci](https://github.com/BristolMyersSquibb/blockr.ci/actions/workflows/ci.yaml/badge.svg)](https://github.com/BristolMyersSquibb/blockr.ci/actions/workflows/ci.yaml)

Reusable GitHub Actions CI workflows for the [blockr](https://bristolmyerssquibb.github.io/blockr-site/) ecosystem.

## Usage

Consumer repo `.github/workflows/`:

### `ci.yaml` — PR + merge-queue gate

```yaml
on:
  pull_request:
  merge_group:

jobs:
  ci:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/ci.yaml@main
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
```

Leave the `pull_request:` trigger unfiltered. Adding `branches: main`
silently disables CI for stacked PRs (PRs whose base is another feature
branch) — they get no lint, no smoke, no signal at all until the base
is retargeted to `main`.

### `pkgdown.yaml` — site deploy on merge to main

```yaml
on:
  push:
    branches: main

name: pkgdown

jobs:
  pkgdown:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/pkgdown.yaml@main
    secrets:
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
    permissions:
      contents: write
```

PR-side pkgdown sanity checks live in `ci.yaml`'s `pkgdown-dev` job;
`pkgdown.yaml` only deploys. Consumers without a deployed site (e.g.
packages with Quarto-based docs) simply omit this workflow file.

### `revdep.yaml` — reverse-dependency checks (optional)

Add a second `jobs:` entry alongside the `ci` entry, gated on
`merge_group`:

```yaml
jobs:
  ci:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/ci.yaml@main
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
  revdep:
    if: github.event_name == 'merge_group'
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/revdep.yaml@main
    with:
      revdep-packages: |
        BristolMyersSquibb/blockr.dock
    secrets:
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
```

Pass secrets by name. `secrets: inherit` does not forward secrets
across organisations — the inherited values silently arrive blank in
the called job.

### `connect-deploy.yaml` — pull-mode Posit Connect deploys

Publishes git-backed ("pull-mode") deployments to Posit Connect, for a
Connect that sits on an internal network a GitHub runner cannot reach.
Deployment is inverted: Connect polls a branch and redeploys when it
advances. The workflow regenerates the per-deploy `manifest.json` and
commits it — from inside the merge queue — to a derived `connect-<base>`
branch (`connect-main`, `connect-test`) that Connect watches. Source
branches stay clean, with no manifest and no per-PR manifest churn.

Caller workflow in the deployment repo (default `auth: app` — push
`connect-*` with a GitHub App, paired with a locked `connect-*` ruleset):

```yaml
name: connect-deploy
on:
  pull_request:
  merge_group:

jobs:
  connect-deploy:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/connect-deploy.yaml@main
    permissions:
      contents: read
    with:
      r-version: "4.4.2"
    secrets:
      APP_ID: ${{ secrets.CONNECT_DEPLOY_APP_ID }}
      APP_PRIVATE_KEY: ${{ secrets.CONNECT_DEPLOY_APP_PRIVATE_KEY }}
```

For a repo whose org permits deploy keys but not Apps, use
`auth: deploy-key` — push `connect-*` over SSH with a repo deploy key on
the `connect-*` bypass. Same locked-branch guarantee as the App, with the
least setup:

```yaml
jobs:
  connect-deploy:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/connect-deploy.yaml@main
    permissions:
      contents: read
    with:
      auth: deploy-key
      r-version: "4.4.2"
    secrets:
      DEPLOY_KEY: ${{ secrets.CONNECT_DEPLOY_SSH_KEY }}
```

For a repo that can provision neither an App nor a deploy key (e.g. a
locked-down EMU org where both are gated), use `auth: token` — push
`connect-*` with the workflow's own `GITHUB_TOKEN`, no App, no
environment, no secrets, paired with an **unprotected** `connect-*`:

```yaml
jobs:
  connect-deploy:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/connect-deploy.yaml@main
    permissions:
      contents: write
    with:
      auth: token
      r-version: "4.4.2"
```

The job is a no-op on `pull_request` (so the required check stays green
and the PR is queueable) and the real publisher on `merge_group`. In app
mode, pass secrets by name. The `permissions:` differ by mode — see
[Auth modes](#auth-modes) for why, and for the security pairing each
mode requires.

The full consumer-side configuration — GitHub App, branch ruleset,
protected environment, required checks — is operational repo settings,
mostly one-time, and several pieces are load-bearing for security. See
[Connect deployment setup](#connect-deployment-setup).

## Pipeline

| Trigger | Jobs |
|---|---|
| `pull_request` | `lint`, `smoke`, `pkgdown-dev`, `coverage`, `docs` (parallel) |
| `merge_group` | `check` matrix → `check-all`; `revdep` matrix → `revdep-all` (if configured) |
| `push: main` | `pkgdown.yaml` deploy (if configured) |

PR jobs run in parallel for fast feedback. The expensive multi-platform
`check` matrix and reverse-dependency checks are reserved for the merge
queue — they gate the merge but never block PR iteration.

`check-all` and `revdep-all` aggregate their respective matrices into a
single stable name, so adding/removing a platform or revdep package
doesn't churn the required-checks list.

### Merge queue

Without GitHub's merge queue enabled, `merge_group` events never fire
and the multi-platform `check` matrix never runs — a green PR can then
produce a red `main` when one of the matrix platforms fails. Enabling
the merge queue closes that gap: the queue runs the full pipeline
against the would-be merge commit and blocks the merge on failure.

To enable, in the consumer repo's branch protection settings for `main`:

1. **Require a pull request before merging**.
2. **Require status checks to pass** — list these stable names:
   - `ci / lint`
   - `ci / smoke`
   - `ci / pkgdown-dev`
   - `ci / coverage`
   - `ci / docs`
   - `ci / check-all`
   - `revdep / revdep-all` (if `revdep.yaml` is configured)

   Skipped jobs satisfy required checks, so the queue accepts the
   PR-only jobs as `skipped` on `merge_group` refs (and vice versa for
   `check-all` / `revdep-all` on PR refs).
3. **Require merge queue** — leave the merge method as **merge commit**
   (squash and rebase strip the merge metadata downstream branches use
   to stay aligned).

Stacked PRs (PRs whose base is not `main`) still merge as plain pushes
to the parent feature branch and bypass the queue — that is intentional;
the queue is reserved for `main`.

## Inputs

### `ci.yaml`

| Input | Type | Default | Purpose |
|---|---|---|---|
| `lintr-exclusions` | newline-separated list | `''` | File paths to exclude from linting |
| `coverage-threshold` | number | `0` | Minimum coverage percent for the `coverage` job to pass. `0` disables the gate; coverage is still uploaded to Codecov. |
| `r-version` | string | `''` | R version for the PR-leg jobs (lint, smoke, pkgdown-dev, coverage, docs). Default (`''`) runs them on `release`. Set it (e.g. `4.4.2`) for a deploy app pinned to one runtime, so its PR checks — notably the `smoke` R CMD check — exercise the deployment target. The merge-queue `check` matrix is unaffected. Pair with `connect-deploy.yaml`'s `r-version` to gate against the version Connect serves. |
| `error-on` | string | `''` | R CMD check severity that fails the `smoke` and `check` jobs (passed to `check-r-package`'s `error-on`). Default (`''`) fails on any NOTE (`'"note"'`), holding the 0-errors/0-warnings/0-notes bar. A deploy app that declares unused `Imports` on purpose (so the Connect manifest ships them) sets `'"warning"'` to tolerate the resulting NOTE. |
| `skip-pkgdown` | boolean | `false` | DEPRECATED — pkgdown moved to `pkgdown.yaml`. No-op. |
| `revdep-packages` | newline-separated list | `''` | DEPRECATED — moved to `revdep.yaml`. No-op. |

### `revdep.yaml`

| Input | Type | Default | Purpose |
|---|---|---|---|
| `revdep-packages` | newline-separated list | _(required)_ | Downstream packages to reverse-dep check. |

### `pkgdown.yaml`

No inputs.

### `connect-deploy.yaml`

| Input | Type | Default | Purpose |
|---|---|---|---|
| `r-version` | string | `4.4.2` | R version installed from Posit's centos-8 build; becomes `platform` in the manifest, so it must be an R version Connect offers. |
| `repos` | string | `…/centos8/latest` | centos8 PPM binary repo the deps install from, recorded verbatim in the manifest as the repo Connect restores from. Default is the rolling centos8 snapshot; pass a dated snapshot (`…/__linux__/centos8/2026-06-01`) to freeze versions, or an internal mirror serving RHEL 8 binaries. See [Binary installs on Connect](#binary-installs-on-connect). |
| `content-dir` | string | `.` | Directory holding the app and receiving the manifest. |
| `connect-branch-prefix` | string | `connect-` | Target branch is `<prefix><base>`. |
| `auth` | string | `app` | Push identity for `connect-*`. `app`: GitHub App token + protected `environment` (locked `connect-*` via App-on-bypass). `deploy-key`: SSH deploy key + protected `environment` (locked `connect-*` via key-on-bypass, least setup). `token`: the workflow's own `GITHUB_TOKEN`, no App/key/environment/secrets (unprotected `connect-*`). See [Auth modes](#auth-modes). |
| `environment` | string | `connect` | Consumer-side protected environment holding the App or deploy-key credentials (`auth: app` and `deploy-key`). |

Secrets: `APP_ID` / `APP_PRIVATE_KEY` (the deploy GitHub App) are
required in `app` mode; `DEPLOY_KEY` (the SSH private key) is required in
`deploy-key` mode; `token` mode needs none. The caller's `permissions:`
differ by mode (`contents: read` for `app` and `deploy-key`, `contents:
write` for `token`) — see [Auth modes](#auth-modes).

### Example with inputs

```yaml
jobs:
  ci:
    uses: BristolMyersSquibb/blockr.ci/.github/workflows/ci.yaml@main
    with:
      coverage-threshold: 80
      lintr-exclusions: |
        vignettes/foo.qmd
        vignettes/bar.qmd
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
```

## What's included

- **Lint** with a canonical lintr config (`object_name_linter = NULL`) — PR gate
- **Smoke test** — single-platform R CMD check — PR gate
- **pkgdown-dev** — `pkgdown::build_site(devel = TRUE)`, artifact upload, no deploy — PR gate
- **Coverage** via `covr::package_coverage()` + codecov, optional threshold — PR gate
- **Docs freshness** — regenerate `man/` + `NAMESPACE` with the roxygen2 version pinned in `DESCRIPTION` (`Config/roxygen2/version`, or legacy `RoxygenNote`) and fail on drift — PR gate
- **Full check** — 4-platform matrix (macOS, Windows, Ubuntu devel, Ubuntu oldrel) — merge-queue gate
- **Reverse-dependency checks** against configurable downstream packages — merge-queue gate
- **pkgdown deploy** — site build + deploy to `gh-pages` on push to `main`
- **parse-deps** — pin a downstream revdep ref via a `` ```deps `` block in the PR body, read fresh when the merge queue runs revdep
- **connect-deploy** — pull-mode Posit Connect deploys: regenerate the manifest in the merge queue and publish it to a `connect-*` branch Connect polls — separate reusable workflow

## Connect deployment setup

`connect-deploy.yaml` ships only the reusable workflow body. The
configuration below is one-time settings on the deployment repo. Two
layers are load-bearing for security — the `connect-*` ruleset and the
protected environment — and both are explained in full.

### How it works

Connect periodically polls each git-backed content item (default every
15 minutes) and redeploys when the watched branch advances, including
when a PR merges into it. The watched directory must contain a
`manifest.json`, which pins the package set, the R version, and the
content metadata Connect restores from.

For each source branch (`main`, `test`) the workflow maintains a derived
branch `connect-<source>` carrying the app tree plus the regenerated
`manifest.json`. Connect watches the `connect-*` branches, never the
source branches. The manifest is generated and committed from the
`merge_group` job, and `connect-*` is writable by exactly one identity —
the deploy GitHub App.

1. A PR is opened against a source branch. The repo's own validation
   (lint, etc.) runs on `pull_request` and gates queueing.
2. `connect-deploy` runs on `pull_request` as a no-op success, so the PR
   is mergeable, and does its real work only on `merge_group`.
3. Approved + green → added to the merge queue.
4. In the queue, the job checks out the queue ref, derives the target
   `connect-<base>` from `merge_group.base_ref`, sets up R, installs the
   app's dependencies, runs `writeManifest()`, commits, and force-pushes
   to `connect-<base>` using the App token.
5. If that job fails the PR is ejected; otherwise the merge completes and
   Connect picks up `connect-<base>` on its next poll.

Writing from the queue is deliberate: the queue serialises, so
`connect-*` writes never race, and "ejected" is equivalent to "the
commit failed". Keep real validation on the `pull_request` side (or use
batch size 1) so no other check can eject a PR after the push.

### Required-check topology

Each required check does real work in exactly one event and reports a
cheap success in the other, so nothing double-runs:

- The repo's validation (lint, etc.): real on `pull_request`, gated to
  skip on `merge_group` with `if: github.event_name == 'pull_request'`.
- `connect-deploy`: no-op on `pull_request`, real on `merge_group`.

A skipped required check counts as **passed** by the merge queue — that
is what makes the symmetry work, and it is also a footgun: a publish step
skipped on `merge_group` by a too-broad `if` would let the queue merge
having deployed nothing. The workflow guards against this with an
aggregator `guard` job that asserts the publish actually ran. List
`connect-deploy / guard` (not `connect-deploy / deploy`) in the required
checks.

### Auth modes

The `auth` input picks which token pushes `connect-*`. It only chooses
the *pusher*; it cannot enforce whether `connect-*` is locked — that is a
repo-side ruleset the workflow can't reach. So each mode must be paired
with the matching `connect-*` protection, and that pairing is the
consumer's responsibility.

**`app` (default).** Mint a short-lived token from a dedicated GitHub App
and push with it. The caller declares `permissions: contents: read` so
its ambient `GITHUB_TOKEN` stays read-only — the App token does the
write. Pair with the locked `connect-*` ruleset, App, and environment
described below.

**`deploy-key`.** Push `connect-*` over SSH with a repo deploy key. Like
`app`, the key does the write, so the caller declares `permissions:
contents: read`. It gives the same locked-`connect-*` guarantee as the
App — a deploy key is a first-class ruleset bypass actor — with the least
setup (no App to register or install), at the cost of a long-lived key
(manual rotation, no auto-expiry), one per repo, granting repo-wide write
(still constrained by branch rules, so it cannot touch a protected
`main`). Pair with a `connect-*` ruleset that bypasses the deploy key.

**`token`.** Push `connect-*` with the workflow's own `GITHUB_TOKEN` — no
App, no environment, no secrets — and declare `permissions: contents:
write`. For a repo that can't provision a bypass-able identity (an EMU
org where App creation is gated, deploy keys are disabled, fine-grained
PATs are policy-capped), this is the only way to run the pipeline. Pair
with an **unprotected** `connect-*`: anyone with repo write — or any pull
request's own workflow — can then push `connect-*` and thereby deploy, so
integrity rests **entirely** on the *source* branch being protected.
`connect-*` is a derived artifact, and nothing technically guarantees it
only ever holds a build of the source.

The caller's `permissions:` are load-bearing, and they differ by mode
because the *pusher* differs: `token` mode pushes with the ambient
`GITHUB_TOKEN`, so its caller grants `contents: write`; `app` and
`deploy-key` push with the App token / SSH key, so the ambient token only
needs `contents: read`. The reusable workflow itself declares **no**
`permissions:` — a reusable workflow may not request *more* than its
caller grants, so a fixed `contents: write` in the workflow would make
GitHub reject every `read`-granting caller (`app`, `deploy-key`) with a
`startup_failure` before any job runs. Declaring none defers to the
caller, so each mode grants exactly what it needs. Set the caller's
`permissions:` explicitly per the examples — an omitted block falls back
to the repo default, which may not match the mode.

The `connect-*` ruleset and environment sections below apply to both
locked modes (**`app`** and **`deploy-key`**); the GitHub App and deploy
key sections are the per-mode identity setup. In `token` mode you skip
all of them and leave `connect-*` unprotected.

### The `connect-*` ruleset

A single repository ruleset targeting `connect-*`:

- Enable **Restrict creations**, **Restrict updates**, **Restrict
  deletions** — each means "only bypass actors may create / update /
  delete the matching ref".
- Bypass list: the deploy identity only — the App in `app` mode or the
  deploy key in `deploy-key` mode — mode **Always allow** (it pushes
  directly; it does not open PRs).

Nobody but that identity can create, update (including force-push), or
delete any `connect-*` branch. One ruleset covers every derived branch;
adding a source branch later needs no ruleset change.

### Deploy identity — a dedicated GitHub App

In `app` mode, use a dedicated GitHub App (installed in
`BristolMyersSquibb`, `contents: write`), **not** the ambient
`GITHUB_TOKEN` (available to every workflow, so any PR-added workflow
could push) and **not** a PAT (long-lived, broad, burns a seat). The
workflow mints a short-lived installation token via
`actions/create-github-app-token`; the caller declares `permissions:
contents: read` so its ambient `GITHUB_TOKEN` stays read-only. Put the
App on the `connect-*` ruleset bypass.

### Deploy identity — a deploy key

In `deploy-key` mode, generate an `ed25519` keypair, add the **public**
half to the deployment repo as a deploy key with write access, store the
**private** half as the `DEPLOY_KEY` environment secret, and add the
deploy key to the `connect-*` ruleset bypass. `actions/checkout`'s
`ssh-key` input writes the key, points the remote at SSH, and seeds
`known_hosts`, so the push authenticates over SSH and the publish step
stays auth-agnostic. The trade-off vs the App: the key is long-lived
(rotate it manually) and repo-scoped, not a short-lived per-run token.

### Environment scoping — the second layer

Store the deploy credential — the App ID and private key in `app` mode,
or `DEPLOY_KEY` in `deploy-key` mode — as **environment** secrets on a
protected environment (`connect`), not as repo secrets. Set its
deployment-branch policy to allow the queue refs the publisher runs on:
`gh-readonly-queue/main/*` (and `gh-readonly-queue/test/*`, one per
source branch). Environment secrets are released only to jobs that
reference the environment and pass its rules, so only the `merge_group`
publisher can use the credential.

This is the accepted credential-scoping tradeoff: because the queue ref
is `gh-readonly-queue/<base>/*`, the environment must allow that ref
pattern rather than just the source branch. A PR only reaches the queue
after approval and PR checks — the same human gate as merging.

Net: the deploy identity is the only one that can write `connect-*`
(ruleset), and the only thing that can act as it is the queue publisher
(environment). Both layers are load-bearing.

### Source-branch protection + merge queue

Each source branch (`main`, `test`) is fully protected — PR required, no
bypass, no direct push — with a merge queue enabled and the merge method
left as **merge commit**. Required status checks: the repo's validation
plus `connect-deploy / guard`. Connect watches `connect-main` /
`connect-test`, never the source branches.

### Declaring the deploy app's dependencies

The deploy directory is structured like an R package — no `renv`, no
committed lockfile. A `DESCRIPTION` declares runtime dependencies under
`Imports`; the workflow installs them with
`r-lib/actions/setup-r-dependencies` and runs `writeManifest()`.
`rsconnect` is build-time tooling the workflow installs; keep it out of
the `DESCRIPTION`.

`writeManifest()` records a package only when the app's own code
references it. So:

- **Required deps** go in `Imports` — always shipped.
- **Optional two-path deps** (a `requireNamespace()` graceful-degradation
  path) go in `Suggests` — still shipped, because the code names them.
- A package the app **never names** — a transitive / UX-only dep — is
  not auto-detected. Keep it in `Suggests` (so it installs) and add a
  top-level `dependencies.R` containing `requireNamespace("pkg")`, which
  the manifest scanner reads. The helper is scan-only; Connect runs the
  app, not loose scripts.
- **Dev/check tooling** (`testthat`, …) stays in `Suggests` for `R CMD
  check` and is also listed in `Config/Needs/tests`, which the guard
  subtracts so it is neither deployed nor flagged.

After `writeManifest()`, the `check-suggests` action fails the deploy if
a deploy-optional `Suggests` package (Suggests minus `Config/Needs/tests`
minus base packages) is absent from the manifest, with a pointer to the
`requireNamespace()` / `dependencies.R` fix — so a missing optional dep
can't silently never reach Connect. A worked fixture lives at
`.github/actions/tests/fixtures/connect-app`.

### Binary installs on Connect

`writeManifest()` records, per package, the repository Connect restores
from and the platform the package was built for. If that repository is a
*source* repository — or the recorded build platform doesn't match
Connect's — Connect compiles the whole closure from source: slow, and a
hard failure for any package needing a toolchain Connect lacks (e.g. a
Rust package with no `rustc`).

So the deploy job builds the manifest on the **target platform**. It runs
in a fixed `rockylinux:8` container — Rocky 8 is ABI-compatible with RHEL
8, and PPM serves both under the `centos8` slug — installs R from Posit's
centos-8 build, and installs deps from the centos8 PPM. Every package then
records a centos8 binary: `RemotePkgPlatform`
`x86_64-pc-linux-gnu-rocky-8.9`, `RemoteRepos` and `Repository` the
`centos8` URL, `Built` the centos8 R. A RHEL 8.6 Connect restores those
binaries directly, no compiler needed.

Two details keep the recorded URL a *binary* URL:

- The deploy installs from, and records, the `repos` input — the centos8
  PPM (`…/__linux__/centos8/<snapshot>`). RHEL 8.x → `centos8` (there is
  no `rhel8`); RHEL 9 → `rhel9`.
- `writeManifest` runs with renv's PPM rewrite off
  (`RENV_CONFIG_PPM_ENABLED=FALSE`), so renv keeps the literal
  `__linux__/centos8` URL instead of genericising it to a distro-less
  source URL.

The platform is fixed, not a knob — the container image and the disabled
genericisation are correctness properties of a RHEL deploy. To pin
versions, set `repos` to a dated centos8 snapshot, and pick an `r-version`
that PPM publishes centos8 binaries for and that Connect has installed.

### Bootstrap (one-time, manual)

Out of scope for the workflow, done once when wiring up a deployment:
create the Connect content item, point it at the repo + `connect-<base>`
branch + `content-dir`, and configure the Connect-side git read
credential and poll frequency. The first `connect-<base>` branch may need
seeding by one manual queue run before Connect is wired up.

### Footguns

- **The environment must allow `gh-readonly-queue/<base>/*`**, not just
  the source branch, or the publisher cannot reach the credential it
  needs (the App key or the deploy key) in `app` / `deploy-key` mode.
- **No `pull_request_target`** in the deployment repo: it runs on the
  base ref with a PR's context and can satisfy a branch-scoped
  environment, leaking its secrets. The caller pattern here uses plain
  `pull_request`; keep it that way.
- **Runner OS need not match Connect's OS.** The manifest pins package
  versions and the PPM repo URL; Connect restores against that URL with
  its own platform via PPM content negotiation. Only the R version and
  package versions must be resolvable on Connect — pick `r-version` from
  Connect's available Rs.

## Dependency resolution

Non-CRAN dependencies (e.g. other blockr.\* packages, or anything that lives only on GitHub) are declared the standard R way: a `Remotes:` field in `DESCRIPTION`.

```
Package: blockr.dock
Imports:
    blockr.core,
    g6R
Remotes:
    BristolMyersSquibb/blockr.core,
    cynkra/g6R
```

`r-lib/actions/setup-r-dependencies` reads `Remotes:` directly, and so does `pak::local_install()` on a contributor's laptop — CI behavior is exactly what you get locally, no central registry, no implicit overrides.

### Per-PR revdep refs

The deps block in a PR body controls which ref of each revdep gets checked out for the **revdep job** — nothing else. It is not a mechanism for overriding forward dependencies; those belong in `Remotes:` in `DESCRIPTION`.

````markdown
```deps
BristolMyersSquibb/blockr.dag#111
BristolMyersSquibb/blockr.ai@my-feature-branch
```
````

Each line is `owner/repo@branch` or `owner/repo#PR-number`. The matching revdep job checks out that ref instead of the default branch.

`parse-deps` validates each entry against the package's `DESCRIPTION`: if a deps-block entry's package name appears in `Imports`/`Depends`/`LinkingTo`/`Suggests`/`Remotes`, parse-deps fails with a pointer to `Remotes:`. This catches the common mistake of trying to use the deps block to swap in a dev branch of a forward dep.

The revdep job runs only in the merge queue, and it reads the deps block fresh from the PR body each time the queue runs. To change which ref gets checked out, edit the block and re-enqueue — there is no separate re-run trigger.

### Example

You're working on `blockr.dock` and need the revdep job to test against an in-progress PR on `blockr.dag`:

1. Open your PR on `blockr.dock`. The configured `revdep-packages` input includes `BristolMyersSquibb/blockr.dag`, so the revdep job runs against `blockr.dag`'s default branch by default.
2. To pin it to a specific PR, add to the PR body:

   ````markdown
   ```deps
   BristolMyersSquibb/blockr.dag#111
   ```
   ````

3. When the PR is enqueued, the merge-queue revdep job reads the block and checks out `blockr.dag` PR #111 head instead of the default branch.
4. To point at a different PR later, edit the block and re-enqueue.

To override a forward dep (e.g. test against an in-progress `blockr.core` branch), edit `Remotes:` in `DESCRIPTION` instead:

```
Remotes:
    BristolMyersSquibb/blockr.core@my-feature-branch
```

## Secrets

- `BLOCKR_PAT` (optional) — GitHub PAT with access to private blockr repos. Falls back to `GITHUB_TOKEN` if not set, which is sufficient for public repos.
- `CODECOV_TOKEN` — for coverage uploads
