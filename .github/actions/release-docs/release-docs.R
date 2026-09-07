# The two release checks devtools answers directly.
#
# Both ask the same question -- is a generated artefact still current
# with the source it came from -- and both need devtools plus the
# package itself installed, which is why they share one action rather
# than paying for that setup twice.
#
# Neither is reimplemented: check_doc_fields() and build_readme() are
# exported and return usable values, unlike the release_checks()
# internals the release-gate action has to restate; see that script.
#
# Using build_readme() rather than a hand-rolled rmarkdown::render()
# call covers README.qmd as well as README.Rmd, and keeps the
# html_preview = FALSE detail in devtools' hands. That flag is
# load-bearing: the default github_document format also writes a
# README.html, and that untracked file would fail the comparison below
# on every run.
#
# Both report before either exits, so a maintainer fixing one thing per
# push does not discover the second one on the next push.
#
# Env vars: PKG_DIR (default "."), SUMMARY_FILE (markdown fragment,
#           written when set), GITHUB_STEP_SUMMARY (appended when set)

pkg_dir <- Sys.getenv("PKG_DIR", unset = ".")

md <- character()
failed <- FALSE

# -- Every documented function has a \value section --------------------

# Only \value is asked for, though check_doc_fields() defaults to
# c("value", "examples"). The second does not hold across this fleet:
# measured, blockr.core is missing \examples in 35 Rd files,
# blockr.dplyr in 10, blockr.ui in 6 and blockr.ggplot in 3, against one
# single missing \value between them. A gate every package fails on its
# first run is one that gets switched off, and CRAN treats the two
# differently anyway.

md <- c(md, "### Rd \\value sections", "")

if (!dir.exists(file.path(pkg_dir, "man"))) {

  md <- c(md, ":heavy_minus_sign: No man/ directory.", "")

} else {

  missing <- tryCatch(
    devtools::check_doc_fields(pkg_dir, fields = "value")$value,
    error = function(e) e
  )

  if (inherits(missing, "error")) {
    cat(sprintf("::error::The Rd check failed: %s\n", conditionMessage(missing)))
    md <- c(
      md,
      paste0(":x: The Rd check could not run: ", conditionMessage(missing)),
      ""
    )
    failed <- TRUE
  } else if (length(missing)) {
    cat("::error::One or more documented functions have no \\value section.\n")
    md <- c(
      md,
      sprintf(
        ":x: %d documented function(s) do not say what they return.",
        length(missing)
      ),
      "",
      paste0("- `", missing, "`"),
      ""
    )
    failed <- TRUE
  } else {
    md <- c(
      md,
      ":white_check_mark: Every documented function has a \\value section.",
      ""
    )
  }
}

# -- The README is current with its source -----------------------------

# Candidate order matches devtools': a .qmd wins over a .Rmd, and the
# top level wins over inst/.

md <- c(md, "### README freshness", "")

readme <- file.path(
  pkg_dir,
  c("README.qmd", "README.Rmd", file.path("inst", c("README.qmd", "README.Rmd")))
)
readme <- readme[file.exists(readme)]

if (!length(readme)) {

  md <- c(
    md,
    ":heavy_minus_sign: No executable README, so nothing to regenerate.",
    ""
  )

} else {

  cat(sprintf("Regenerating %s to compare.\n", readme[[1L]]))

  rendered <- tryCatch(
    {
      devtools::build_readme(pkg_dir, quiet = FALSE)
      TRUE
    },
    error = function(e) e
  )

  if (inherits(rendered, "error")) {

    # A render that died leaves the tree clean, so reading the tree
    # alone would report "current" -- the false green this whole
    # workflow exists to remove.
    cat("::error::The README did not render; its freshness is unknown.\n")
    md <- c(
      md,
      paste0(
        ":x: The README did not render, so its freshness is unknown: ",
        conditionMessage(rendered)
      ),
      ""
    )
    failed <- TRUE

  } else {

    drift <- system2(
      "git", c("-C", shQuote(pkg_dir), "status", "--porcelain"),
      stdout = TRUE
    )

    if (!length(drift)) {
      md <- c(md, ":white_check_mark: README.md is current with its source.", "")
    } else {
      cat(paste0(
        "::error::README.md is out of date. Regenerate it ",
        "(devtools::build_readme()) and commit the result.\n"
      ))
      cat(drift, sep = "\n")
      md <- c(
        md,
        paste0(
          ":x: README.md does not match its source. Regenerate it with ",
          "`devtools::build_readme()` and commit the result."
        ),
        "",
        "```",
        drift,
        "```",
        ""
      )
      failed <- TRUE
    }
  }
}

# -- Report ------------------------------------------------------------

cat(md, sep = "\n")

write_to <- function(path) {
  if (nzchar(path)) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    write(md, file = path, append = TRUE)
  }
}

write_to(Sys.getenv("SUMMARY_FILE", unset = ""))
write_to(Sys.getenv("GITHUB_STEP_SUMMARY", unset = ""))

if (failed) {
  quit(status = 1L)
}
