# blockr.ci

[![ci](https://github.com/cynkra/blockr.ci/actions/workflows/ci.yaml/badge.svg)](https://github.com/cynkra/blockr.ci/actions/workflows/ci.yaml)

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
    uses: cynkra/blockr.ci/.github/workflows/ci.yaml@main
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
    uses: cynkra/blockr.ci/.github/workflows/pkgdown.yaml@main
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
    uses: cynkra/blockr.ci/.github/workflows/ci.yaml@main
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
  revdep:
    if: github.event_name == 'merge_group'
    uses: cynkra/blockr.ci/.github/workflows/revdep.yaml@main
    with:
      revdep-packages: |
        BristolMyersSquibb/blockr.dock
    secrets:
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
```

### `deps-rerun.yaml` — re-run deps-affected jobs on PR-body edit

```yaml
on:
  pull_request:
    branches: main
    types: [edited]

name: deps-rerun

jobs:
  rerun:
    uses: cynkra/blockr.ci/.github/workflows/deps-rerun.yaml@main
    secrets:
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
```

Pass secrets by name. `secrets: inherit` does not forward secrets
across organisations — the inherited values silently arrive blank in
the called job.

## Pipeline

| Trigger | Jobs |
|---|---|
| `pull_request` | `lint`, `smoke`, `pkgdown-dev`, `coverage` (parallel) |
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
| `skip-pkgdown` | boolean | `false` | DEPRECATED — pkgdown moved to `pkgdown.yaml`. No-op. |
| `revdep-packages` | newline-separated list | `''` | DEPRECATED — moved to `revdep.yaml`. No-op. |

### `revdep.yaml`

| Input | Type | Default | Purpose |
|---|---|---|---|
| `revdep-packages` | newline-separated list | _(required)_ | Downstream packages to reverse-dep check. |

### `pkgdown.yaml`

No inputs.

### Example with inputs

```yaml
jobs:
  ci:
    uses: cynkra/blockr.ci/.github/workflows/ci.yaml@main
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
- **Full check** — 4-platform matrix (macOS, Windows, Ubuntu devel, Ubuntu oldrel) — merge-queue gate
- **Reverse-dependency checks** against configurable downstream packages — merge-queue gate
- **pkgdown deploy** — site build + deploy to `gh-pages` on push to `main`
- **parse-deps** — override dependency versions via a `` ```deps `` block in the PR body
- **deps-rerun** — automatically re-run affected jobs when the deps block changes

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

When the deps block changes, the **deps-rerun** workflow re-runs the deps-affected jobs (lint, smoke, pkgdown-dev, coverage, revdep) without needing a new push.

### Example

You're working on `blockr.dock` and need the revdep job to test against an in-progress PR on `blockr.dag`:

1. Open your PR on `blockr.dock`. The configured `revdep-packages` input includes `BristolMyersSquibb/blockr.dag`, so the revdep job runs against `blockr.dag`'s default branch by default.
2. To pin it to a specific PR, add to the PR body:

   ````markdown
   ```deps
   BristolMyersSquibb/blockr.dag#111
   ```
   ````

3. The revdep job checks out `blockr.dag` PR #111 head instead.
4. If you later change the deps block (e.g., point to a different PR), the affected jobs re-run automatically.

To override a forward dep (e.g. test against an in-progress `blockr.core` branch), edit `Remotes:` in `DESCRIPTION` instead:

```
Remotes:
    BristolMyersSquibb/blockr.core@my-feature-branch
```

## Secrets

- `BLOCKR_PAT` (optional) — GitHub PAT with access to private blockr repos. Falls back to `GITHUB_TOKEN` if not set, which is sufficient for public repos.
- `CODECOV_TOKEN` — for coverage uploads
