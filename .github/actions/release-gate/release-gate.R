# The five release_checks() conditions, reimplemented readably.
#
# Reads DESCRIPTION, .Rbuildignore and the vignette headers, and fails
# when any of the five does not hold. The only dependency is desc, which
# owns the DESCRIPTION grammar and costs two recursive dependencies
# against devtools' 94, so this job stays in the seconds range and does
# not need the package itself installed.
#
# These five are reimplemented because devtools offers no way to read
# their result. They are not exported, and they route through
# devtools:::check_status(), which returns NULL whether the check passed
# or failed -- so a script calling one exits 0 regardless. Measured, the
# finding exists only as cli-formatted text on *stderr* ("x WARNING:
# version (0.1.1.9001) should have exactly three components"), so
# wrapping them means grepping a message stream through ::: and coupling
# to print formatting. Reimplementing the rule is the smaller coupling.
#
# The checks devtools *can* answer are called rather than rewritten:
# check_doc_fields() and build_readme() are exported and return usable
# values, and both run in the workflow's `docs` job.
#
# The reimplementations stay faithful to what devtools tests, with one
# deliberate divergence noted at check_vignette_titles() below.
#
# Env vars: PKG_DIR (default "."), SUMMARY_FILE (markdown fragment,
#           written when set), GITHUB_STEP_SUMMARY (appended when set)

pkg_dir <- Sys.getenv("PKG_DIR", unset = ".")

desc_path <- file.path(pkg_dir, "DESCRIPTION")

if (!file.exists(desc_path)) {
  cat(sprintf("::error::release-gate: no DESCRIPTION at '%s'.\n", desc_path))
  quit(status = 1L)
}

field <- function(name) {
  val <- desc::desc_get_field(name, default = NA_character_, file = desc_path)
  if (is.na(val) || !nzchar(trimws(val))) NA_character_ else val
}

# Every check returns one of these. "skip" is a pass that says the
# condition did not apply -- no NEWS.md, no vignettes, no man/ -- and is
# reported as such rather than as a silent success, so a check that goes
# missing is visible instead of green.
outcome <- function(name, status, detail) {
  list(name = name, status = status, detail = detail)
}

# -- Version has exactly three components ------------------------------

check_version <- function() {
  name <- "Version has exactly three components"
  ver <- field("Version")

  if (is.na(ver)) {
    return(outcome(name, "fail", "DESCRIPTION carries no Version field"))
  }

  parts <- tryCatch(unlist(numeric_version(ver)), error = function(e) NULL)

  if (is.null(parts)) {
    return(outcome(name, "fail", sprintf("version (%s) is not a version", ver)))
  }

  if (length(parts) == 3L) {
    outcome(name, "pass", ver)
  } else {
    outcome(
      name, "fail",
      sprintf("version (%s) should have exactly three components", ver)
    )
  }
}

# -- No dependency pinned to a development version ---------------------

# Dependency parsing goes through desc, which owns the DESCRIPTION
# grammar -- the alternative is hand-rolling comma splitting, paren
# extraction and operator stripping, and getting one of them subtly
# wrong. Only the four fields devtools looks at are considered, so the
# two cannot drift; `*` is desc's marker for an unconstrained
# dependency. A dependency counts as development when its pin has four
# components and the last is >= 9000 -- devtools' rule, kept verbatim.
check_dev_versions <- function() {
  name <- "No dependency pinned to a development version"

  deps <- desc::desc_get_deps(file = desc_path)
  deps <- deps[deps$type %in% c("Depends", "Imports", "LinkingTo", "Suggests"), ]
  pinned <- deps[deps$version != "*", , drop = FALSE]

  if (!nrow(pinned)) {
    return(outcome(name, "pass", "no version-pinned dependencies"))
  }

  ver <- trimws(sub("^[^0-9]*", "", pinned$version))

  is_dev <- vapply(
    ver,
    function(x) {
      parts <- tryCatch(unlist(numeric_version(x)), error = function(e) NULL)
      !is.null(parts) && length(parts) == 4L && parts[[4L]] >= 9000L
    },
    logical(1L),
    USE.NAMES = FALSE
  )

  if (any(is_dev)) {
    outcome(
      name, "fail",
      paste0(
        "depends on development versions of: ",
        paste0(pinned$package[is_dev], " (", ver[is_dev], ")", collapse = ", ")
      )
    )
  } else {
    outcome(name, "pass", sprintf("%d pinned, none a devel version", nrow(pinned)))
  }
}

# -- No Remotes field --------------------------------------------------

check_remotes <- function() {
  name <- "No Remotes field in DESCRIPTION"
  remotes <- field("Remotes")

  if (is.na(remotes)) {
    return(outcome(name, "pass", "no Remotes field"))
  }

  named <- trimws(unlist(strsplit(remotes, "[,\n]")))
  named <- named[nzchar(named)]

  outcome(
    name, "fail",
    paste0(
      "Remotes must go before submission; it names ",
      paste0(named, collapse = ", ")
    )
  )
}

# -- NEWS.md is not build-ignored, and no stale inst/NEWS.Rd -----------

# Both halves say the same thing: CRAN has supported NEWS.md for years,
# so neither hiding it nor shipping a converted copy is still needed.
# Only reached when NEWS.md exists, since a package without one has
# nothing to ignore -- devtools returns early there too.
check_news_md <- function() {
  name <- "NEWS.md is not build-ignored, no stale inst/NEWS.Rd"

  if (!file.exists(file.path(pkg_dir, "NEWS.md"))) {
    return(outcome(name, "skip", "no NEWS.md"))
  }

  problems <- character()
  ignore_path <- file.path(pkg_dir, ".Rbuildignore")

  if (file.exists(ignore_path)) {
    lines <- readLines(ignore_path, warn = FALSE)
    # Matched both ways because .Rbuildignore holds regexes: the escaped
    # spelling is what a real entry looks like (^NEWS\.md$), the plain
    # one catches a hand-written entry that forgot the escape.
    hits <- lines[grepl("NEWS\\.md", lines, fixed = TRUE) |
                    grepl("NEWS.md", lines, fixed = TRUE)]
    if (length(hits)) {
      problems <- c(problems, paste0(
        "NEWS.md is build-ignored by .Rbuildignore (",
        paste0(trimws(hits), collapse = ", "),
        "); CRAN renders it, so drop the entry"
      ))
    }
  }

  if (file.exists(file.path(pkg_dir, "inst", "NEWS.Rd"))) {
    problems <- c(problems, paste0(
      "inst/NEWS.Rd exists alongside NEWS.md; the converted copy goes ",
      "stale silently and can be removed"
    ))
  }

  if (length(problems)) {
    outcome(name, "fail", paste0(problems, collapse = "; "))
  } else {
    outcome(name, "pass", "NEWS.md ships as itself")
  }
}

# -- No placeholder vignette titles ------------------------------------

# Scans vignettes/ by file extension rather than through
# tools::pkgVignettes(). That function resolves vignettes through the
# registered engines, so on a runner without the quarto package every
# .qmd is invisible to it and the check passes by finding nothing --
# a false green on exactly the packages in this fleet, whose vignettes
# are .qmd. Reading the headers directly needs no engine at all.
check_vignette_titles <- function() {
  name <- "No placeholder vignette titles"
  vig_dir <- file.path(pkg_dir, "vignettes")

  if (!dir.exists(vig_dir)) {
    return(outcome(name, "skip", "no vignettes/ directory"))
  }

  docs <- list.files(
    vig_dir,
    pattern = "\\.(rmd|qmd|md|rnw|rtex|rhtml|rrst)$",
    ignore.case = TRUE,
    full.names = TRUE
  )

  if (!length(docs)) {
    return(outcome(name, "skip", "no vignette sources in vignettes/"))
  }

  has_placeholder <- vapply(
    docs,
    function(path) {
      head <- readLines(path, n = 30L, warn = FALSE)
      any(grepl("Vignette Title", head, fixed = TRUE))
    },
    logical(1L),
    USE.NAMES = FALSE
  )

  if (any(has_placeholder)) {
    outcome(
      name, "fail",
      paste0(
        "placeholder 'Vignette Title' left in the title field and/or the ",
        "VignetteIndexEntry of: ",
        paste0(basename(docs[has_placeholder]), collapse = ", ")
      )
    )
  } else {
    outcome(name, "pass", sprintf("%d vignette(s) titled", length(docs)))
  }
}

# -- Run, report, exit -------------------------------------------------

checks <- list(
  check_version(),
  check_dev_versions(),
  check_remotes(),
  check_news_md(),
  check_vignette_titles()
)

status <- vapply(checks, `[[`, character(1L), "status")
failed <- checks[status == "fail"]

label <- c(pass = "OK", fail = "FAIL", skip = "n/a")
mark <- c(pass = ":white_check_mark:", fail = ":x:", skip = ":heavy_minus_sign:")

for (check in checks) {
  cat(sprintf("%-5s %s -- %s\n", label[[check$status]], check$name, check$detail))
}

for (check in failed) {
  cat(sprintf("::error::%s: %s\n", check$name, check$detail))
}

# Markdown for the step summary and for the sticky comment the report
# job rewrites. Both read the same fragment, so the two cannot disagree.
markdown <- c(
  "### Hard gates",
  "",
  "| Check | Result |",
  "| --- | --- |",
  vapply(
    checks,
    function(check) {
      sprintf(
        "| %s | %s %s |",
        gsub("|", "\\|", check$name, fixed = TRUE),
        mark[[check$status]],
        gsub("|", "\\|", check$detail, fixed = TRUE)
      )
    },
    character(1L)
  ),
  ""
)

write_to <- function(path) {
  if (nzchar(path)) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    write(markdown, file = path, append = TRUE)
  }
}

write_to(Sys.getenv("SUMMARY_FILE", unset = ""))
write_to(Sys.getenv("GITHUB_STEP_SUMMARY", unset = ""))

if (length(failed)) {
  cat(sprintf(
    "\n%d of %d hard gates failed. Fix them before submitting.\n",
    length(failed), length(checks)
  ))
  quit(status = 1L)
}

cat("\nAll hard gates pass at this commit.\n")
