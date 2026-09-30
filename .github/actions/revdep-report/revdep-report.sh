#!/usr/bin/env bash
# Compose the pull-request comment for revdep.yaml's informational tier.
#
# One row per downstream in PACKAGES, from the outcome its leg left in
# OUTCOMES_DIR. A leg that did not pass also gets the workflow runs at the
# head of the downstream's own default branch, so a failure the downstream
# already has reads as such rather than as something the pull request
# broke.
#
# The outcome files are written after the downstream's own code has run,
# so they are read as data: the rows come from PACKAGES, a status has to
# be one that job.status can take, and a job id has to be a number, or
# the leg is reported as having no result.
#
# A downstream whose runs cannot be read -- a private repository the
# token has no Actions access to, say -- gets a note saying so rather than
# failing the report, which informs and gates nothing.
#
# Env vars: PACKAGES, OUTCOMES_DIR, BODY_FILE, GH_TOKEN, GITHUB_SERVER_URL,
#           GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SHA, GITHUB_STEP_SUMMARY

set -euo pipefail

: "${PACKAGES:?revdep-report: PACKAGES is required}"
: "${BODY_FILE:?revdep-report: BODY_FILE is required}"

server="${GITHUB_SERVER_URL:-https://github.com}"
repo_url="$server/${GITHUB_REPOSITORY:-}"
run_url="$repo_url/actions/runs/${GITHUB_RUN_ID:-}"
sha="${GITHUB_SHA:-}"

# A pipe ends a table cell and a bracket ends a link's text, so both are
# escaped in anything a downstream names.
escape='gsub("(?<c>[|\\[\\]])"; "\\\(.c)")'

# Every outcome file as one array. A file that is not a JSON object is
# skipped, which leaves its leg without a result.
outcomes=$(
  for file in "${OUTCOMES_DIR:-.}"/*.json; do
    if [[ -f "$file" ]]; then
      jq -c 'select(type == "object")' "$file" 2>/dev/null || true
    fi
  done | jq -s '.'
)

# The runs at the head of a downstream's default branch, which HEAD
# names on the API, as "`abc1234`: [ci](url) success, [pkgdown](url)
# success".
own_branch() {
  local pkg=$1 head runs
  if ! head=$(gh api "repos/$pkg/commits/HEAD" 2>/dev/null | jq -er '.sha') ||
     ! runs=$(gh api "repos/$pkg/actions/runs?head_sha=$head&per_page=100" 2>/dev/null |
                jq -er ".workflow_runs
                  | map(\"[\(.name | $escape)](\(.html_url)) \(.conclusion // .status | gsub(\"_\"; \" \"))\")
                  | join(\", \")"); then
    echo "its runs could not be read"
    return 0
  fi
  echo "[\`${head:0:7}\`]($server/$pkg/commit/$head): ${runs:-no workflow run}"
}

rows=""
total=0
failed=0

while IFS= read -r pkg; do
  total=$((total + 1))

  outcome=$(jq -c --arg pkg "$pkg" '
    (map(select(.pkg == $pkg)) | first) // {}
    | {
        status: ((.status | select(IN("success", "failure", "cancelled"))) // ""),
        job: ((.job | tostring | select(test("^[0-9]+$"))) // "")
      }' <<< "$outcomes")
  status=$(jq -r '.status' <<< "$outcome")
  job=$(jq -r '.job' <<< "$outcome")

  link="$run_url"
  if [[ -n "$job" ]]; then
    link="$run_url/job/$job"
  fi

  case "$status" in
    success)   icon=":white_check_mark:" ;;
    failure)   icon=":x:" ;;
    cancelled) icon=":warning:" ;;
    *)         icon=":warning:"; status="no result" ;;
  esac

  own=""
  if [[ "$status" != success ]]; then
    failed=$((failed + 1))
    own=$(own_branch "$pkg")
  fi

  rows+="| \`$pkg\` | $icon [$status]($link) | $own |"$'\n'
done < <(jq -r '.[]' <<< "$PACKAGES")

if (( total == 0 )); then
  echo "::error::revdep-report: PACKAGES lists no downstream to report on." >&2
  exit 1
fi

if (( failed == 0 )); then
  headline=":white_check_mark: **Every informational downstream passes against this commit.**"
else
  headline=":x: **Informational downstreams not passing against this commit: $failed of $total.**"
fi

{
  echo "## Informational reverse-dependency checks — [\`${sha:0:7}\`]($repo_url/commit/$sha)"
  echo
  echo "$headline"
  echo
  echo "| Downstream | Result | Its own default branch |"
  echo "| --- | --- | --- |"
  printf '%s' "$rows"
  echo
  echo "These downstreams are checked in the merge queue the same way as the ones behind \`revdep-all\`, but none of them holds the merge. For a leg that did not pass, the last column gives the downstream's own workflow runs at the head of its default branch. If those fail as well, the failure likely predates this pull request."
  echo
  echo "<sub>Rewritten by \`revdep\` on every merge-queue run of this pull request. It is posted once [the run]($run_url) has finished every informational leg, which can be after the merge.</sub>"
} > "$BODY_FILE"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$BODY_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

echo "revdep-report: $failed of $total informational downstreams not passing."
