# The mechanical CRAN pre-submission checks, reimplemented against base R.
#
# Reads DESCRIPTION, .Rbuildignore, the vignette headers and man/*.Rd, and
# fails when any of six conditions does not hold. Base R only -- no
# devtools, no pkgdepends, nothing off CRAN -- so the job needs nothing
# beyond setup-r and finishes in seconds. That is also what keeps the
# gate callable from a repository outside the blockr fleet, which cannot
# be assumed to install anything.
#
# Deliberately NOT a call to devtools::release_checks(). Its five checks
# route through devtools:::check_status(), which prints "OK" or "WARNING"
# and returns NULL on both branches, so a script wrapping it exits 0
# regardless of what it found. Each check is a few lines, and
# reimplementing them is the only way a finding reaches an exit status.
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

desc <- read.dcf(desc_path)

field <- function(name) {
  if (!name %in% colnames(desc)) {
    return(NA_character_)
  }
  val <- desc[1L, name]
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

# Splits on commas, which the DESCRIPTION dependency grammar does not
# allow inside a version constraint, then reads the operator off the
# front of the parenthesised part. A dependency counts as development
# when its pin has four components and the last is >= 9000 -- devtools'
# rule, kept verbatim so the two cannot drift.
check_dev_versions <- function() {
  name <- "No dependency pinned to a development version"
  fields <- c("Depends", "Imports", "LinkingTo", "Suggests")
  deps <- unlist(lapply(fields, field))
  deps <- deps[!is.na(deps)]

  entries <- trimws(unlist(strsplit(paste(deps, collapse = ","), ",")))
  entries <- entries[nzchar(entries)]
  pinned <- entries[grepl("\\(", entries)]

  if (!length(pinned)) {
    return(outcome(name, "pass", "no version-pinned dependencies"))
  }

  pkg <- trimws(sub("\\s*\\(.*$", "", pinned))
  ver <- trimws(sub("^[^0-9]*", "", sub("^[^(]*\\(([^)]*)\\).*$", "\\1", pinned)))

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
        paste0(pkg[is_dev], " (", ver[is_dev], ")", collapse = ", ")
      )
    )
  } else {
    outcome(name, "pass", sprintf("%d pinned, none a devel version", length(pinned)))
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

# -- Every documented function has a \value section --------------------

# Rd files without \usage are excluded: package-level documentation,
# re-export stubs and data sets have nothing to describe a return value
# for, and R CMD check does not ask them to. That leaves the case CRAN
# rejects on routinely -- a documented function whose result goes
# unexplained.
#
# Only \value is gated, though devtools::check_doc_fields() defaults to
# c("value", "examples"). The second one does not hold across this
# fleet: measured, blockr.core is missing \examples in 35 Rd files,
# blockr.dplyr in 10, blockr.ui in 6 and blockr.ggplot in 3, against one
# single missing \value between them. A gate every package fails on its
# first run is one that gets switched off, and CRAN treats the two
# differently anyway -- a missing \value comes back as a change request,
# a missing example usually does not come back at all.
check_doc_fields <- function() {
  name <- "Every documented function has a \\value section"
  man_dir <- file.path(pkg_dir, "man")

  if (!dir.exists(man_dir)) {
    return(outcome(name, "skip", "no man/ directory"))
  }

  paths <- list.files(man_dir, pattern = "\\.Rd$", full.names = TRUE)

  if (!length(paths)) {
    return(outcome(name, "skip", "no Rd files in man/"))
  }

  unparsed <- character()
  missing <- character()

  for (path in paths) {
    rd <- tryCatch(
      suppressWarnings(tools::parse_Rd(path, permissive = TRUE)),
      error = function(e) NULL
    )

    if (is.null(rd)) {
      unparsed <- c(unparsed, basename(path))
      next
    }

    tags <- unlist(lapply(rd, attr, "Rd_tag"))

    if (!"\\usage" %in% tags) {
      next
    }

    if (!"\\value" %in% tags) {
      missing <- c(missing, basename(path))
    }
  }

  problems <- character()

  if (length(unparsed)) {
    problems <- c(problems, paste0(
      "unparseable Rd: ", paste0(unparsed, collapse = ", ")
    ))
  }

  if (length(missing)) {
    problems <- c(problems, paste0(
      "missing \\value in ", length(missing), " file(s): ",
      paste0(missing, collapse = ", ")
    ))
  }

  if (length(problems)) {
    outcome(name, "fail", paste0(problems, collapse = "; "))
  } else {
    outcome(name, "pass", sprintf("%d Rd file(s) checked", length(paths)))
  }
}

# -- Run, report, exit -------------------------------------------------

checks <- list(
  check_version(),
  check_dev_versions(),
  check_remotes(),
  check_news_md(),
  check_vignette_titles(),
  check_doc_fields()
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
