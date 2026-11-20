# Installs what the image holds for the repos it is built for: the
# packages in PACKAGES, which names each repo at its branch and the
# packages that the workflows with a job in the image add, with every
# dependency the jobs install.
# That is Suggests too, and the Config/Needs fields in NEEDS, which those
# workflows pass.
# The pak call installs the system packages they need with apt as well.
# Then the script removes the packages of the organisation, which
# ORG_PACKAGES names, so that the image holds what they depend on but none
# of them.

split_refs <- function(x) {
  x <- strsplit(x, "[[:space:],]+")[[1L]]
  x[nzchar(x)]
}

refs <- split_refs(Sys.getenv("PACKAGES"))

if (!length(refs)) {
  stop("PACKAGES names no packages to install.")
}

needs <- split_refs(Sys.getenv("NEEDS"))

org_packages <- split_refs(Sys.getenv("ORG_PACKAGES"))

if (!length(org_packages)) {
  stop("ORG_PACKAGES names no packages to remove.")
}

Sys.setenv(PKGCACHE_HTTP_VERSION = "2")

pak::pkg_install(
  refs,
  dependencies = c(sprintf("Config/Needs/%s", needs), "all"),
  upgrade = TRUE,
  ask = FALSE
)

# The image holds none of the packages of the organisation.
# A copy in the image would be as old as the build, and every job would
# hold it, whether the job's package needs it or not.
# A job installs the packages of the organisation that its own package
# needs instead.
# The pak call above installed them anyway.
# That way, it installed what they depend on, system packages included.
org <- intersect(org_packages, rownames(installed.packages()))
message(
  "Removing the packages of the organisation: ",
  paste(org, collapse = " ")
)
remove.packages(org, lib = .libPaths())

pak::cache_clean()

# A job uses the rules for system requirements that pak fetched here, so
# the build fails without them.
rules <- file.path(Sys.getenv("R_PKG_CACHE_DIR"), "R", "pkgcache", "sysreqs")

if (!file.exists(file.path(rules, "HEAD"))) {
  stop("pak kept no rules for system requirements in ", rules, ".")
}
