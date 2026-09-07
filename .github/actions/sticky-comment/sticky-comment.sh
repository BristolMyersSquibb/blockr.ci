#!/usr/bin/env bash
# Rewrite one pull-request comment, identified by an HTML-comment marker.
#
# Creates the comment on the first run and edits it in place after, so a
# workflow that reports on every push leaves one comment describing the
# head commit rather than a thread of stale ones nobody reads to the end
# of.
#
# Written against `gh api` rather than a third-party sticky-comment
# action: a marker grep and one PATCH is a better trade than another
# supply-chain edge in a workflow every repository in the fleet calls.
#
# Failing to write is a warning, not an error. Commenting needs
# `pull-requests: write`, and on a pull request from a fork the token is
# read-only whatever the caller declares -- so a workflow that also
# writes $GITHUB_STEP_SUMMARY keeps its output either way, and a missing
# grant should not redden an otherwise-good run.
#
# Env vars: MARKER, BODY_FILE, PR_NUMBER, GITHUB_REPOSITORY, GH_TOKEN

set -euo pipefail

: "${MARKER:?sticky-comment: MARKER is required}"
: "${BODY_FILE:?sticky-comment: BODY_FILE is required}"

if [[ ! -f "$BODY_FILE" ]]; then
  echo "::error::sticky-comment: no body file at '$BODY_FILE'." >&2
  exit 1
fi

if [[ -z "${PR_NUMBER:-}" ]]; then
  echo "::warning::sticky-comment: no pull-request number, so there is nothing to comment on."
  exit 0
fi

# The marker has to lead the body for the next run to find it again;
# prepending it here keeps that contract out of every caller.
body=$(mktemp)
if [[ "$(head -n 1 "$BODY_FILE")" == "$MARKER" ]]; then
  cat "$BODY_FILE" > "$body"
else
  {
    printf '%s\n' "$MARKER"
    cat "$BODY_FILE"
  } > "$body"
fi

# The `--paginate` flag applies the filter per page, so a match on page
# two arrives as a second line, and `head -n1` keeps the oldest marked
# comment as the one true sticky. A null body -- which a hidden comment
# can have -- would abort the filter, hence the `// ""`.
existing="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
  --paginate \
  --jq "map(select((.body // \"\") | startswith(\"$MARKER\"))) | .[0].id // empty" \
  2>/dev/null | head -n 1 || true)"

if [[ -n "$existing" ]]; then
  method=PATCH
  endpoint="repos/$GITHUB_REPOSITORY/issues/comments/$existing"
else
  method=POST
  endpoint="repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments"
fi

# Built with jq rather than `-f body=...` so a body holding quotes,
# backticks or newlines survives the trip intact.
if jq -n --rawfile body "$body" '{body: $body}' \
     | gh api --method "$method" "$endpoint" --input - > /dev/null; then
  echo "sticky-comment: comment written ($method)."
else
  echo "::warning::sticky-comment: could not write the comment. Grant the caller 'pull-requests: write' -- on a fork pull request the token is read-only regardless."
fi
