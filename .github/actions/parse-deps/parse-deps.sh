#!/usr/bin/env bash
# Parse the ```deps block from a PR body. Bash side handles only the parts
# that are easier in bash (env wrangling, fresh PR-body fetch, deps-block
# extraction); everything that involves package metadata is delegated to
# parse-deps.R, which uses pkgdepends (the tool that owns the syntax).
#
# Env vars: PR_BODY, PR_NUMBER, GH_TOKEN, PKG, BASE_PACKAGES, GITHUB_OUTPUT,
#           SCRIPT_DIR

set -euo pipefail

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Under the merge queue there is no pull_request payload, so callers pass an
# empty PR_NUMBER. Recover it from the queue ref, whose shape is
# refs/heads/gh-readonly-queue/<base>/pr-<N>-<sha>, so the fresh-body fetch
# below still fires (this is the only context the revdep job runs in).
if [[ -z "${PR_NUMBER:-}" && "${GITHUB_REF:-}" =~ gh-readonly-queue/.+/pr-([0-9]+)- ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi

if [[ -n "${PR_NUMBER:-}" && -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  fresh_body=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq '.body' 2>/dev/null || true)
  if [[ -n "$fresh_body" ]]; then
    PR_BODY="$fresh_body"
  fi
fi

# Extract the deps block, strip fences and blanks, leave one entry per line.
DEPS_LINES=$(echo "${PR_BODY:-}" | tr -d '\r' \
  | sed -n '/^```deps$/,/^```$/p' \
  | grep -v '^```' \
  | sed '/^[[:space:]]*$/d' || true)

# Auto-detect DESCRIPTION. Most jobs check the package out at the repo root;
# the revdep job checks it out under ./pkg.
DESC_PATH=""
for candidate in DESCRIPTION pkg/DESCRIPTION; do
  if [[ -f "$candidate" ]]; then
    DESC_PATH="$candidate"
    break
  fi
done

export DEPS_LINES DESC_PATH
export PKG="${PKG:-}"
export BASE_PACKAGES="${BASE_PACKAGES:-}"
export GITHUB_OUTPUT="${GITHUB_OUTPUT:-}"

Rscript --no-save --no-restore "$SCRIPT_DIR/parse-deps.R"
