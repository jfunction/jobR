# A worker node of the containerised testbed.
#
# Waits for the host to be reachable, then joins and works until the jobset is
# done. Retrying the connection is not a nicety: compose starts containers
# together, so a worker will usually be up before the host has bound its socket.

library(jobR)

env_chr <- function(n, d) { v <- Sys.getenv(n); if (!nzchar(v)) d else v }
env_num <- function(n, d) { v <- Sys.getenv(n); if (!nzchar(v)) d else as.numeric(v) }

url    <- env_chr("JOBR_URL", "tcp://host:5555")
phrase <- env_chr("JOBR_PASSPHRASE", "testbed-alpha-bravo-charlie")
cores  <- env_num("JOBR_CORES", 1)
wait   <- env_num("JOBR_WAIT", 120)

message("== jobR testbed worker ==")
message("  R     : ", getRversion())
message("  host  : ", url)
message("  cores : ", cores)

deadline <- Sys.time() + wait
repeat {
  ok <- tryCatch(jobr_ping(url, timeout_ms = 2000, quiet = TRUE)$reachable,
                 error = function(e) FALSE)
  if (isTRUE(ok)) break
  if (Sys.time() > deadline) {
    message("host never became reachable at ", url)
    quit(status = 1)
  }
  Sys.sleep(2)
}

res <- jobr_join(url, phrase, cores = cores,
                 cache_dir = file.path(tempdir(), "jobr-worker"),
                 max_seconds = env_num("JOBR_MAX_SECONDS", 280), quiet = FALSE)
message("worker done: ", res$chunks_done, " chunks")
quit(status = 0)
