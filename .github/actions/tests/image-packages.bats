#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../../image/packages.sh"
  cd "$BATS_TEST_TMPDIR"

  export ORG=acme
  export BRANCH=js-state
  export CI_YAML="$BATS_TEST_TMPDIR/ci.yaml"
  export FIXED_PACKAGES="any::pkgdepends any::sessioninfo"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
  export GH_STUB_JSON="$BATS_TEST_TMPDIR/graphql.json"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GITHUB_OUTPUT"

  # A gh that records its arguments and answers with GH_STUB_JSON, which
  # may hold one JSON document per page, as gh api --paginate prints them.
  mkdir -p bin
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
cat "$GH_STUB_JSON"
STUB
  chmod +x bin/gh
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH

  cat > "$CI_YAML" <<'YAML'
jobs:
  lint:
    steps:
      - uses: actions/checkout@v5

      - uses: $/.github/actions/parse-deps
        with:
          base-packages: |
            any::lintr
            local::.

      - uses: r-lib/actions/setup-r-dependencies@v2
        with:
          needs: lint

      - name: Install in the image
        uses: $/.github/actions/install-deps
        with:
          # A comment inside the step.
          needs: website

  smoke:
    needs: build
    steps:
      - uses: $/.github/actions/install-deps
        with:
          needs: check
          extra-packages: any::rcmdcheck
  report:
    needs: deploy
YAML
}

# One page of the GraphQL reply, with a node per argument: name, whether
# the branch exists, whether it holds a DESCRIPTION, whether archived.
write_page() {
  local nodes="" name ref file archived
  while [ "$#" -gt 0 ]; do
    name=$1 ref=$2 file=$3 archived=$4
    shift 4
    if [ "$ref" = yes ]; then
      if [ "$file" = yes ]; then
        ref='{ "target": { "file": { "name": "DESCRIPTION" } } }'
      else
        ref='{ "target": { "file": null } }'
      fi
    else
      ref=null
    fi
    nodes+="{ \"nameWithOwner\": \"$name\", \"isArchived\": $archived, \"ref\": $ref }, "
  done
  nodes="${nodes%, }"
  printf '{ "data": { "organization": { "repositories": { "nodes": [ %s ] } } } }\n' "$nodes" >> "$GH_STUB_JSON"
}

@test "lists the repos whose branch holds a DESCRIPTION" {
  write_page acme/alpha yes yes false \
    acme/beta no no false \
    acme/gamma yes no false \
    acme/delta yes yes true

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_OUTPUT"
  assert_line "repos=acme/alpha@js-state"
}

@test "asks for public repos only" {
  write_page acme/alpha yes yes false

  run bash "$SCRIPT"
  assert_success

  run cat "$GH_LOG"
  assert_output --partial "privacy: PUBLIC"
}

@test "reads the repos of every page" {
  write_page acme/alpha yes yes false
  write_page acme/omega yes yes false

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_OUTPUT"
  assert_line "repos=acme/alpha@js-state acme/omega@js-state"
}

@test "no repo found: fails, so that the image of the day before stays" {
  write_page acme/beta no no false

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "::error::"

  run cat "$GITHUB_OUTPUT"
  assert_output ""
}

@test "installs the repos, the any:: refs of ci.yaml and the fixed packages" {
  write_page acme/alpha yes yes false

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_OUTPUT"
  assert_line "packages=acme/alpha@js-state any::lintr any::rcmdcheck any::pkgdepends any::sessioninfo"
}

@test "takes needs from the install steps, not from the jobs" {
  write_page acme/alpha yes yes false

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_OUTPUT"
  assert_line "needs=check lint website"
  refute_output --partial "build"
  refute_output --partial "deploy"
}
