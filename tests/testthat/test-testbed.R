# The containerised testbed cannot run here -- Docker needs a virtualisation
# platform this machine does not have -- but the part that decides whether a
# distributed run was CORRECT is ordinary R and is tested like anything else.
# Only the container plumbing goes unverified locally.

testbed_assertions <- function() {
  f <- testthat::test_path("..", "..", "docker", "assertions.R")
  skip_if_not(file.exists(f), "docker/assertions.R not present")
  env <- new.env(parent = globalenv())
  sys.source(f, envir = env)
  env$testbed_problems
}

# One chunk's worth of results, as run_job returns them.
mk_rows <- function(ids, host) {
  lapply(ids, function(i) {
    data.frame(id = i, host = host, pid = 1L, elapsed = 0.1,
               finished = Sys.time(), stringsAsFactors = FALSE)
  })
}
all_done <- function(n) data.frame(chunk = seq_len(n),
                                   state = rep("done", n),
                                   stringsAsFactors = FALSE)

test_that("a correct run reports no problems", {
  tp <- testbed_assertions()
  results <- list(mk_rows(1:5, "node-a"), mk_rows(6:10, "node-b"))
  expect_length(tp(results, all_done(2), n_jobs = 10, expect_hosts = 2), 0L)
})

test_that("a missing job is caught", {
  tp <- testbed_assertions()
  results <- list(mk_rows(1:5, "node-a"), mk_rows(6:9, "node-b"))
  expect_match(tp(results, all_done(2), 10, 2), "not covered exactly once",
               all = FALSE)
})

test_that("a duplicated job is caught", {
  tp <- testbed_assertions()
  results <- list(mk_rows(1:5, "node-a"), mk_rows(c(5:9), "node-b"))
  expect_match(tp(results, all_done(2), 10, 2), "not covered exactly once",
               all = FALSE)
})

test_that("work landing on only one machine is caught", {
  # The failure a multi-node test exists to detect: every worker silently
  # failed to connect and the host did all of it.
  tp <- testbed_assertions()
  results <- list(mk_rows(1:10, "node-a"))
  expect_match(tp(results, all_done(1), 10, expect_hosts = 2),
               "expected at least 2", all = FALSE)
})

test_that("a single-host run is fine when only one host is expected", {
  tp <- testbed_assertions()
  results <- list(mk_rows(1:10, "node-a"))
  expect_length(tp(results, all_done(1), 10, expect_hosts = 1), 0L)
})

test_that("errorValue results are caught rather than read as success", {
  # The shape the multi-core corruption bug produced.
  tp <- testbed_assertions()
  results <- list(list(structure(-1L, class = "errorValue"),
                       structure(-1L, class = "errorValue")))
  p <- tp(results, all_done(1), 2, 1)
  expect_gt(length(p), 0L)
  expect_match(p, "data frame|no results", all = FALSE)
})

test_that("an empty run is caught", {
  tp <- testbed_assertions()
  expect_match(tp(list(), all_done(1), 10, 1), "no results", all = FALSE)
})

test_that("factor host columns are caught", {
  # What a worker on R 3.6 returns if the project forgets stringsAsFactors.
  tp <- testbed_assertions()
  rows <- lapply(1:4, function(i) {
    data.frame(id = i, host = "old-node", pid = 1L, elapsed = 0.1,
               finished = Sys.time(), stringsAsFactors = TRUE)
  })
  expect_match(tp(list(rows), all_done(1), 4, 1), "not character", all = FALSE)
})

test_that("unfinished chunks are caught", {
  tp <- testbed_assertions()
  st <- all_done(3); st$state[2] <- "open"
  results <- list(mk_rows(1:10, "node-a"), mk_rows(11:20, "node-b"))
  expect_match(tp(results, st, 20, 2), "chunks are not done", all = FALSE)
})

test_that("the ledger check can be skipped", {
  tp <- testbed_assertions()
  results <- list(mk_rows(1:5, "node-a"), mk_rows(6:10, "node-b"))
  expect_length(tp(results, NULL, 10, 2), 0L)
})
