# blockr.ci

[![ci](https://github.com/cynkra/blockr.ci/actions/workflows/ci.yaml/badge.svg)](https://github.com/cynkra/blockr.ci/actions/workflows/ci.yaml)

Reusable GitHub Actions CI workflows for the [blockr](https://bristolmyerssquibb.github.io/blockr-site/) ecosystem.

## Usage

Replace your repo's `.github/workflows/` contents with two files:

### `.github/workflows/ci.yaml`

```yaml
on:
  push:
    branches: main
  pull_request:
  merge_group:

jobs:
  ci:
    uses: cynkra/blockr.ci/.github/workflows/ci.yaml@main
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
    permissions:
      contents: write
```

Leave the `pull_request:` trigger unfiltered. Adding `branches: main`
silently disables CI for stacked PRs (PRs whose base is another feature
branch) — they get no lint, no smoke, no signal at all until the base
is retargeted to `main`.

### `.github/workflows/deps-rerun.yaml`

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

```
lint → smoke → check       (merge queue + push to main)
             → coverage    (merge queue + push to main)
             → revdep      (pull request, if configured)
             → pkgdown     (merge queue + push to main; deploys on push)
```

`lint` and `smoke` run on every event (pull request, merge queue, push
to main). The remaining jobs only run where listed — pull requests are
deliberately kept to the cheap gate.

All steps are mandatory — a consumer gets the full pipeline or none of it.

### Merge queue

Without GitHub's merge queue enabled, `merge_group` events never fire,
and the expensive jobs (`check`, `coverage`, `pkgdown`) only run on the
`push` event — that is, *after* the PR has merged into `main`. A green
PR can then produce a red `main` when one of the matrix platforms
fails. Enabling the merge queue closes that gap: the queue runs the
full pipeline against the would-be merge commit and blocks the merge
on failure.

To enable, in the consumer repo's branch protection settings for `main`:

1. **Require a pull request before merging**.
2. **Require status checks to pass** — mark `lint`, `smoke`, `check`,
   `coverage`, and (if configured) `pkgdown` as required.
3. **Require merge queue** — leave the merge method as **merge commit**
   (squash and rebase strip the merge metadata downstream branches use
   to stay aligned).

Stacked PRs (PRs whose base is not `main`) still merge as plain pushes
to the parent feature branch and bypass the queue — that is intentional;
the queue is reserved for `main`.

## Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `revdep-packages` | newline-separated list | `''` | Downstream packages to reverse-dep check. Empty skips the job. |
| `lintr-exclusions` | newline-separated list | `''` | File paths to exclude from linting |
| `skip-pkgdown` | boolean | `false` | Skip pkgdown for repos with custom site builds |

### Example with all inputs

```yaml
jobs:
  ci:
    uses: cynkra/blockr.ci/.github/workflows/ci.yaml@main
    with:
      revdep-packages: |
        cynkra/blockr.dock
        cynkra/blockr.dag
      lintr-exclusions: |
        vignettes/foo.qmd
        vignettes/bar.qmd
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
      BLOCKR_PAT: ${{ secrets.BLOCKR_PAT }}
    permissions:
      contents: write
```

## What's included

- **Lint** with a canonical lintr config (`object_name_linter = NULL`)
- **Smoke test** — single-platform R CMD check (PR gate)
- **Full check** — 4-platform matrix (macOS, Windows, Ubuntu devel, Ubuntu oldrel), merge queue + push
- **Coverage** via covr + codecov, merge queue + push (not PR)
- **Reverse-dependency checks** against configurable downstream packages (PR only)
- **pkgdown** site build + deploy to gh-pages
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

When the deps block changes, the **deps-rerun** workflow re-runs the smoke and revdep jobs without needing a new push.

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
