#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../check-suggests/check-suggests.sh"
  cd "$BATS_TEST_TMPDIR"
}

# DESCRIPTION from stdin, so each test states exactly the fields it exercises.
write_description() {
  cat > DESCRIPTION
}

# A manifest carrying just the package-name keys check-suggests reads. The
# real writeManifest() output nests far more under each key; only the names
# matter here.
write_manifest() {
  local entries=""
  for p in "$@"; do
    entries+="\"$p\": {\"Source\": \"CRAN\"}, "
  done
  entries="${entries%, }"
  cat > manifest.json <<EOF
{ "version": 1, "platform": "4.4.2", "packages": { $entries } }
EOF
}

@test "deploy-optional Suggests present in manifest: success" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests: jsonlite
EOF
  write_manifest shiny jsonlite

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "OK"
}

@test "deploy-optional Suggests missing from manifest: failure with hint" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests: jsonlite
EOF
  write_manifest shiny

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "jsonlite"
  assert_output --partial "requireNamespace"
  assert_output --partial "dependencies.R"
}

@test "Config/Needs/tests packages are carved out" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests:
    testthat (>= 3.0.0),
    withr
Config/Needs/tests:
    testthat,
    withr
EOF
  write_manifest shiny

  run bash "$SCRIPT"
  assert_success
}

@test "base packages in Suggests are carved out" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests: methods
EOF
  write_manifest shiny

  run bash "$SCRIPT"
  assert_success
}

@test "no Suggests field: nothing to check, success" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
EOF
  write_manifest shiny

  run bash "$SCRIPT"
  assert_success
}

@test "version constraints stripped before matching: present" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests: testthat (>= 3.0.0)
EOF
  write_manifest shiny testthat

  run bash "$SCRIPT"
  assert_success
}

@test "version constraints stripped before matching: missing names bare package" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests: jsonlite (>= 1.8.0)
EOF
  write_manifest shiny

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "- jsonlite"
  refute_output --partial "1.8.0"
}

@test "missing manifest.json: failure pointing at writeManifest" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests: jsonlite
EOF

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "manifest.json"
  assert_output --partial "writeManifest"
}

@test "missing DESCRIPTION: failure" {
  write_manifest shiny

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "DESCRIPTION"
}

@test "multiple missing deploy-optional Suggests are all listed" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests:
    jsonlite,
    glue
EOF
  write_manifest shiny

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "jsonlite"
  assert_output --partial "glue"
}

@test "one present, one missing: fails on the missing one" {
  write_description <<'EOF'
Package: connectapp
Imports: shiny
Suggests:
    jsonlite,
    glue
EOF
  write_manifest shiny jsonlite

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "- glue"
  refute_output --partial "- jsonlite"
}

@test "content-dir input: reads DESCRIPTION and manifest from a subdirectory" {
  mkdir -p app
  cat > app/DESCRIPTION <<'EOF'
Package: connectapp
Imports: shiny
Suggests: jsonlite
EOF
  cat > app/manifest.json <<'EOF'
{ "version": 1, "packages": { "shiny": {"Source": "CRAN"} } }
EOF
  export CONTENT_DIR="app"

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "jsonlite"
}
