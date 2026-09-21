# The host node of the containerised testbed.
#
# Runs a jobset, waits for the workers to finish it, then asserts the things
# that must be true of any correct run and exits non-zero if they are not. The
# container's exit code is the test result, so `docker compose up
# --exit-code-from host` is the whole harness.

library(jobR)

env_num <- function(name, default) {
  v <- Sys.getenv(name)
  if (!nzchar(v)) default else as.numeric(v)
}
env_chr <- function(name, default) {
  v <- Sys.getenv(name)
  if (!nzchar(v)) default else v
}

n_jobs    <- env_num("JOBR_JOBS", 60)
chunksize <- env_num("JOBR_CHUNKSIZE", 5)
seconds   <- env_num("JOBR_SECONDS", 0.4)
lease     <- env_num("JOBR_LEASE", 20)
expect_hosts <- env_num("JOBR_EXPECT_HOSTS", 2)
phrase    <- env_chr("JOBR_PASSPHRASE", "testbed-alpha-bravo-charlie")
port      <- env_num("JOBR_PORT", 5555)
work_dir  <- env_chr("JOBR_WORK", "/tmp/jobr-host")
deadline  <- env_num("JOBR_DEADLINE", 300)

project <- system.file("examples", "benchmark", package = "jobR")
jobs <- jobr_benchmark_jobs(n = n_jobs, seconds = seconds)

message("== jobR testbed host ==")
message("  R         : ", getRversion())
message("  jobs      : ", n_jobs, " x ", seconds, "s, chunksize ", chunksize)
message("  lease     : ", lease, "s")
message("  expecting : at least ", expect_hosts, " distinct worker hosts")

h <- host_new(project, jobs = jobs, chunksize = chunksize,
              passphrase = phrase, work_dir = work_dir,
              lease_seconds = lease, jobset = "testbed")

jobr_serve(h, sprintf("tcp://0.0.0.0:%d", port),
           max_seconds = deadline, ready_file = "/tmp/jobr-ready", quiet = FALSE)

# ---- assertions -------------------------------------------------------------
# The definition of a correct run lives in assertions.R, free of container and
# network concerns, so that it can be tested on a machine that cannot run
# Docker. See tests/testthat/test-testbed.R.

source("/opt/jobr/docker/assertions.R")

results  <- host_results(h)
led      <- ledger_open(file.path(work_dir, "ledger.tsv"))
n_chunks <- nrow(chunk_plan(n_jobs, chunksize))
st       <- chunk_state(led, "testbed", n_chunks)

problems <- testbed_problems(results, st, n_jobs, expect_hosts)

message("")
message("== results ==")
report <- tryCatch(jobr_benchmark_report(results), error = function(e) e)
if (inherits(report, "error")) {
  message("  could not summarise: ", conditionMessage(report))
} else {
  print(report)
}

if (length(problems)) {
  message("")
  message("== FAILED ==")
  for (p in problems) message("  - ", p)
  quit(status = 1)
}
message("")
message("== OK == all ", n_jobs, " jobs, all ", n_chunks, " chunks done")
quit(status = 0)
