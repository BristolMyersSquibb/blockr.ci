#!/usr/bin/env bash
# Works out what the image holds, for the plan job of image.yaml.
#
# The repos are the public repos of ORG whose branch BRANCH holds a
# DESCRIPTION at its root, as one GraphQL query lists them.  Only public
# ones count, because the build installs the package of each repo into the
# image, and the image is public.  Archived repos run no CI, so they are
# left out as well.  Finding none is an error, so that a failed query
# leaves the image of the day before in place.
#
# The extra packages are the any:: refs that CI_YAML installs, together
# with FIXED_PACKAGES, which the steps of blockr.ci install themselves.
# The needs are the values that CI_YAML passes as `needs:` to
# setup-r-dependencies or install-deps.
#
# Env vars: ORG, BRANCH, CI_YAML, FIXED_PACKAGES, GITHUB_OUTPUT
# Outputs, each separated by spaces: repos, as owner/repo@branch,
# packages, the pak refs to install, and needs.

set -euo pipefail
export LC_ALL=C

query='
query($org: String!, $ref: String!, $endCursor: String) {
  organization(login: $org) {
    repositories(first: 100, after: $endCursor, privacy: PUBLIC) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        isArchived
        ref(qualifiedName: $ref) {
          target { ... on Commit { file(path: "DESCRIPTION") { name } } }
        }
      }
    }
  }
}'

repos=$(gh api graphql --paginate -F org="$ORG" -F ref="refs/heads/$BRANCH" -f query="$query" |
  jq -r --arg branch "$BRANCH" '.data.organization.repositories.nodes[] |
    select((.isArchived | not) and .ref.target.file != null) |
    "\(.nameWithOwner)@\($branch)"' |
  sort -u)

if [ -z "$repos" ]; then
  echo "::error::Found no public repo of $ORG whose branch $BRANCH holds a DESCRIPTION."
  exit 1
fi

extra=$(grep -oE 'any::[A-Za-z0-9.]+' "$CI_YAML" | sort -u)

# A needs: line counts only inside a step that uses setup-r-dependencies
# or install-deps, and not as the needs: of a job.  A step runs from its
# "- " line to the next line that is indented no deeper.
needs=$(awk '
  NF == 0 { next }
  { match($0, /^ */); indent = RLENGTH }
  /^[[:space:]]*- / {
    step_indent = indent
    in_step = ($0 ~ /uses:.*(setup-r-dependencies|install-deps)/)
    next
  }
  indent <= step_indent { in_step = 0 }
  /^[[:space:]]+uses:.*(setup-r-dependencies|install-deps)/ { in_step = 1 }
  in_step && /^[[:space:]]+needs:[[:space:]]*[A-Za-z]/ { print $2 }
' "$CI_YAML" | sort -u)

packages=$(printf '%s\n' $repos $extra $FIXED_PACKAGES | sed '/^$/d' | awk '!seen[$0]++')

join() { printf '%s\n' "$@" | sed '/^$/d' | paste -sd ' ' -; }

echo "The image holds these repos: $(join $repos)"
echo "It adds these packages: $(join $extra $FIXED_PACKAGES)"
echo "And installs these Config/Needs fields: $(join $needs)"

{
  echo "repos=$(join $repos)"
  echo "packages=$(join $packages)"
  echo "needs=$(join $needs)"
} >> "$GITHUB_OUTPUT"
