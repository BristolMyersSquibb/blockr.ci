#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../../audit/audit.sh"
  cd "$BATS_TEST_TMPDIR"

  export ORG=acme
  export BRANCHES="js-state main"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export STUB="$BATS_TEST_TMPDIR/stub"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  mkdir -p "$RUNNER_TEMP" "$STUB/graphql" "$STUB/contents" "$STUB/audit" bin
  : > "$GITHUB_STEP_SUMMARY"
  : > "$GH_LOG"

  # A gh that records its arguments.  It answers the GraphQL query for a
  # branch with the pages in $STUB/graphql/<branch>.<page>.json, as
  # gh api --paginate prints them, and a download with the file in
  # $STUB/contents/<repo>/<branch>/<path>.  A file that is missing fails,
  # as gh fails on a 404.
  cat > bin/gh <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
for arg; do
  case "$arg" in
    expression=refs/heads/*)
      branch=${arg#expression=refs/heads/}
      branch=${branch%%:*} ;;
    repos/*/contents/*)
      rest=${arg#repos/}
      repo=${rest%%/contents/*}
      rest=${rest#*/contents/}
      file="$STUB/contents/$repo/${rest##*\?ref=}/${rest%%\?ref=*}" ;;
  esac
done
if [ -n "${branch:-}" ]; then
  pages=("$STUB/graphql/$branch".*.json)
  if [ -e "${pages[0]}" ]; then
    cat "${pages[@]}"
  else
    echo '{ "data": { "organization": { "repositories": { "nodes": [] } } } }'
  fi
elif [ -f "${file:-}" ]; then
  cat "$file"
else
  echo '{ "message": "Not Found", "status": "404" }'
  exit 1
fi
STUB

  # An npm that records its arguments and answers an audit with the report
  # in $STUB/audit/<name>.json, where <name> is the name in the lockfile.
  # It exits 1 on any report but the clean one, as npm does on a finding
  # or an error.
  cat > bin/npm <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NPM_LOG"
while [ "$#" -gt 0 ]; do
  [ "$1" = --prefix ] && prefix=$2
  shift
done
report=$(jq -r .name "$prefix/package-lock.json")
cat "$STUB/audit/$report.json"
[ "$report" = clean ]
STUB
  chmod +x bin/gh bin/npm
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PATH

  # The reports, in the shape that npm audit --json prints.  In the one
  # with findings, chalk and debug carry advisories of their own, which
  # are critical and high.  The package wrap is flagged only through the
  # copy of debug that it holds, and ms has a moderate advisory alone.
  cat > "$STUB/audit/clean.json" <<'JSON'
{
  "auditReportVersion": 2,
  "vulnerabilities": {},
  "metadata": {
    "vulnerabilities": { "info": 0, "low": 0, "moderate": 0, "high": 0, "critical": 0, "total": 0 }
  }
}
JSON

  cat > "$STUB/audit/findings.json" <<'JSON'
{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "chalk": {
      "name": "chalk",
      "severity": "critical",
      "isDirect": true,
      "via": [
        {
          "source": 1107375,
          "name": "chalk",
          "dependency": "chalk",
          "title": "Malware in chalk",
          "url": "https://github.com/advisories/GHSA-2v46-p5h4-248w",
          "severity": "critical",
          "range": "=5.6.1"
        }
      ],
      "effects": [],
      "range": "",
      "nodes": ["node_modules/chalk"],
      "fixAvailable": false
    },
    "debug": {
      "name": "debug",
      "severity": "high",
      "isDirect": true,
      "via": [
        {
          "source": 1107615,
          "name": "debug",
          "dependency": "debug",
          "title": "debug@4.4.2 contains malware after npm account takeover",
          "url": "https://github.com/advisories/GHSA-4x49-vf9v-38px",
          "severity": "high",
          "range": "=4.4.2"
        }
      ],
      "effects": ["wrap"],
      "range": "",
      "nodes": ["node_modules/debug", "node_modules/wrap/node_modules/debug"],
      "fixAvailable": false
    },
    "wrap": {
      "name": "wrap",
      "severity": "high",
      "isDirect": true,
      "via": ["debug"],
      "effects": [],
      "range": "1.0.0",
      "nodes": ["node_modules/wrap"],
      "fixAvailable": false
    },
    "ms": {
      "name": "ms",
      "severity": "moderate",
      "isDirect": false,
      "via": [
        {
          "source": 1,
          "name": "ms",
          "dependency": "ms",
          "title": "A moderate advisory",
          "url": "https://github.com/advisories/GHSA-0000-0000-0000",
          "severity": "moderate",
          "range": "<3.0.0"
        }
      ],
      "effects": [],
      "range": "<3.0.0",
      "nodes": ["node_modules/ms"],
      "fixAvailable": true
    }
  },
  "metadata": {
    "vulnerabilities": { "info": 0, "low": 0, "moderate": 1, "high": 2, "critical": 1, "total": 4 }
  }
}
JSON

  cat > "$STUB/audit/pipe.json" <<'JSON'
{
  "auditReportVersion": 2,
  "vulnerabilities": {
    "chalk": {
      "name": "chalk",
      "severity": "high",
      "via": [
        {
          "title": "Reads a | from the input",
          "url": "https://github.com/advisories/GHSA-1111-1111-1111",
          "severity": "high"
        }
      ],
      "nodes": ["node_modules/chalk"]
    }
  },
  "metadata": {
    "vulnerabilities": { "info": 0, "low": 0, "moderate": 0, "high": 1, "critical": 0, "total": 1 }
  }
}
JSON

  # What npm prints when it cannot reach the registry.
  cat > "$STUB/audit/error.json" <<'JSON'
{
  "message": "request to https://registry.npmjs.org/-/npm/v1/security/advisories/bulk failed, reason: getaddrinfo EAI_AGAIN registry.npmjs.org",
  "error": { "summary": "", "detail": "" }
}
JSON
}

# Adds a repo to the GraphQL reply for a branch, on page PAGE (1 by
# default): its name, whether it is archived, and the text of each of its
# workflows on the branch.  A repo without workflows there gets a null
# object, as one without the branch does.
add_repo() {
  local branch=$1 name=$2 archived=$3
  shift 3
  local page="$STUB/graphql/$branch.${PAGE:-1}.json"
  if [ ! -f "$page" ]; then
    echo '{ "data": { "organization": { "repositories": { "nodes": [] } } } }' > "$page"
  fi
  jq --arg name "$name" --argjson archived "$archived" '
    .data.organization.repositories.nodes += [{
      nameWithOwner: $name,
      isArchived: $archived,
      object: (if $ARGS.positional == [] then null
               else { entries: [$ARGS.positional[] | { object: { text: . } }] } end)
    }]' "$page" --args "$@" > "$page.new"
  mv "$page.new" "$page"
}

# A workflow that calls ci.yaml with typescript-dir set to its argument.
caller() {
  printf 'jobs:\n  ci:\n    uses: acme/ci/.github/workflows/ci.yaml@main\n    with:\n      typescript-dir: %s\n' "$1"
}

# Puts a lockfile on a branch of a repo, at a path.  Its name selects the
# report that npm answers its audit with.
add_lockfile() {
  local repo=$1 branch=$2 path=$3 report=$4
  local file="$STUB/contents/$repo/$branch/$path"
  mkdir -p "$(dirname "$file")"
  jq -n --arg report "$report" '{
    name: $report,
    lockfileVersion: 3,
    packages: {
      "": { name: $report },
      "node_modules/chalk": { version: "5.6.1" },
      "node_modules/debug": { version: "4.4.2" },
      "node_modules/ms": { version: "2.1.3" },
      "node_modules/wrap": { version: "1.0.0" },
      "node_modules/wrap/node_modules/debug": { version: "4.4.1" }
    }
  }' > "$file"
}

@test "audits the lockfile of each repo whose workflows set typescript-dir" {
  add_repo js-state acme/alpha false "$(caller "'.'")"
  add_repo js-state acme/beta false 'jobs:
  ci:
    uses: acme/ci/.github/workflows/ci.yaml@main'
  add_repo js-state acme/gamma false
  add_repo js-state acme/delta true "$(caller "'.'")"
  add_lockfile acme/alpha js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run grep contents "$GH_LOG"
  assert_output "api -H Accept: application/vnd.github.raw repos/acme/alpha/contents/package-lock.json?ref=js-state"

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | package-lock.json | no advisory |"
  assert_line "No version in these lockfiles has an advisory of high or critical severity."
}

@test "runs the audit of the typescript job's level on the lockfile alone" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run cat "$NPM_LOG"
  assert_output --regexp "^audit --package-lock-only --audit-level=high --json --prefix $RUNNER_TEMP/audit\.[A-Za-z0-9]+$"
}

@test "reads the lockfile in typescript-dir" {
  add_repo js-state acme/alpha false "$(caller js)"
  add_repo js-state acme/beta false "$(caller '"./inst/js/"')"
  add_repo js-state acme/gamma false "$(caller "'.' # the root")"
  add_lockfile acme/alpha js-state js/package-lock.json clean
  add_lockfile acme/beta js-state inst/js/package-lock.json clean
  add_lockfile acme/gamma js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | js/package-lock.json | no advisory |"
  assert_line "| acme/beta | js-state | inst/js/package-lock.json | no advisory |"
  assert_line "| acme/gamma | js-state | package-lock.json | no advisory |"
}

@test "skips a typescript-dir that is empty, commented out or an input" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_repo js-state acme/beta false "$(caller "''")" \
    'jobs:
  ci:
    with:
      # typescript-dir: js
      image: true' \
    'on:
  workflow_call:
    inputs:
      typescript-dir:
        type: string
jobs:
  typescript:
    if: inputs.typescript-dir != '"''"'
    defaults:
      run:
        working-directory: ${{ inputs.typescript-dir }}'
  add_lockfile acme/alpha js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run grep contents "$GH_LOG"
  assert_output --partial "acme/alpha"
  refute_output --partial "acme/beta"
}

@test "audits each branch, and a lockfile once per branch" {
  add_repo js-state acme/alpha false "$(caller .)" "$(caller .)"
  add_repo main acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json clean
  add_lockfile acme/alpha main package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run grep -c contents "$GH_LOG"
  assert_output 2

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | package-lock.json | no advisory |"
  assert_line "| acme/alpha | main | package-lock.json | no advisory |"
}

@test "asks for public repos only" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run cat "$GH_LOG"
  assert_output --partial "privacy: PUBLIC"
}

@test "reads the repos of every page" {
  PAGE=1 add_repo js-state acme/alpha false "$(caller .)"
  PAGE=2 add_repo js-state acme/omega false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json clean
  add_lockfile acme/omega js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_success

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | package-lock.json | no advisory |"
  assert_line "| acme/omega | js-state | package-lock.json | no advisory |"
}

@test "no caller found: fails, so that a broken query does not pass" {
  add_repo js-state acme/beta false 'jobs: {}'

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "::error::Found no public repo of acme with a workflow on js-state or main that sets typescript-dir."

  run grep -c contents "$GH_LOG"
  assert_output 0
}

@test "an advisory of high or critical severity fails the run, and the summary lists it" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json findings

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "::error::The lockfile package-lock.json of acme/alpha@js-state holds versions with 2 advisories of high or critical severity."

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | package-lock.json | 1 critical, 2 high, 1 moderate |"
  assert_line "| acme/alpha | js-state | chalk | 5.6.1 | critical | [GHSA-2v46-p5h4-248w](https://github.com/advisories/GHSA-2v46-p5h4-248w) Malware in chalk |"
  assert_line "| acme/alpha | js-state | debug | 4.4.1, 4.4.2 | high | [GHSA-4x49-vf9v-38px](https://github.com/advisories/GHSA-4x49-vf9v-38px) debug@4.4.2 contains malware after npm account takeover |"
  refute_line --partial "No version"
}

@test "lists no package flagged only through a dependency, and no moderate advisory" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json findings

  run bash "$SCRIPT"
  assert_failure

  run cat "$GITHUB_STEP_SUMMARY"
  refute_line --partial "| wrap |"
  refute_line --partial "| ms |"
}

@test "escapes a pipe in the title of an advisory, which would split its row" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json pipe

  run bash "$SCRIPT"
  assert_failure

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | chalk | 5.6.1 | high | [GHSA-1111-1111-1111](https://github.com/advisories/GHSA-1111-1111-1111) Reads a \| from the input |"
}

@test "a lockfile that cannot be downloaded fails the run, and the others are still audited" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_repo js-state acme/beta false "$(caller .)"
  add_lockfile acme/beta js-state package-lock.json clean

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "::error::Could not download package-lock.json of acme/alpha@js-state."

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | package-lock.json | Download failed |"
  assert_line "| acme/beta | js-state | package-lock.json | no advisory |"
  refute_line --partial "No version"
}

@test "an audit that fails fails the run, with what npm says" {
  add_repo js-state acme/alpha false "$(caller .)"
  add_lockfile acme/alpha js-state package-lock.json error

  run bash "$SCRIPT"
  assert_failure
  assert_output --partial "::error::The audit of package-lock.json of acme/alpha@js-state failed: request to https://registry.npmjs.org/-/npm/v1/security/advisories/bulk failed, reason: getaddrinfo EAI_AGAIN registry.npmjs.org"

  run cat "$GITHUB_STEP_SUMMARY"
  assert_line "| acme/alpha | js-state | package-lock.json | Audit failed |"
  refute_line --partial "No version"
}
