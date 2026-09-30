#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../revdep-report/revdep-report.sh"
  cd "$BATS_TEST_TMPDIR"

  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="acme/widget"
  export GITHUB_RUN_ID=99
  export GITHUB_SHA="0123456789abcdef0123456789abcdef01234567"
  # Blanked because the bats job itself runs inside Actions, where this
  # is set: without it every test would append its report to the real
  # step summary.
  export GITHUB_STEP_SUMMARY=""
  export PACKAGES='["acme/one","acme/two"]'
  export OUTCOMES_DIR="$BATS_TEST_TMPDIR/outcomes"
  export BODY_FILE="$BATS_TEST_TMPDIR/comment.md"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$OUTCOMES_DIR" "$GH_FIXTURES"

  # A gh that answers `gh api <endpoint>` from a fixture file named after
  # the endpoint, and fails, as the API would, on one it has none for.
  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
key=$(printf '%s' "$2" | tr '/?=&' '____')
if [ "$1" = api ] && [ -f "$GH_FIXTURES/$key" ]; then
  cat "$GH_FIXTURES/$key"
else
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
STUB
  chmod +x bin/gh
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH
}

HEAD_SHA=7a8341da20c35c18ccd2ce16f5d19f75bbbe870e

# What a leg's recording step writes: outcome <file> <pkg> <status> <job>.
outcome() {
  jq -n --arg pkg "$2" --arg status "$3" --arg job "$4" \
    '{pkg: $pkg, status: $status, job: $job}' > "$OUTCOMES_DIR/$1.json"
}

# The head of a downstream's default branch, and the runs on it:
# own_runs <pkg> <workflow_runs array>.
own_runs() {
  local key
  key=$(printf '%s' "repos/$1/commits/HEAD" | tr '/?=&' '____')
  printf '{"sha": "%s"}' "$HEAD_SHA" > "$GH_FIXTURES/$key"
  key=$(printf '%s' "repos/$1/actions/runs?head_sha=$HEAD_SHA&per_page=100" | tr '/?=&' '____')
  printf '{"workflow_runs": %s}' "$2" > "$GH_FIXTURES/$key"
}

report() {
  run bash "$SCRIPT"
}

@test "every leg passes: a row each, and no downstream is looked up" {
  outcome 0 acme/one success 11
  outcome 1 acme/two success 12

  report
  assert_success

  run cat "$BODY_FILE"
  assert_line --index 0 '## Informational reverse-dependency checks — [`0123456`](https://github.com/acme/widget/commit/0123456789abcdef0123456789abcdef01234567)'
  assert_output --partial "Every informational downstream passes against this commit."
  assert_output --partial '| `acme/one` | :white_check_mark: [success](https://github.com/acme/widget/actions/runs/99/job/11) |  |'
  assert_output --partial '| `acme/two` | :white_check_mark: [success](https://github.com/acme/widget/actions/runs/99/job/12) |  |'

  # No log file at all is the proof that gh was never reached.
  run test -e "$GH_LOG"
  assert_failure
}

@test "a failing leg links its log and gives the downstream's own runs" {
  outcome 0 acme/one success 11
  outcome 1 acme/two failure 12
  own_runs acme/two '[
    {"name": "pkgdown", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme/two/actions/runs/2"},
    {"name": "ci", "status": "completed", "conclusion": "failure", "html_url": "https://github.com/acme/two/actions/runs/1"}
  ]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial "Informational downstreams not passing against this commit: 1 of 2."
  assert_output --partial "| \`acme/two\` | :x: [failure](https://github.com/acme/widget/actions/runs/99/job/12) | [\`7a8341d\`](https://github.com/acme/two/commit/$HEAD_SHA): [pkgdown](https://github.com/acme/two/actions/runs/2) success, [ci](https://github.com/acme/two/actions/runs/1) failure |"

  # Only the leg that did not pass is looked up.
  run cat "$GH_LOG"
  refute_output --partial "acme/one"
}

# Also the status of a leg stopped by timeout-minutes.
@test "a cancelled leg counts as not passing" {
  outcome 0 acme/one cancelled 11
  outcome 1 acme/two success 12
  own_runs acme/one '[]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial "not passing against this commit: 1 of 2."
  assert_output --partial '| `acme/one` | :warning: [cancelled](https://github.com/acme/widget/actions/runs/99/job/11) |'
}

# A leg whose runner died before its last steps leaves no file behind.
@test "a leg that recorded nothing is no result, linked to the run" {
  outcome 0 acme/one success 11
  own_runs acme/two '[]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial "not passing against this commit: 1 of 2."
  assert_output --partial "| \`acme/two\` | :warning: [no result](https://github.com/acme/widget/actions/runs/99) | [\`7a8341d\`](https://github.com/acme/two/commit/$HEAD_SHA): no workflow run |"
}

@test "no outcomes directory at all: every leg is no result" {
  export OUTCOMES_DIR="$BATS_TEST_TMPDIR/absent"

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial "not passing against this commit: 2 of 2."
}

@test "outcomes are matched by package, and rows follow the package list" {
  outcome 7 acme/two success 12
  outcome 3 acme/one success 11

  report
  assert_success

  run grep '^| `acme/' "$BODY_FILE"
  assert_line --index 0 --partial '| `acme/one` | :white_check_mark: [success](https://github.com/acme/widget/actions/runs/99/job/11) |'
  assert_line --index 1 --partial '| `acme/two` | :white_check_mark: [success](https://github.com/acme/widget/actions/runs/99/job/12) |'
}

# The files are written after the downstream's own code has run.
@test "a status or job id no leg could have written is not trusted" {
  outcome 0 acme/one 'success!' 11
  outcome 1 acme/two success '12)[x](https://example.com'
  own_runs acme/one '[]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial '| `acme/one` | :warning: [no result](https://github.com/acme/widget/actions/runs/99/job/11) |'
  assert_output --partial '| `acme/two` | :white_check_mark: [success](https://github.com/acme/widget/actions/runs/99) |'
  refute_output --partial "example.com"
}

@test "a malformed outcome file is skipped rather than fatal" {
  printf 'not json' > "$OUTCOMES_DIR/0.json"
  outcome 1 acme/two success 12
  own_runs acme/one '[]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial '| `acme/one` | :warning: [no result](https://github.com/acme/widget/actions/runs/99) |'
}

# A private downstream the token has no Actions access to, for one.
@test "runs that cannot be read are noted, and the report still succeeds" {
  outcome 0 acme/one failure 11
  outcome 1 acme/two success 12

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial '| `acme/one` | :x: [failure](https://github.com/acme/widget/actions/runs/99/job/11) | its runs could not be read |'
}

@test "a run still going shows its status" {
  outcome 0 acme/one success 11
  outcome 1 acme/two failure 12
  own_runs acme/two '[{"name": "ci", "status": "in_progress", "conclusion": null, "html_url": "https://github.com/acme/two/actions/runs/1"}]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial '[ci](https://github.com/acme/two/actions/runs/1) in progress |'
}

@test "a pipe or bracket in a run name cannot break the table" {
  outcome 0 acme/one success 11
  outcome 1 acme/two failure 12
  own_runs acme/two '[{"name": "check | lint [nightly]", "status": "completed", "conclusion": "success", "html_url": "https://github.com/acme/two/actions/runs/1"}]'

  report
  assert_success

  run cat "$BODY_FILE"
  assert_output --partial '[check \| lint \[nightly\]](https://github.com/acme/two/actions/runs/1) success |'
}

@test "the report also goes to the step summary" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  outcome 0 acme/one success 11
  outcome 1 acme/two success 12

  report
  assert_success

  run cat "$GITHUB_STEP_SUMMARY"
  assert_output --partial "## Informational reverse-dependency checks"
}

@test "an empty package list is an error, not an empty report" {
  export PACKAGES='[]'

  report
  assert_failure
  assert_output --partial "lists no downstream"
}
