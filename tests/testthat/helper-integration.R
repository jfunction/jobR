# Integration-test scaffolding.
#
# These tests run a real host and real workers as separate OS processes talking
# over real sockets. Nothing here is mocked: the only thing not exercised is the
# physical network between two machines, and that is the one part a CI runner
# genuinely cannot reproduce.
#
# Three things make process-level tests tractable rather than flaky:
#
#   1. Time is compressed, not waited on. Leases are seconds, not minutes, so a
#      "worker vanished" test finishes in about as long as it takes to notice.
#   2. Faults are injected deterministically. A worker is never killed on a
#      timer and hoped to be mid-chunk; the job itself signals through the
#      filesystem when it has reached the exact point we want to interrupt.
#   3. The ledger is the assertion surface. After any scenario, however the
#      processes interleaved, the ledger must satisfy the same invariants.

integration_enabled <- function() {
  !identical(Sys.getenv("JOBR_INTEGRATION"), "") ||
    !identical(Sys.getenv("NOT_CRAN"), "")
}

skip_unless_integration <- function() {
  testthat::skip_on_cran()
  testthat::skip_if_not(integration_enabled(),
                        "set JOBR_INTEGRATION=1 to run integration tests")
  testthat::skip_if_not_installed("callr")
}

# The checkout, if these tests are running from one. Walks up rather than
# assuming a fixed depth, and returns NULL when there is no source tree to
# find -- which is the case under `R CMD check`, where the tests run inside
# <pkg>.Rcheck and the only jobR that exists is the installed one.
#
# Getting this wrong is silent and total: every background process dies on its
# first line, no host ever binds its socket, and all thirteen integration
# tests fail with the same timeout, which reads like a broken package rather
# than a test helper looking in the wrong place.
pkg_root <- function() {
  d <- normalizePath(testthat::test_path("."), mustWork = FALSE)
  for (i in 1:5) {
    if (file.exists(file.path(d, "DESCRIPTION")) &&
        dir.exists(file.path(d, "R")) &&
        file.exists(file.path(d, "data", "passphraseWords.rda"))) {
      return(d)
    }
    up <- dirname(d)
    if (identical(up, d)) break
    d <- up
  }
  NULL
}

# Ports are drawn from a high range and bumped per use. Two concurrent test
# runs on one machine would otherwise collide and produce confusing failures.
.port <- local({
  p <- 29000L + sample(500L, 1L)
  function() {
    p <<- p + 1L
    p
  }
})

test_url <- function() sprintf("tcp://127.0.0.1:%d", .port())

# Run a function in a fresh R process with jobR available in the global
# environment. Sources the checkout when there is one, so tests run against
# working-tree code without installing; falls back to the installed package
# under `R CMD check`, where there is no checkout to source and the package
# being checked is the point anyway.
bg <- function(f, args = list()) {
  callr::r_bg(
    func = function(root, f, args) {
      if (is.null(root)) {
        library(jobR)
      } else {
        load(file.path(root, "data", "passphraseWords.rda"), envir = globalenv())
        for (fl in list.files(file.path(root, "R"), full.names = TRUE)) {
          source(fl, local = FALSE)
        }
      }
      do.call(f, args, envir = globalenv())
    },
    args = list(root = pkg_root(), f = f, args = args),
    supervise = TRUE
  )
}

# Poll for a condition instead of sleeping a fixed amount. Keeps tests fast when
# things go well and gives a clear failure when they do not.
wait_until <- function(cond, timeout = 30, interval = 0.1, what = "condition") {
  deadline <- Sys.time() + timeout
  while (Sys.time() < deadline) {
    if (isTRUE(try(cond(), silent = TRUE))) return(invisible(TRUE))
    Sys.sleep(interval)
  }
  stop("timed out waiting for ", what, call. = FALSE)
}

kill_quietly <- function(p) try(if (p$is_alive()) p$kill(), silent = TRUE)

# A project whose run_job can be told to stall at a chosen job, exactly once.
# The stall is the fault-injection point: the test waits for the sentinel to
# appear, which proves the worker is inside that job, and only then kills it.
write_demo_project <- function(dir, stall_at = NA, sentinel = NULL) {
  dir.create(file.path(dir, "R"), recursive = TRUE, showWarnings = FALSE)
  body <- c(
    "run_job <- function(row) {",
    if (!is.na(stall_at)) c(
      sprintf("  sentinel <- %s", deparse(sentinel)),
      sprintf("  if (row$x == %d && !file.exists(sentinel)) {", stall_at),
      "    dir.create(dirname(sentinel), recursive = TRUE, showWarnings = FALSE)",
      "    file.create(sentinel)",
      "    Sys.sleep(120)",
      "  }"
    ),
    "  data.frame(x = row$x, y = row$x * 2)",
    "}"
  )
  writeLines(body, file.path(dir, "R", "run.R"))
  writeLines(c("Project: demo", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(dir, "jobR.dcf"))
  dir
}

# The oracle: whatever the distributed system produces must equal what a plain
# serial loop produces. Independent of chunking, ordering and retries.
serial_expectation <- function(n) data.frame(x = seq_len(n), y = seq_len(n) * 2)

collected <- function(work_dir, jobset) {
  files <- sort(list.files(file.path(work_dir, "results", jobset),
                           pattern = "\\.rds$", full.names = TRUE))
  if (!length(files)) return(NULL)
  rows <- do.call(rbind, lapply(files, function(f) do.call(rbind, readRDS(f))))
  rows <- rows[order(rows$x), , drop = FALSE]
  # A project may return whatever columns it likes; the oracle only compares
  # the two it put in.
  rows[, intersect(c("x", "y"), names(rows)), drop = FALSE]
}

# Invariants that must hold after any run, no matter how it was perturbed.
expect_ledger_sane <- function(work_dir, jobset, n_chunks) {
  led <- ledger_open(file.path(work_dir, "ledger.tsv"))
  st <- chunk_state(led, jobset, n_chunks, now = unix_time() + 1e6)
  testthat::expect_equal(nrow(st), n_chunks)
  testthat::expect_true(all(st$state %in% c("done", "open")))
  ev <- led$events[led$events$jobset == jobset, ]
  testthat::expect_true(all(ev$chunk >= 1 & ev$chunk <= n_chunks))
  testthat::expect_true(all(ev$type %in% LEDGER_TYPES))
  invisible(st)
}

# Locate a bundled example project. Under R CMD check the tests run against an
# installed package, where inst/ has become the package root; in a checkout it
# is still inst/examples. Without this the example tests silently skip in the
# one place it matters most -- the check that has to pass before release.
example_dir <- function(name) {
  installed <- system.file("examples", name, package = "jobR")
  if (nzchar(installed) && dir.exists(installed)) return(installed)
  testthat::test_path("..", "..", "inst", "examples", name)
}
