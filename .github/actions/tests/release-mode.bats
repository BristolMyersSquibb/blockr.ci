#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../release-mode/release-mode.sh"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  > "$GITHUB_OUTPUT"

  export GITHUB_REPOSITORY="BristolMyersSquibb/testpkg"
  export GH_TOKEN="dummy"
  export PR_NUMBER=""
  export GITHUB_REF=""
  unset LABEL || true

  # Stub `gh` on PATH. Each test writes the label list it should return into
  # GH_LABELS, or sets GH_FAIL=1 to make the lookup fail the way a missing
  # `pull-requests: read` scope would.
  export BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALLS"
if [[ -n "${GH_FAIL:-}" ]]; then
  echo "gh: HTTP 403" >&2
  exit 1
fi
printf '%s' "${GH_LABELS:-}"
STUB
  chmod +x "$BIN/gh"
  export PATH="$BIN:$PATH"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh_calls"
  > "$GH_CALLS"
}

get_output() {
  grep "^${1}=" "$GITHUB_OUTPUT" | sed "s/^${1}=//"
}

@test "pull request carrying the release label is release mode" {
  export PR_NUMBER=54
  export GH_LABELS=$'release\ndocumentation'
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "true"
}

@test "pull request without the label is not release mode" {
  export PR_NUMBER=54
  export GH_LABELS=$'documentation\nbug'
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
}

@test "pull request with no labels at all is not release mode" {
  export PR_NUMBER=54
  export GH_LABELS=""
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
}

@test "merge queue ref recovers the pull request number" {
  export GITHUB_REF="refs/heads/gh-readonly-queue/main/pr-356-42bbd338944d56c645c7b51743a201fb967059b6"
  export GH_LABELS="release"
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "true"
  # The lookup must have asked about PR 356, not some other number.
  assert grep -q "repos/BristolMyersSquibb/testpkg/pulls/356" "$GH_CALLS"
}

@test "merge queue ref for a non-release pull request is not release mode" {
  export GITHUB_REF="refs/heads/gh-readonly-queue/main/pr-356-42bbd338944d56c645c7b51743a201fb967059b6"
  export GH_LABELS=$'bug\nenhancement'
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
}

@test "push ref with no pull request is not release mode and makes no API call" {
  export GITHUB_REF="refs/heads/main"
  export GH_LABELS="release"
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
  assert_equal "$(wc -l < "$GH_CALLS")" "0"
}

@test "a failed lookup falls back to not-release and warns" {
  export PR_NUMBER=54
  export GH_FAIL=1
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
  assert_output --partial "::warning::"
}

@test "a missing token skips the lookup rather than erroring" {
  export PR_NUMBER=54
  export GH_TOKEN=""
  export GH_LABELS="release"
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
}

@test "label match is exact, not a substring" {
  export PR_NUMBER=54
  export GH_LABELS=$'release-blocked\npre-release'
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "false"
}

@test "the label is configurable" {
  export PR_NUMBER=54
  export LABEL="cran-submission"
  export GH_LABELS=$'cran-submission\nbug'
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "true"
}

@test "a label containing spaces still matches exactly" {
  export PR_NUMBER=54
  export LABEL="ready to release"
  export GH_LABELS=$'ready to release\nbug'
  run bash "$SCRIPT"
  assert_success
  assert_equal "$(get_output is-release)" "true"
}
