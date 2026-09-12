# Helper sourced by the entrypoint. Anything listed in Files travels with the
# bundle, so a project can be spread across as many scripts as it likes.
estimate_pi <- function(n, seed) {
  set.seed(seed)
  inside <- sum(runif(n)^2 + runif(n)^2 <= 1)
  4 * inside / n
}
