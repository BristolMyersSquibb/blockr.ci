#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../release-gate/release-gate.R"
  cd "$BATS_TEST_TMPDIR"

  # Blanked because the bats job itself runs inside Actions, where this
  # is set: without it every test would append its table to the real
  # step summary.
  export GITHUB_STEP_SUMMARY=""
  export SUMMARY_FILE=""
}

gate() {
  run Rscript --no-save --no-restore "$SCRIPT"
}

# The smallest package that clears every gate: a three-component
# version, no dependencies, and none of the optional files the remaining
# checks look at.
write_clean_description() {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1.0
Title: A Test Package
EOF
}

@test "a clean package passes every gate" {
  write_clean_description

  gate
  assert_success
  assert_output --partial "All hard gates pass"
}

@test "a missing DESCRIPTION fails rather than passing on nothing" {
  gate
  assert_failure
  assert_output --partial "no DESCRIPTION"
}

@test "a four-component version fails" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1.1.9001
EOF

  gate
  assert_failure
  assert_output --partial "0.1.1.9001"
  assert_output --partial "exactly three components"
}

@test "a two-component version fails" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1
EOF

  gate
  assert_failure
  assert_output --partial "exactly three components"
}

@test "a dependency pinned to a development version fails, and is named" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1.0
Imports:
    shiny (>= 1.7.0)
Suggests:
    blockr.theme (>= 0.0.0.9002)
EOF

  gate
  assert_failure
  assert_output --partial "blockr.theme"
  assert_output --partial "0.0.0.9002"
  refute_output --partial "shiny (1.7.0)"
}

@test "an ordinary version pin passes" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1.0
Depends:
    R (>= 4.1.0)
Imports:
    shiny (>= 1.14.0),
    bslib
EOF

  gate
  assert_success
}

@test "a Remotes field fails, and its entries are named" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1.0
Remotes:
    nbenn/typedjson,
    BristolMyersSquibb/blockr.core
EOF

  gate
  assert_failure
  assert_output --partial "nbenn/typedjson"
  assert_output --partial "BristolMyersSquibb/blockr.core"
}

@test "a build-ignored NEWS.md fails" {
  write_clean_description
  echo "# testpkg 0.1.0" > NEWS.md
  printf '^NEWS\\.md$\n' > .Rbuildignore

  gate
  assert_failure
  assert_output --partial "build-ignored"
}

@test "a NEWS.md that is not build-ignored passes" {
  write_clean_description
  echo "# testpkg 0.1.0" > NEWS.md
  printf '^LICENSE\\.md$\n' > .Rbuildignore

  gate
  assert_success
}

@test "a stale inst/NEWS.Rd alongside NEWS.md fails" {
  write_clean_description
  echo "# testpkg 0.1.0" > NEWS.md
  mkdir -p inst
  echo '\name{NEWS}' > inst/NEWS.Rd

  gate
  assert_failure
  assert_output --partial "inst/NEWS.Rd"
}

@test "a placeholder title in an Rmd vignette fails" {
  write_clean_description
  mkdir -p vignettes
  cat > vignettes/intro.Rmd <<'EOF'
---
title: "Vignette Title"
output: rmarkdown::html_vignette
vignette: >
  %\VignetteIndexEntry{Vignette Title}
---
EOF

  gate
  assert_failure
  assert_output --partial "intro.Rmd"
  assert_output --partial "placeholder"
}

# The reason this check reads the headers itself instead of calling
# tools::pkgVignettes(): that function resolves vignettes through the
# registered engines, so without the quarto package installed a .qmd is
# invisible to it and the check passes by finding nothing.
@test "a placeholder title in a qmd vignette fails too" {
  write_clean_description
  mkdir -p vignettes
  cat > vignettes/intro.qmd <<'EOF'
---
title: "Vignette Title"
vignette: >
  %\VignetteIndexEntry{Vignette Title}
---
EOF

  gate
  assert_failure
  assert_output --partial "intro.qmd"
}

@test "a titled vignette passes" {
  write_clean_description
  mkdir -p vignettes
  cat > vignettes/intro.qmd <<'EOF'
---
title: "Getting started"
vignette: >
  %\VignetteIndexEntry{Getting started}
---
EOF

  gate
  assert_success
}

# The point of collecting rather than exiting on the first failure: a
# maintainer fixing one thing per push is a maintainer pushing five
# times.
@test "every failing gate is reported, not just the first" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1.1.9001
Suggests:
    blockr.theme (>= 0.0.0.9002)
Remotes:
    BristolMyersSquibb/blockr.theme
EOF

  gate
  assert_failure
  assert_output --partial "3 of 5 hard gates failed"
  assert_output --partial "exactly three components"
  assert_output --partial "blockr.theme"
  assert_output --partial "Remotes"
}

@test "the markdown fragment is written when SUMMARY_FILE is set" {
  write_clean_description
  export SUMMARY_FILE="$BATS_TEST_TMPDIR/parts/10-gate.md"

  gate
  assert_success

  run cat "$SUMMARY_FILE"
  assert_success
  assert_output --partial "### Hard gates"
  assert_output --partial "| Check | Result |"
  assert_output --partial ":white_check_mark:"
}

@test "a failing gate still writes its fragment" {
  cat > DESCRIPTION <<'EOF'
Package: testpkg
Version: 0.1
EOF
  export SUMMARY_FILE="$BATS_TEST_TMPDIR/parts/10-gate.md"

  gate
  assert_failure

  run cat "$SUMMARY_FILE"
  assert_success
  assert_output --partial ":x:"
}
