#!/usr/bin/env bash
# Audits the lockfiles of the callers of the typescript job of ci.yaml,
# for audit.yaml.
#
# A caller is a public repo of ORG with a workflow on one of BRANCHES that
# sets typescript-dir, the input that turns the typescript job on.
# One GraphQL query per branch reads the workflows of every public repo.
# It asks for the directory with object(expression:), which is null where
# the branch or the directory is missing.
# The file(path:) field that packages.sh uses raises an error there
# instead, and gh fails on it.
# Archived repos run no CI, so they are left out.
# The lockfile of a caller is the package-lock.json in its typescript-dir,
# which the typescript job installs with npm ci.
# Finding no caller is an error, so that a broken query does not pass for
# a clean audit.
#
# Each lockfile gets `npm audit --package-lock-only --audit-level=high`.
# The audit checks the lockfile against the advisories that the npm
# registry serves, and installs nothing.
# It runs on the lockfile alone, without the package.json beside it,
# since npm ci installs what the lockfile names.
# The exit status of npm says only that it found an advisory or failed, so
# its JSON report tells the two apart.
# Each advisory of high or critical severity fails the run, and the job
# summary lists it with the repo, the branch, the package and its version.
# The version comes from the lockfile, at each path where the package is
# installed.
# A package that is flagged only through a dependency gets no row of its
# own, since the row of that dependency names the advisory.
# A lockfile that cannot be downloaded or audited fails the run as well.
#
# Env vars: ORG, BRANCHES, RUNNER_TEMP, GITHUB_STEP_SUMMARY

set -euo pipefail
export LC_ALL=C

query='
query($org: String!, $expression: String!, $endCursor: String) {
  organization(login: $org) {
    repositories(first: 100, after: $endCursor, privacy: PUBLIC) {
      pageInfo { hasNextPage endCursor }
      nodes {
        nameWithOwner
        isArchived
        object(expression: $expression) {
          ... on Tree { entries { object { ... on Blob { text } } } }
        }
      }
    }
  }
}'

# A line that sets typescript-dir, and not one inside a comment.
setting="^[[:space:]]*typescript-dir:[[:space:]]*[\"']?(?<dir>[^\"'#[:space:]]+)"

# Prints the repo, the branch and the path of each lockfile, one per line.
find_lockfiles='
  .data.organization.repositories.nodes[] |
  select(.isArchived | not) |
  .nameWithOwner as $repo |
  .object.entries[]?.object.text // empty |
  split("\n")[] |
  capture($setting).dir |
  sub("^(\\./)+"; "") | sub("/+$"; "") |
  (if . == "." or . == "" then "" else "\(.)/" end) as $dir |
  "\($repo) \($branch) \($dir)package-lock.json"'

# Prints how many vulnerable packages npm counts at each severity.
count_by_severity='
  .metadata.vulnerabilities as $n |
  [("critical", "high", "moderate", "low", "info") |
    select(($n[.] // 0) > 0) | "\($n[.]) \(.)"] |
  if length == 0 then "no advisory" else join(", ") end'

# Prints a row of the summary table for each advisory of high or critical
# severity.
list_findings='
  .vulnerabilities[] |
  .name as $name |
  ([.nodes[]? as $node | $lock[0].packages[$node].version // empty] |
    unique | join(", ")) as $versions |
  .via[] | objects |
  select(.severity == "high" or .severity == "critical") |
  (.url // "") as $url |
  ($url | sub(".*/"; "")) as $id |
  (.title // "" | gsub("\\|"; "\\|")) as $title |
  "| \($repo) | \($branch) | \($name) | \($versions) | \(.severity) | [\($id)](\($url)) \($title) |"'

lockfiles=""
for branch in $BRANCHES; do
  reply=$(gh api graphql --paginate -F org="$ORG" \
    -f expression="refs/heads/$branch:.github/workflows" -f query="$query")
  lockfiles+=$(jq -r --arg branch "$branch" --arg setting "$setting" \
    "$find_lockfiles" <<< "$reply")
  lockfiles+=$'\n'
done
lockfiles=$(sed '/^$/d' <<< "$lockfiles" | sort -u)

if [ -z "$lockfiles" ]; then
  echo "::error::Found no public repo of $ORG with a workflow on ${BRANCHES// / or } that sets typescript-dir."
  exit 1
fi

echo "Auditing these lockfiles:"
echo "$lockfiles"

mapfile -t lockfiles <<< "$lockfiles"

failed=0
errors=0
results=()
findings=()

for lockfile in "${lockfiles[@]}"; do
  read -r repo branch path <<< "$lockfile"
  echo "::group::$repo@$branch: $path"
  dir=$(mktemp -d "$RUNNER_TEMP/audit.XXXXXX")

  if ! gh api -H 'Accept: application/vnd.github.raw' \
    "repos/$repo/contents/$path?ref=$branch" > "$dir/package-lock.json"; then
    echo "::endgroup::"
    echo "::error::Could not download $path of $repo@$branch."
    results+=("| $repo | $branch | $path | Download failed |")
    failed=1
    errors=1
    continue
  fi

  npm audit --package-lock-only --audit-level=high --json --prefix "$dir" \
    > "$dir/audit.json" || true

  if ! jq -e '.vulnerabilities | type == "object"' "$dir/audit.json" > /dev/null 2>&1; then
    cat "$dir/audit.json"
    message=$(jq -r '.message // .error.summary // empty' "$dir/audit.json" 2> /dev/null || true)
    echo "::endgroup::"
    echo "::error::The audit of $path of $repo@$branch failed${message:+: $message}"
    results+=("| $repo | $branch | $path | Audit failed |")
    failed=1
    errors=1
    continue
  fi

  count=$(jq -r "$count_by_severity" "$dir/audit.json")
  echo "$count"
  results+=("| $repo | $branch | $path | $count |")

  found=$(jq -r --arg repo "$repo" --arg branch "$branch" \
    --slurpfile lock "$dir/package-lock.json" "$list_findings" "$dir/audit.json")
  echo "::endgroup::"

  if [ -n "$found" ]; then
    echo "$found"
    echo "::error::The lockfile $path of $repo@$branch holds versions with $(grep -c '' <<< "$found") advisories of high or critical severity."
    findings+=("$found")
    failed=1
  fi
done

{
  echo "## Audit of the lockfiles of the typescript job's callers"
  echo
  echo "| Repository | Branch | Lockfile | Result |"
  echo "| --- | --- | --- | --- |"
  printf '%s\n' "${results[@]}"
  echo
  if [ "${#findings[@]}" -gt 0 ]; then
    echo "### Advisories of high or critical severity"
    echo
    echo "| Repository | Branch | Package | Version | Severity | Advisory |"
    echo "| --- | --- | --- | --- | --- | --- |"
    printf '%s\n' "${findings[@]}"
  elif [ "$errors" -eq 0 ]; then
    echo "No version in these lockfiles has an advisory of high or critical severity."
  fi
} >> "$GITHUB_STEP_SUMMARY"

exit "$failed"
