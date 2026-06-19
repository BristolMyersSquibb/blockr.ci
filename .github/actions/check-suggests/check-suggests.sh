#!/usr/bin/env bash
# Resolve the deploy directory's DESCRIPTION and manifest.json, then hand off
# to check-suggests.R (which owns the package-metadata comparison). Mirrors the
# bash/R split in parse-deps: bash does path wrangling and early existence
# checks, R does anything that touches package descriptions.
#
# Env vars: CONTENT_DIR (default "."), GITHUB_OUTPUT (unused), SCRIPT_DIR

set -euo pipefail

: "${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

CONTENT_DIR="${CONTENT_DIR:-.}"
DESC_PATH="$CONTENT_DIR/DESCRIPTION"
MANIFEST_PATH="$CONTENT_DIR/manifest.json"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "::error::check-suggests: no manifest.json at '$MANIFEST_PATH'. Run rsconnect::writeManifest() before this step." >&2
  exit 1
fi

if [[ ! -f "$DESC_PATH" ]]; then
  echo "::error::check-suggests: no DESCRIPTION at '$DESC_PATH'. The deploy directory must declare its dependencies as an R package." >&2
  exit 1
fi

export DESC_PATH MANIFEST_PATH

Rscript --no-save --no-restore "$SCRIPT_DIR/check-suggests.R"
