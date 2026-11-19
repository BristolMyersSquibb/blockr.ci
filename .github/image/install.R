# Installs what the image holds for the repos it is built for: the
# packages in PACKAGES, which names each repo at its branch and the
# packages that ci.yaml adds, with every dependency the jobs install.
# That is Suggests too, and the Config/Needs fields in NEEDS, which
# ci.yaml passes.
# The pak call installs the system packages they need with apt as well.

split_refs <- function(x) {
  x <- strsplit(x, "[[:space:],]+")[[1L]]
  x[nzchar(x)]
}

refs <- split_refs(Sys.getenv("PACKAGES"))

if (!length(refs)) {
  stop("PACKAGES names no packages to install.")
}

needs <- split_refs(Sys.getenv("NEEDS"))

Sys.setenv(PKGCACHE_HTTP_VERSION = "2")

pak::pkg_install(
  refs,
  dependencies = c(sprintf("Config/Needs/%s", needs), "all"),
  upgrade = TRUE,
  ask = FALSE
)

pak::cache_clean()
