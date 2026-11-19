# Resolves the dependencies of the package in the working directory into
# the lockfile LOCKFILE, as setup-r-dependencies does.
# The refs are any::sessioninfo and deps::., then those in EXTRA.
# The dependency types are the R expression DEPENDENCIES, plus the
# Config/Needs field of each entry in NEEDS.
# Installed packages are kept rather than upgraded, as there.
#
# Env vars: DEPENDENCIES, EXTRA, NEEDS, LOCKFILE

split_refs <- function(x) {
  x <- strsplit(x, "[[:space:],]+")[[1L]]
  x[nzchar(x)]
}

needs <- split_refs(Sys.getenv("NEEDS"))
needs <- if (length(needs)) sprintf("Config/Needs/%s", needs)

refs <- c("deps::.", "any::sessioninfo", split_refs(Sys.getenv("EXTRA")))

dependencies <- eval(parse(text = Sys.getenv("DEPENDENCIES", '"all"')))

# The lockfile records the system packages only while pak looks them up,
# and check-sysreqs.sh reads them from there.
Sys.setenv(PKG_SYSREQS = "true", PKGCACHE_HTTP_VERSION = "2")

pak::lockfile_create(
  refs,
  lockfile = Sys.getenv("LOCKFILE"),
  upgrade = FALSE,
  dependencies = c(needs, dependencies)
)
