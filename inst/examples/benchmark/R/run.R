# A job whose cost you know in advance: it burns `row$seconds` of real CPU.
# That makes the arithmetic honest -- 240 jobs at 1s is 240 CPU-seconds, so the
# wall-clock time of a run tells you how much parallelism you actually got.
#
# Each result records which machine and process did the work, so after a run you
# can see the split directly with jobR::jobr_benchmark_report().

# Sourced by project-relative path. R/burn.R travels to the workers only
# because it is listed in Files -- nothing is shipped implicitly.
source("R/burn.R")

run_job <- function(row) {
  started <- Sys.time()
  burn(row$seconds)
  finished <- Sys.time()

  data.frame(
    id       = row$id,
    host     = Sys.info()[["nodename"]],
    pid      = Sys.getpid(),
    elapsed  = as.numeric(difftime(finished, started, units = "secs")),
    finished = finished
  )
}
