#!/usr/bin/env Rscript
# Fail the deploy if a deploy-optional `Suggests` package is absent from the
# generated manifest. writeManifest() only records a Suggests package when the
# app's own code references it, so a Suggests dep that is installed on the
# runner but never named in code is silently dropped from the manifest and
# never reaches Connect. This guard turns that silent gap into a hard failure.
#
# Deploy-optional = Suggests minus the dev/check tooling the consumer parks in
# Config/Needs/tests, minus base packages (never recorded in a manifest).
#
# Env vars (set by check-suggests.sh):
#   DESC_PATH     : path to the deploy directory's DESCRIPTION
#   MANIFEST_PATH : path to the generated manifest.json

env <- function(x) Sys.getenv(x, unset = "")

desc_path <- env("DESC_PATH")
manifest_path <- env("MANIFEST_PATH")

read_field <- function(d, field) {
  if (!field %in% colnames(d)) {
    return(character())
  }

  x <- trimws(strsplit(d[1, field], ",")[[1]])
  x <- sub("\\s*\\(.*$", "", x)
  unique(x[nzchar(x) & x != "R"])
}

d <- read.dcf(desc_path)
suggests <- read_field(d, "Suggests")
test_pkgs <- read_field(d, "Config/Needs/tests")
base_pkgs <- rownames(installed.packages(priority = "base"))

manifest <- jsonlite::fromJSON(manifest_path, simplifyVector = FALSE)
manifest_pkgs <- names(manifest$packages)

deploy_optional <- setdiff(suggests, c(test_pkgs, base_pkgs))
missing <- setdiff(deploy_optional, manifest_pkgs)

if (length(missing)) {
  message("check-suggests: deploy-optional Suggests missing from the manifest:")
  for (m in missing) message("  - ", m)
  message("")
  message(
    "These are in Suggests (so installed on the runner) but writeManifest() ",
    "did not record them, so Connect would never receive them. For each, ",
    "either:"
  )
  message(
    "  - reference it on the app's graceful-degradation path, guarded by ",
    "requireNamespace(\"pkg\"), so the manifest scan sees it; or"
  )
  message(
    "  - if the app never names it (a transitive/UX-only dep), add a ",
    "top-level dependencies.R containing requireNamespace(\"pkg\") so renv's ",
    "scanner records it; or"
  )
  message(
    "  - if it is dev/check tooling, list it in Config/Needs/tests so this ",
    "guard ignores it."
  )
  quit(status = 1)
}

message(sprintf(
  "check-suggests: OK (%d deploy-optional Suggests, all present in manifest)",
  length(deploy_optional)
))
