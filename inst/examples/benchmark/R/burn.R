# Consume a set amount of real CPU time.
#
# Deliberately CPU-bound rather than Sys.sleep(): sleeping would parallelise
# perfectly even on a single core, which is precisely the thing being measured.
burn <- function(seconds) {
  t0 <- Sys.time()
  x <- 0
  repeat {
    x <- x + sum(sqrt(runif(2000)))
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) >= seconds) break
  }
  x
}
