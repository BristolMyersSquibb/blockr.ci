#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../install-deps/check-sysreqs.sh"
  cd "$BATS_TEST_TMPDIR"

  export LOCKFILE="$BATS_TEST_TMPDIR/pkg.lock"
  export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
  export DPKG_STATUS="$BATS_TEST_TMPDIR/dpkg-status"
  : > "$GITHUB_ENV"

  # A dpkg-query that answers from DPKG_STATUS, in the format the script
  # asks for: status, package and what it provides, separated by tabs.
  mkdir -p bin
  cat > bin/dpkg-query <<'STUB'
#!/usr/bin/env bash
cat "$DPKG_STATUS"
STUB
  chmod +x bin/dpkg-query
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH
}

# A lockfile that carries only the field the script reads.
write_lockfile() {
  local names=""
  for p in "$@"; do
    names+="\"$p\", "
  done
  names="${names%, }"
  cat > "$LOCKFILE" <<JSON
{ "lockfile_version": 1, "packages": [], "sysreqs": { "packages": [ $names ] } }
JSON
}

@test "every system package installed: switches the system requirements of pak off" {
  write_lockfile libcurl4-openssl-dev pandoc
  printf 'ii \tlibcurl4-openssl-dev\tlibcurl-dev (= 8.18.0-1), libcurl-ssl-dev (= 8.18.0-1)\nii \tpandoc\t\n' > "$DPKG_STATUS"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "all 2 system packages"

  run cat "$GITHUB_ENV"
  assert_output "PKG_SYSREQS=false"
}

@test "a system package missing: lets pak install only the missing ones" {
  write_lockfile libcurl4-openssl-dev libprotobuf-dev pandoc
  printf 'ii \tlibcurl4-openssl-dev\t\nii \tpandoc\t\n' > "$DPKG_STATUS"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "::warning"
  assert_output --partial "libprotobuf-dev"
  refute_output --partial "pandoc"

  run cat "$GITHUB_ENV"
  assert_line "PKG_SYSREQS=true"
  assert_line "PKG_SYSREQS_UPDATE=false"
}

@test "a system package that another package provides counts as installed" {
  write_lockfile libcurl-dev
  printf 'ii \tlibcurl4-openssl-dev\tlibcurl-dev (= 8.18.0-1), libcurl-ssl-dev (= 8.18.0-1)\n' > "$DPKG_STATUS"

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_ENV"
  assert_output "PKG_SYSREQS=false"
}

@test "a system package with only its config files left counts as missing" {
  write_lockfile libxml2-dev
  printf 'rc \tlibxml2-dev\t\n' > "$DPKG_STATUS"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "libxml2-dev"

  run cat "$GITHUB_ENV"
  assert_line "PKG_SYSREQS=true"
}

@test "no system packages in the lockfile: switches the system requirements of pak off" {
  write_lockfile
  printf 'ii \tpandoc\t\n' > "$DPKG_STATUS"

  run bash "$SCRIPT"
  assert_success
  assert_output --partial "need no system packages"

  run cat "$GITHUB_ENV"
  assert_output "PKG_SYSREQS=false"
}

@test "a lockfile without a sysreqs field: switches the system requirements of pak off" {
  printf '{ "lockfile_version": 1, "packages": [] }\n' > "$LOCKFILE"
  printf 'ii \tpandoc\t\n' > "$DPKG_STATUS"

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_ENV"
  assert_output "PKG_SYSREQS=false"
}
