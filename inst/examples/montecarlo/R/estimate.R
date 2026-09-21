# Helper sourced by the entrypoint. Anything listed in Files travels with the
# bundle, so a project can be spread across as many scripts as it likes.
#
# The seed arrives in the jobs data frame rather than being drawn here, so each
# job is reproducible on its own terms. jobR gives a daemon the same random
# number generator as the worker, so the answer does not depend on how many
# cores happened to run it -- see ?versions.
estimate_pi <- function(n, seed) {
  set.seed(seed)
  inside <- sum(runif(n)^2 + runif(n)^2 <= 1)
  4 * inside / n
}
