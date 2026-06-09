#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../parse-deps/parse-deps.sh"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  > "$GITHUB_OUTPUT"
  cd "$BATS_TEST_TMPDIR"
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

@test "branch syntax: ref = branch name" {
  write_description
  export PR_BODY='```deps
owner/repo@feature-branch
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "feature-branch"
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

  assert_equal "$(get_output ref)" "main"
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

  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$GH_CALLS"
cat <<'BODY'
```deps
owner/repo@queued-branch
```
BODY
STUB
  chmod +x bin/gh
  export PATH="$PWD/bin:$PATH"
  export GH_CALLS="$BATS_TEST_TMPDIR/gh_calls"
  > "$GH_CALLS"

  export PR_BODY=""
  export PR_NUMBER=""
  export GH_TOKEN="x"
  export GITHUB_REPOSITORY="owner/repo"
  export GITHUB_REF="refs/heads/gh-readonly-queue/main/pr-19-deadbeef"
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_equal "$(get_output ref)" "queued-branch"
  assert [ -n "$(grep 'pulls/19' "$GH_CALLS")" ]
}

@test "no DESCRIPTION present: warns, skips validation, still excludes from extra" {
  # No write_description / mkdir pkg — empty cwd
  export PR_BODY='```deps
owner/repo#5
```'
  export PKG="owner/repo"
  export BASE_PACKAGES="any::rcmdcheck"

  run bash "$SCRIPT"
  assert_success

  assert_output --partial "no DESCRIPTION"
  assert_equal "$(get_output extra-packages)" "any::rcmdcheck"
  assert_equal "$(get_output ref)" "refs/pull/5/head"
}
