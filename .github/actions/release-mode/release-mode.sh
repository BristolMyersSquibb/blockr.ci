#!/usr/bin/env bash
# Report whether the pull request behind this run carries the release label.
#
# The label is read from the API rather than the event payload, for two
# reasons. Under the merge queue there is no pull_request payload at all, and
# on a pull_request event the payload can be stale -- the label may have been
# applied between the push and this run, which is exactly the case that
# matters here. The same fresh-read argument parse-deps.sh makes for the PR
# body.
#
# Env vars: LABEL, PR_NUMBER, GH_TOKEN, GITHUB_REF, GITHUB_REPOSITORY,
#           GITHUB_OUTPUT

set -euo pipefail

: "${LABEL:=release}"

# Under the merge queue there is no pull_request payload, so callers pass an
# empty PR_NUMBER. Recover it from the queue ref, whose shape is
# refs/heads/gh-readonly-queue/<base>/pr-<N>-<sha>.
if [[ -z "${PR_NUMBER:-}" && "${GITHUB_REF:-}" =~ gh-readonly-queue/.+/pr-([0-9]+)- ]]; then
  PR_NUMBER="${BASH_REMATCH[1]}"
fi

# Failing closed here would be the wrong direction: `false` reproduces the
# behaviour these workflows had before release mode existed -- the check
# matrix and the reverse-dependency legs run at the queue, and no expensive
# release leg fires. A lookup that cannot answer therefore costs a redundant
# run, never a skipped check.
is_release=false

if [[ -n "${PR_NUMBER:-}" && -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  if labels=$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" \
                --jq '.labels[].name' 2>/dev/null); then
    if grep -qxF -- "$LABEL" <<<"$labels"; then
      is_release=true
    fi
  else
    echo "::warning::Could not read labels for pull request #${PR_NUMBER}; treating this as an ordinary run."
  fi
fi

echo "Release mode: ${is_release} (pull request '${PR_NUMBER:-none}', label '${LABEL}')"
echo "is-release=${is_release}" >> "$GITHUB_OUTPUT"
