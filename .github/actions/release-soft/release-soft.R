# The release checks worth reading but not worth gating on.
#
# Spelling, URL reachability and the NOTEs from an --as-cran run all
# turn on things outside the package: jargon, third-party redirects,
# transient 503s and CRAN's own incoming-feasibility service. A volatile
# signal used as a gate is one that gets ignored or switched off, which
# is the same argument r-devel/recheck makes about itself. So this
# script always exits 0, and reports what it found.
#
# That makes "the check did not run" a result rather than a reason to
# redden a pull request, which is why every check is wrapped: a missing
# package or a dead network shows up as a line in the report.
#
# The --as-cran leg is not a second copy of what ci.yaml's matrix
# already does. That matrix checks --as-cran and fails on any NOTE, but
# with _R_CHECK_CRAN_INCOMING_ off it never reaches the checks a
# submission is actually read against: new-submission notes, the licence
# and URL scan, the DESCRIPTION spell check, the maintainer address.
# The caller turns those on through the environment.
#
# Spelling goes through spelling::spell_check_package() rather than
# devtools::spell_check(), which is a two-line wrapper around it --
# same check, and it keeps devtools' 94 recursive dependencies out of a
# job that needs 12.
#
# Env vars: PKG_DIR (default "."), SUMMARY_FILE (markdown fragment,
#           written when set), GITHUB_STEP_SUMMARY (appended when set),
#           CHECK_ARGS (comma-separated R CMD check arguments)

pkg_dir <- Sys.getenv("PKG_DIR", unset = ".")

md <- c("### Soft checks", "", "Reported on every push, never a gate.", "")

# -- Spelling ----------------------------------------------------------

# Honours inst/WORDLIST, which is what makes a spell check survivable on
# a package full of jargon.

spelling <- tryCatch(
  spelling::spell_check_package(pkg_dir),
  error = function(e) e
)

md <- c(md, "#### Spelling", "")

md <- if (inherits(spelling, "error")) {
  c(md, paste0(":warning: The spell check could not run: ",
               conditionMessage(spelling)), "")
} else if (!nrow(spelling)) {
  c(md, ":white_check_mark: No misspellings.", "")
} else {
  print(spelling)
  c(
    md,
    sprintf(
      ":warning: %d word(s) not in the dictionary or inst/WORDLIST.",
      nrow(spelling)
    ),
    "",
    paste0(
      "- `", spelling$word, "` -- ",
      vapply(spelling$found, function(x) paste(x, collapse = ", "), character(1L))
    ),
    ""
  )
}

# -- URLs --------------------------------------------------------------

urls <- tryCatch(urlchecker::url_check(pkg_dir), error = function(e) e)

md <- c(md, "#### URLs", "")

md <- if (inherits(urls, "error")) {
  c(md, paste0(":warning: The URL check could not run: ",
               conditionMessage(urls)), "")
} else if (!nrow(urls)) {
  c(md, ":white_check_mark: All URLs resolve.", "")
} else {
  print(urls)
  cols <- intersect(c("URL", "From", "Status", "Message"), names(urls))
  c(
    md,
    sprintf(":warning: %d URL(s) worth a look.", nrow(urls)),
    "",
    paste0("| ", paste(cols, collapse = " | "), " |"),
    paste0("| ", paste(rep("---", length(cols)), collapse = " | "), " |"),
    apply(urls[cols], 1L, function(row) {
      paste0("| ", paste(trimws(as.character(row)), collapse = " | "), " |")
    }),
    ""
  )
}

# -- R CMD check --as-cran ---------------------------------------------

# Setting `error_on = "never"` keeps a NOTE from failing the step, and
# the tryCatch keeps a build that dies outright from doing so either.

args <- Sys.getenv("CHECK_ARGS", unset = "--no-manual,--as-cran,--run-donttest")
args <- trimws(strsplit(args, ",")[[1L]])
args <- args[nzchar(args)]

check <- tryCatch(
  rcmdcheck::rcmdcheck(
    path = pkg_dir,
    args = args,
    error_on = "never",
    quiet = FALSE
  ),
  error = function(e) e
)

md <- c(md, sprintf("#### R CMD check %s", paste(args, collapse = " ")), "")

block <- function(title, items) {
  if (!length(items)) {
    return(character())
  }
  c(
    sprintf("**%s**", title),
    "",
    unlist(lapply(items, function(x) c("```", strsplit(x, "\n")[[1L]], "```", "")))
  )
}

md <- if (inherits(check, "error")) {
  c(md, paste0(":warning: The check could not run: ",
               conditionMessage(check)), "")
} else {
  found <- length(check$errors) + length(check$warnings) + length(check$notes)
  c(
    md,
    if (found) {
      sprintf(":warning: %d finding(s) from the CRAN incoming checks.", found)
    } else {
      ":white_check_mark: No errors, warnings or notes."
    },
    "",
    block("Errors", check$errors),
    block("Warnings", check$warnings),
    block("Notes", check$notes)
  )
}

# -- Report ------------------------------------------------------------

write_to <- function(path) {
  if (nzchar(path)) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    write(md, file = path, append = TRUE)
  }
}

write_to(Sys.getenv("SUMMARY_FILE", unset = ""))
write_to(Sys.getenv("GITHUB_STEP_SUMMARY", unset = ""))
