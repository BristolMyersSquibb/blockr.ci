#!/usr/bin/env bash
# Works out what the image holds, for the plan job of image.yaml.
#
# The repos are the public repos of ORG whose branch BRANCH holds a
# DESCRIPTION at its root, as one GraphQL query lists them.  Only public
# ones count, because the image is public, and it holds what the package
# of each repo depends on.  Archived repos run no CI, so they are
# left out as well.  Finding none is an error, so that a failed query
# leaves the image of the day before in place.
#
# A package counts as one of ORG when a public repo of ORG has the same
# name.
# A package of ORG can reach the image as a dependency of another one,
# from CRAN or from a branch other than BRANCH.
# So every public repo counts here, archived or not, and with BRANCH or
# without.
# The build installs these packages with the rest and then removes them,
# so that the image holds none of them.
#
# The extra packages and the needs come from the workflows in WORKFLOW_DIR
# that run a job in IMAGE, the ones with a `container:` line that names it.
# The extra packages are the any:: refs that those workflows install,
# together with FIXED_PACKAGES, which the steps of blockr.ci install
# themselves.
# The needs are the values that those workflows pass as `needs:` to
# setup-r-dependencies or install-deps.
# Finding no such workflow is an error too.
#
# Env vars: ORG, BRANCH, WORKFLOW_DIR, IMAGE, FIXED_PACKAGES, GITHUB_OUTPUT
# Outputs, each separated by spaces: repos, as owner/repo@branch,
# packages, the pak refs to install, needs, and org-packages, the names
# of the public repos of ORG.

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

reply=$(gh api graphql --paginate -F org="$ORG" -F ref="refs/heads/$BRANCH" -f query="$query")

repos=$(jq -r --arg branch "$BRANCH" '.data.organization.repositories.nodes[] |
    select((.isArchived | not) and .ref.target.file != null) |
    "\(.nameWithOwner)@\($branch)"' <<< "$reply" |
  sort -u)

if [ -z "$repos" ]; then
  echo "::error::Found no public repo of $ORG whose branch $BRANCH holds a DESCRIPTION."
  exit 1
fi

org_packages=$(jq -r '.data.organization.repositories.nodes[].nameWithOwner |
    sub("^[^/]*/"; "")' <<< "$reply" |
  sort -u)

mapfile -t workflows < <(grep -lE "^[[:space:]]*container:.*${IMAGE//./\\.}" "$WORKFLOW_DIR"/*.yaml || true)

if [ "${#workflows[@]}" -eq 0 ]; then
  echo "::error::Found no workflow in $WORKFLOW_DIR that runs a job in $IMAGE."
  exit 1
fi

extra=$(grep -ohE 'any::[A-Za-z0-9.]+' "${workflows[@]}" | sort -u)

# A needs: line counts only inside a step that uses setup-r-dependencies
# or install-deps, and not as the needs: of a job.  A step runs from its
# "- " line to the next line that is indented no deeper.
# Each workflow starts outside any step.
needs=$(awk '
  FNR == 1 { in_step = 0; step_indent = 0 }
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
' "${workflows[@]}" | sort -u)

packages=$(printf '%s\n' $repos $extra $FIXED_PACKAGES | sed '/^$/d' | awk '!seen[$0]++')

join() { printf '%s\n' "$@" | sed '/^$/d' | paste -sd ' ' -; }

echo "The image is built for these repos: $(join $repos)"
echo "It takes its extra packages from these workflows: $(join "${workflows[@]##*/}")"
echo "It adds these packages: $(join $extra $FIXED_PACKAGES)"
echo "And installs these Config/Needs fields: $(join $needs)"
echo "It holds no package named after one of these repos of $ORG: $(join $org_packages)"

{
  echo "repos=$(join $repos)"
  echo "packages=$(join $packages)"
  echo "needs=$(join $needs)"
  echo "org-packages=$(join $org_packages)"
} >> "$GITHUB_OUTPUT"
