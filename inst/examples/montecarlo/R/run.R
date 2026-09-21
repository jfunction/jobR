# The entrypoint must define run_job(). It is sourced once per worker, with the
# project directory as the working directory, so relative paths behave.
source("R/estimate.R")

run_job <- function(row) {
  data.frame(
    id       = row$id,
    n        = row$n,
    estimate = estimate_pi(row$n, row$seed),
    stringsAsFactors = FALSE   # explicit: R 3.6 defaults this to TRUE (?versions)
  )
}
