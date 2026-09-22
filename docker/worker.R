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
need_rtt <- env_num("JOBR_REQUIRE_RTT_MS", 0)

message("== jobR testbed worker ==")
message("  R     : ", getRversion())
message("  host  : ", url)
message("  cores : ", cores)
if (need_rtt > 0) message("  gate  : wait for a round trip of >= ", need_rtt, "ms")

# Two conditions, not one. The host has to be up, and -- when this worker is
# the impaired one -- its link has to be bad BEFORE it joins.
#
# The impairment is applied from outside this container by a sidecar sharing
# its network namespace, and compose cannot express "start after the qdisc
# exists". Gating on a sentinel file would work until a stale one survived in
# the volume, at which point the worker would join over a clean link and the
# run would still report itself as an impaired test. Measuring the round trip
# instead cannot go stale: the gate opens only once the link is observably
# slow, so an unimpaired run can never masquerade as an impaired one.
deadline <- Sys.time() + wait
repeat {
  t0 <- Sys.time()
  ok <- tryCatch(jobr_ping(url, timeout_ms = env_num("JOBR_PING_MS", 4000),
                           quiet = TRUE)$reachable,
                 error = function(e) FALSE)
  rtt <- as.numeric(difftime(Sys.time(), t0, units = "secs")) * 1000
  if (isTRUE(ok) && rtt >= need_rtt) {
    if (need_rtt > 0) message("  link is impaired (round trip ", round(rtt),
                              "ms), joining now")
    break
  }
  if (Sys.time() > deadline) {
    if (isTRUE(ok)) {
      message("host is reachable but the link never became impaired ",
              "(last round trip ", round(rtt), "ms); is the netem sidecar up?")
    } else {
      message("host never became reachable at ", url)
    }
    quit(status = 1)
  }
  Sys.sleep(2)
}

res <- jobr_join(url, phrase, cores = cores,
                 cache_dir = file.path(tempdir(), "jobr-worker"),
                 timeout_ms = env_num("JOBR_TIMEOUT_MS", 5000),
                 max_chunks = env_num("JOBR_MAX_CHUNKS", Inf),
                 max_seconds = env_num("JOBR_MAX_SECONDS", 280), quiet = FALSE)
message("worker done: ", res$chunks_done, " chunks")
quit(status = 0)
