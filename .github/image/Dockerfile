# syntax=docker/dockerfile:1

# The image that the Ubuntu jobs of ci.yaml run in, for a caller that sets
# `image: true`.
# The image workflow builds it every day, once per R version, and pushes it
# to ghcr.io/bristolmyerssquibb/blockr.ci.
# It holds what those jobs would otherwise fetch while they run: R, the
# tools, and the system and R packages of the repos it is built for.

FROM ubuntu:26.04

LABEL org.opencontainers.image.source="https://github.com/BristolMyersSquibb/blockr.ci"
LABEL org.opencontainers.image.description="R, tools and dependencies for the Ubuntu jobs of blockr.ci"

# The R version as Posit names its build of R, the Quarto pin of ci.yaml,
# the pak refs to install and the Config/Needs fields to install as well.
# Posit names a build of R by its exact version, such as 4.6.2, and its
# daily build of R-devel "devel".
# The refs and the fields are each separated by spaces.
ARG R_VERSION
ARG QUARTO_VERSION
ARG PACKAGES
ARG NEEDS

# The variables that r-lib/actions/setup-r exports on a runner, so that a
# job sees the same R settings in the image.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    NOT_CRAN=true \
    _R_CHECK_SYSTEM_CLOCK_=FALSE \
    RSPM=https://packagemanager.posit.co/cran/__linux__/resolute/latest \
    RENV_CONFIG_REPOS_OVERRIDE=https://packagemanager.posit.co/cran/__linux__/resolute/latest

# Tools that the jobs take from the runner image or from setup-r.
# The checkout needs git, and R CMD check --as-cran needs qpdf,
# ghostscript and the checkbashisms of devscripts.
# The install-deps action reads its lockfile with jq.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl devscripts file ghostscript git gnupg jq \
      qpdf tzdata unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/*

# The GitHub CLI, with which parse-deps reads the pull request body.
RUN curl -fsSL -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Google Chrome, which chromote finds before any Chromium, as on the runner.
# With Chrome in place, the chromote rule of pak skips its Chromium PPA.
RUN curl -fsSL -o /tmp/chrome.deb \
      https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/chrome.deb \
 && rm -rf /tmp/chrome.deb /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/quarto.deb \
      "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/quarto.deb \
 && rm -rf /tmp/quarto.deb /var/lib/apt/lists/*

# R from the build of Posit that setup-r installs on a runner.
RUN curl -fsSL -o /tmp/r.deb \
      "https://cdn.posit.co/r/ubuntu-2604/pkgs/r-${R_VERSION}_1_amd64.deb" \
 && apt-get update \
 && apt-get install -y /tmp/r.deb \
 && rm -rf /tmp/r.deb /var/lib/apt/lists/* \
 && ln -s "/opt/R/${R_VERSION}/bin/R" /usr/local/bin/R \
 && ln -s "/opt/R/${R_VERSION}/bin/Rscript" /usr/local/bin/Rscript

# The repositories and the user agent that setup-r writes to its R profile.
# P3M serves binaries only to an agent that names the R version.
# It has none for R-devel on Ubuntu 26.04, so the image of devel builds its
# R packages from source.
RUN printf '%s\n' \
      'options(' \
      '  repos = c(RSPM = Sys.getenv("RSPM"), CRAN = "https://cran.rstudio.com"),' \
      '  HTTPUserAgent = sprintf("R/%s R (%s %s) on GitHub Actions", getRversion(), getRversion(), paste(R.version$platform, R.version$arch, R.version$os))' \
      ')' \
      >> "/opt/R/${R_VERSION}/lib/R/etc/Rprofile.site" \
 && Rscript -e 'install.packages("pak", repos = sprintf("https://r-lib.github.io/p/pak/stable/%s/%s/%s", .Platform$pkgType, R.Version()$os, R.Version()$arch))'

# The R packages that PACKAGES resolves to, with their system packages.
# The token only raises the GitHub rate limit, and stays out of the image.
COPY install.R /tmp/install.R
RUN --mount=type=secret,id=GITHUB_PAT,env=GITHUB_PAT \
    PKG_SYSREQS=true Rscript /tmp/install.R \
 && rm -rf /tmp/install.R /var/lib/apt/lists/* /root/.cache/R
