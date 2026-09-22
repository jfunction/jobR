# One image per R version, so the testbed can run a genuinely mixed fleet --
# which is the normal case for this package and the source of the subtlest bugs
# (see ?versions).
#
# Built from the repository root:
#   docker build -f docker/Dockerfile --build-arg R_VERSION=4.4.1 -t jobr:4.4.1 .
ARG R_VERSION=4.4.1
FROM rocker/r-ver:${R_VERSION}

# Deliberately no apt step. nanonext bundles NNG and mbedTLS, and digest, zip
# and mirai need no system libraries, so the toolchain rocker already carries is
# enough. Installing anything would also break the oldest image outright:
# rocker/r-ver:3.6.3 is built on Debian buster, which is end-of-life and has
# moved to archive.debian.org, so `apt-get update` returns 404 there.

# Dependencies first, so editing the package does not invalidate this layer.
# mirai is Suggested and only needed for cores > 1, but the testbed exercises
# multi-core workers, so it is installed here.
RUN Rscript -e 'install.packages(c("nanonext","digest","zip","mirai"), \
      repos = "https://cloud.r-project.org")' \
 && Rscript -e 'stopifnot(all(c("nanonext","digest","zip","mirai") %in% \
      rownames(installed.packages())))'

WORKDIR /opt/jobr
COPY DESCRIPTION NAMESPACE ./
COPY R/ R/
COPY man/ man/
COPY data/ data/
COPY inst/ inst/

# getRversion() returns an R_system_version, which cat() cannot print -- it is
# list-backed. as.character() on both, or this smoke test fails the build while
# the install it is checking has actually succeeded.
RUN R CMD INSTALL --no-multiarch . \
 && Rscript -e 'library(jobR); cat("jobR", as.character(packageVersion("jobR")), \
      "on R", as.character(getRversion()), "\n")'

COPY docker/host.R docker/worker.R docker/assertions.R docker/
