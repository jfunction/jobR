# One image per R version, so the testbed can run a genuinely mixed fleet --
# which is the normal case for this package and the source of the subtlest bugs
# (see ?versions).
#
# Built from the repository root:
#   docker build -f docker/Dockerfile --build-arg R_VERSION=4.4.1 -t jobr:4.4.1 .
ARG R_VERSION=4.4.1
FROM rocker/r-ver:${R_VERSION}

# nanonext bundles NNG and mbedTLS and needs compiling. rocker images carry a
# toolchain already; libssl is needed by some dependency chains.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl-dev procps \
 && rm -rf /var/lib/apt/lists/*

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

RUN R CMD INSTALL --no-multiarch . \
 && Rscript -e 'library(jobR); cat("jobR", as.character(packageVersion("jobR")), \
      "on R", getRversion(), "\n")'

COPY docker/host.R docker/worker.R docker/assertions.R docker/
