#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../parse-deps/parse-deps.sh"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  > "$GITHUB_OUTPUT"
  cd "$BATS_TEST_TMPDIR"
  stub_gh
}

# Stands in for `gh api`, logging each call behind the token it carried. The
# downstream owner/repo has branches main, feature-branch and queued-branch;
# its pull request 42 was opened from one of them and 43 from a fork. The
# upstream owner/upstream answers pull request 19 with GH_PR_BODY. Anything
# else fails, as a 404 would.
stub_gh() {
  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo "${GH_TOKEN:-} $*" >> "$GH_CALLS"
case "$*" in
  *" repos/owner/upstream/pulls/19 "*) printf '%s\n' "$GH_PR_BODY" ;;
  *" repos/owner/repo/pulls/42 "*) echo true ;;
  *" repos/owner/repo/pulls/43 "*) echo false ;;
  *" repos/owner/repo/branches?per_page=100 "*)
    printf '%s\n' main feature-branch queued-branch ;;
  *) exit 1 ;;
esac
STUB
  chmod +x bin/gh
  export PATH="$PWD/bin:$PATH"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh_calls"
  > "$GH_CALLS"
}

get_output() {
  local key="$1"
  if grep -q "^${key}<<EOF" "$GITHUB_OUTPUT"; then
    sed -n "/^${key}<<EOF$/,/^EOF$/p" "$GITHUB_OUTPUT" | sed '1d;$d'
  else
    grep "^${key}=" "$GITHUB_OUTPUT" | sed "s/^${key}=//"
  fi
}

# A typical DESCRIPTION used by most cases. Imports + Remotes cover the
# forward-dep validation paths.
write_description() {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.0.0
Imports:
    blockr.core (>= 0.1.2),
    glue
Suggests:
    testthat
Remotes:
    BristolMyersSquibb/blockr.core
EOF
}

@test "no deps block: extra-packages = base-packages only, ref empty" {
  write_description
  export PR_BODY="Just a regular PR body with no deps."
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
  assert_equal "$(get_output ref)" ""
}

@test "deps-block entry (revdep ref) is NOT appended to extra-packages" {
  write_description
  export PR_BODY='Some text
```deps
owner/repo
```
More text'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
  assert_equal "$(get_output ref)" ""
}

@test "multiple revdep refs: none appended; extra-packages stays as base" {
  write_description
  export PR_BODY='```deps
owner/alpha
owner/beta
owner/gamma
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
}

@test "PR number syntax: ref = refs/pull/N/head" {
  write_description
  export PR_BODY='```deps
owner/repo#42
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "refs/pull/42/head"
}

@test "branch syntax: ref = refs/heads/<branch>" {
  write_description
  export PR_BODY='```deps
owner/repo@feature-branch
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "refs/heads/feature-branch"
}

@test "owner matched case-insensitively" {
  write_description
  export PR_BODY='```deps
OWNER/repo@main
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "refs/heads/main"
}

@test "entry without a ref: default branch, nothing looked up" {
  write_description
  export PR_BODY='```deps
owner/repo
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" ""
  assert_equal "$(cat "$GH_CALLS")" ""
}

@test "pull request from a fork: error naming the entry" {
  write_description
  export PR_BODY='```deps
owner/repo#43
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "'owner/repo#43' is a pull request from a fork"
  assert_equal "$(get_output ref)" ""
}

@test "pull request that cannot be looked up: error" {
  write_description
  export PR_BODY='```deps
owner/repo#99
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "could not look up pull request #99 of owner/repo"
}

@test "entry naming another owner: error, nothing looked up" {
  write_description
  export PR_BODY='```deps
someoneelse/repo#42
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "'someoneelse/repo#42' does not name owner/repo"
  assert_equal "$(cat "$GH_CALLS")" ""
}

@test "package alias for another repository: error" {
  write_description
  export PR_BODY='```deps
repo=someoneelse/anything#42
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "'repo=someoneelse/anything#42' does not name owner/repo"
}

@test "non-GitHub ref for PKG: error" {
  write_description
  export PR_BODY='```deps
git::https://github.com/someoneelse/repo@main
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "does not name owner/repo"
}

@test "SHA after @: error rather than passed through" {
  write_description
  export PR_BODY='```deps
owner/repo@e11d4fb2578e509a83bf0546591fe4b7548cabd2
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "'e11d4fb2578e509a83bf0546591fe4b7548cabd2' is not a branch of owner/repo"
  assert_equal "$(get_output ref)" ""
}

@test "refs/ path after @: error" {
  write_description
  export PR_BODY='```deps
owner/repo@refs/pull/43/head
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "'refs/pull/43/head' is not a branch of owner/repo"
}

@test "branches that cannot be listed: error" {
  write_description
  export PR_BODY='```deps
owner/private@main
```'
  export PKG="owner/private"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure

  assert_output --partial "could not list the branches of owner/private"
}

@test "PKG lookups use PKG_TOKEN; the body fetch keeps GH_TOKEN" {
  write_description
  export GH_PR_BODY='```deps
owner/repo@queued-branch
```'
  export PR_BODY=""
  export PR_NUMBER="19"
  export GH_TOKEN="upstream-token"
  export PKG_TOKEN="pkg-token"
  export GITHUB_REPOSITORY="owner/upstream"
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert [ -n "$(grep '^upstream-token api repos/owner/upstream/pulls/19 ' "$GH_CALLS")" ]
  assert [ -n "$(grep '^pkg-token api --paginate repos/owner/repo/branches' "$GH_CALLS")" ]
}

@test "PKG not matching any dep: ref empty" {
  write_description
  export PR_BODY='```deps
owner/other@main
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" ""
}

@test "PKG not set: ref empty" {
  write_description
  export PR_BODY='```deps
owner/repo@main
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" ""
}

@test "Windows line endings stripped: ref resolved, extra unchanged" {
  write_description
  export PR_BODY=$'```deps\r\nowner/repo@main\r\n```\r\n'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "refs/heads/main"
  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
}

@test "blank lines in deps block are skipped (no error)" {
  write_description
  export PR_BODY='```deps
owner/alpha

owner/beta
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
}

@test "custom base-packages preserved as-is (deps not appended)" {
  write_description
  export PR_BODY='```deps
owner/repo
```'
  export PKG=""
  export BASE_PACKAGES="custom::pkg1
custom::pkg2"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output extra-packages)" "custom::pkg1
custom::pkg2"
}

@test "forward dep (Imports) in deps block: error" {
  write_description
  export PR_BODY='```deps
owner/glue@my-branch
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "glue"
  assert_output --partial "Remotes"
}

@test "Remotes-listed forward dep in deps block: error" {
  write_description
  export PR_BODY='```deps
BristolMyersSquibb/blockr.core@dev
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "blockr.core"
}

@test "multiple forward-dep errors collected (don't stop at first)" {
  write_description
  export PR_BODY='```deps
owner/glue@x
fork/blockr.core@y
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "glue"
  assert_output --partial "blockr.core"
}

@test "DESCRIPTION at pkg/ (revdep job layout) is auto-detected" {
  mkdir -p pkg
  cat > pkg/DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.0.0
Imports:
    glue
EOF
  export PR_BODY='```deps
owner/glue@x
```'
  export PKG=""
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "glue"
}

@test "merge_group queue ref: PR number recovered, fresh body fetched" {
  write_description
  export GH_PR_BODY='```deps
owner/repo@queued-branch
```'
  export PR_BODY=""
  export PR_NUMBER=""
  export GH_TOKEN="x"
  export GITHUB_REPOSITORY="owner/upstream"
  export GITHUB_REF="refs/heads/gh-readonly-queue/main/pr-19-deadbeef"
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "refs/heads/queued-branch"
  assert [ -n "$(grep 'owner/upstream/pulls/19' "$GH_CALLS")" ]
}

@test "no DESCRIPTION present: warns, skips validation, still excludes from extra" {
  # No write_description / mkdir pkg — empty cwd
  export PR_BODY='```deps
owner/repo#42
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_output --partial "no DESCRIPTION"
  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
  assert_equal "$(get_output ref)" "refs/pull/42/head"
}
