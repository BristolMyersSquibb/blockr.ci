#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../sticky-comment/sticky-comment.sh"
  cd "$BATS_TEST_TMPDIR"

  export GITHUB_REPOSITORY="acme/widget"
  export PR_NUMBER=7
  export MARKER="<!-- release-gate -->"
  export BODY_FILE="$BATS_TEST_TMPDIR/body.md"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_PAYLOAD="$BATS_TEST_TMPDIR/payload.json"

  # A gh that records what it was asked to do. The listing call is the
  # one carrying --paginate; anything else is the write, whose stdin is
  # the JSON payload.
  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
for arg in "$@"; do
  if [ "$arg" = "--paginate" ]; then
    if [ -n "${GH_STUB_EXISTING:-}" ]; then
      printf '%s\n' "$GH_STUB_EXISTING"
    fi
    exit 0
  fi
done
cat > "${GH_PAYLOAD:-/dev/null}"
if [ -n "${GH_STUB_FAIL:-}" ]; then
  exit 1
fi
exit 0
STUB
  chmod +x bin/gh
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH

  printf 'Hello.\n' > "$BODY_FILE"
}

@test "no existing comment: posts a new one" {
  run bash "$SCRIPT"
  assert_success
  assert_output --partial "POST"

  run cat "$GH_LOG"
  assert_output --partial "issues/7/comments"
}

@test "existing comment: patches it in place rather than adding a second" {
  export GH_STUB_EXISTING=12345

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "PATCH"

  run cat "$GH_LOG"
  assert_output --partial "issues/comments/12345"
  refute_output --partial "--method POST"
}

# The `--paginate` flag applies the filter per page, so two pages
# holding a match yield two ids; taking the first keeps one comment rather than erroring
# on a two-line endpoint.
@test "a match on more than one page resolves to a single id" {
  export GH_STUB_EXISTING=$'12345\n67890'

  run bash "$SCRIPT"
  assert_success

  run cat "$GH_LOG"
  assert_output --partial "issues/comments/12345"
  refute_output --partial "67890"
}

@test "the marker is prepended so the next run finds the comment" {
  run bash "$SCRIPT"
  assert_success

  run head -n 1 <(jq -r '.body' "$GH_PAYLOAD")
  assert_output "<!-- release-gate -->"
}

@test "a body that already leads with the marker does not get a second one" {
  printf '<!-- release-gate -->\nHello.\n' > "$BODY_FILE"

  run bash "$SCRIPT"
  assert_success

  run jq -r '.body' "$GH_PAYLOAD"
  assert_line --index 0 "<!-- release-gate -->"
  refute_line --index 1 "<!-- release-gate -->"
}

# The body carries fenced code, backticks and quotes from R CMD check
# output, so it has to survive as JSON rather than as a shell word.
@test "quotes, backticks and newlines survive into the payload" {
  cat > "$BODY_FILE" <<'BODY'
## Release gate

Maintainer: 'A B <a@b.com>'

```
checking CRAN incoming feasibility ... NOTE
"quoted" and `backticked`
```
BODY

  run bash "$SCRIPT"
  assert_success

  run jq -r '.body' "$GH_PAYLOAD"
  assert_output --partial "Maintainer: 'A B <a@b.com>'"
  assert_output --partial '"quoted" and `backticked`'
  assert_output --partial 'checking CRAN incoming feasibility ... NOTE'
}

# Commenting needs pull-requests: write, which a fork pull request never
# has. The step summaries still carry the content, so a missing grant
# warns rather than reddening the run.
@test "a write that is refused warns instead of failing" {
  export GH_STUB_FAIL=1

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "::warning::"
  assert_output --partial "pull-requests: write"
}

@test "no pull-request number: nothing to comment on, and no failure" {
  export PR_NUMBER=""

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "nothing to comment on"

  # No log file at all is the proof that gh was never reached.
  run test -e "$GH_LOG"
  assert_failure
}

@test "a missing body file is an error, not a silent skip" {
  export BODY_FILE="$BATS_TEST_TMPDIR/absent.md"

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "no body file"
}
