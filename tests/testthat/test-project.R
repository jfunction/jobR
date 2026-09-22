# ---- scaffolding ------------------------------------------------------------

test_that("a scaffolded project is immediately valid", {
  p <- file.path(tempfile("scaffold-"), "mysim")
  expect_message(jobr_new_project(p), "created project")
  expect_true(jobr_check_project(p, quiet = TRUE)$ok)
})

test_that("a scaffolded project's stub entrypoint actually runs", {
  p <- file.path(tempfile("scaffold-"), "mysim")
  jobr_new_project(p)
  runner <- load_entrypoint(p, manifest_read(p)$entrypoint)
  expect_equal(runner(data.frame(id = 1, x = 21))$result, 42)
})

test_that("the scaffolded manifest explains itself", {
  p <- file.path(tempfile("scaffold-"), "mysim")
  jobr_new_project(p)
  txt <- readLines(file.path(p, "jobR.dcf"))
  expect_true(any(grepl("^#", txt)))          # commented, not bare fields
  expect_true(any(grepl("\\?jobR.dcf", txt))) # points at the reference
})

test_that("a scaffolded project bundles and unpacks", {
  p <- file.path(tempfile("scaffold-"), "mysim")
  jobr_new_project(p)
  b <- bundle_create(p)
  out <- bundle_unpack(b$path, tempfile("u-"), expect_hash = b$hash)
  expect_equal(manifest_read(out)$project, "mysim")
})

test_that("the project name is validated and the directory guarded", {
  expect_error(jobr_new_project(tempfile(), name = "../escape"), "alphanumeric")
  expect_error(jobr_new_project(tempfile(), name = "has space"), "alphanumeric")

  occupied <- tempfile("occupied-")
  dir.create(occupied); writeLines("x", file.path(occupied, "something"))
  expect_error(jobr_new_project(occupied), "not empty")
})

# ---- validation -------------------------------------------------------------

test_that("a missing manifest is reported rather than thrown", {
  res <- jobr_check_project(tempfile(), quiet = TRUE)
  expect_false(res$ok)
  expect_match(res$problems, "no jobR.dcf", all = FALSE)
})

test_that("files listed but absent are reported", {
  p <- file.path(tempfile("proj-"), "x"); jobr_new_project(p)
  writeLines(c("Project: x", "Entrypoint: R/run.R", "Files: R/run.R, R/ghost.R"),
             file.path(p, "jobR.dcf"))
  res <- jobr_check_project(p, quiet = TRUE)
  expect_false(res$ok)
  expect_match(res$problems, "do not exist", all = FALSE)
})

test_that("an entrypoint that forgets run_job is reported", {
  p <- file.path(tempfile("proj-"), "x"); jobr_new_project(p)
  writeLines("helper <- function(x) x", file.path(p, "R", "run.R"))
  res <- jobr_check_project(p, quiet = TRUE)
  expect_false(res$ok)
  expect_match(res$problems, "run_job", all = FALSE)
})

test_that("a declared lockfile that is absent is reported", {
  p <- file.path(tempfile("proj-"), "x"); jobr_new_project(p)
  writeLines(c("Project: x", "Entrypoint: R/run.R", "Files: R/run.R",
               "Lockfile: renv.lock"), file.path(p, "jobR.dcf"))
  res <- jobr_check_project(p, quiet = TRUE)
  expect_false(res$ok)
  expect_match(res$problems, "Lockfile", all = FALSE)
})

# ---- the shipped examples ---------------------------------------------------

test_that("both bundled examples are valid projects", {
  for (ex in c("montecarlo", "benchmark")) {
    dir <- example_dir(ex)
    skip_if_not(dir.exists(dir))
    expect_true(jobr_check_project(dir, quiet = TRUE)$ok, info = ex)
  }
})

test_that("the benchmark entrypoint reports host and elapsed time", {
  dir <- example_dir("benchmark")
  skip_if_not(dir.exists(dir))
  runner <- load_entrypoint(dir, "R/run.R")
  out <- runner(data.frame(id = 7, seconds = 0.05))
  expect_equal(out$id, 7)
  expect_true(nzchar(out$host))
  expect_gte(out$elapsed, 0.04)
})

# ---- benchmark helpers ------------------------------------------------------

test_that("jobr_burn consumes roughly the time asked of it", {
  t <- system.time(jobr_burn(0.2))[["elapsed"]]
  expect_gte(t, 0.15)
  expect_lt(t, 2)            # generous: CI machines stall unpredictably
})

test_that("benchmark jobs have the columns the entrypoint expects", {
  j <- jobr_benchmark_jobs(50, seconds = 0.5)
  expect_equal(nrow(j), 50L)
  expect_setequal(names(j), c("id", "seconds"))
  expect_true(all(j$seconds == 0.5))
})

test_that("the estimate is arithmetically right", {
  e <- suppressMessages(jobr_estimate(240, seconds = 1, cores = c(a = 4, b = 8)))
  expect_equal(unname(e[["cpu_seconds"]]), 240)
  expect_equal(unname(e[["ideal_seconds"]]), 20)
})

test_that("the report attributes work to the right machines", {
  mk <- function(host, ids) {
    lapply(ids, function(i) data.frame(id = i, host = host, pid = 1,
                                       elapsed = 1, finished = Sys.time()))
  }
  results <- list(do.call(rbind, mk("alpha", 1:3)),
                  do.call(rbind, mk("beta", 4:5)))
  rep <- jobr_benchmark_report(lapply(results, function(d) split(d, seq_len(nrow(d)))))
  expect_equal(rep$host, c("alpha", "beta"))
  expect_equal(rep$jobs, c(3L, 2L))
  expect_equal(sum(rep$share), 1)
})

test_that("an empty report does not error", {
  expect_equal(nrow(jobr_benchmark_report(list())), 0L)
})

# ---- preflight --------------------------------------------------------------

test_that("LAN address discovery returns plausible addresses or nothing", {
  addrs <- jobr_lan_address()
  expect_type(addrs, "character")
  for (a in addrs) {
    expect_match(a, "^(\\d{1,3}\\.){3}\\d{1,3}$")
    expect_false(startsWith(a, "127."))
    expect_false(startsWith(a, "169.254."))
  }
})

test_that("the doctor detects a free port and an occupied one", {
  port <- 28100 + sample(300, 1)
  free <- jobr_doctor(port, quiet = TRUE)
  expect_true(free$port_free)

  sock <- nanonext::socket("rep", listen = sprintf("tcp://0.0.0.0:%d", port))
  on.exit(close(sock), add = TRUE)
  taken <- jobr_doctor(port, quiet = TRUE)
  expect_false(taken$port_free)
  expect_match(taken$problems, "could not be bound", all = FALSE)
})

test_that("ping reports unreachable hosts without throwing", {
  res <- jobr_ping("tcp://127.0.0.1:28999", timeout_ms = 400, quiet = TRUE)
  expect_false(res$reachable)
  expect_false(res$authenticated)
})

# ---- running across different R versions ------------------------------------
# A fleet of machines people already own is a fleet of mismatched R versions.
# jobR's floor is R 3.6 (nanonext's floor), not an arbitrary 4.0.

test_that("the R version string is well formed", {
  expect_match(r_version_string(), "^[0-9]+[.][0-9]+")
})

test_that("matching versions produce no noise", {
  expect_length(version_skew_warnings("4.5.3", worker_version = "4.5.3"), 0L)
})

test_that("an absent host version is tolerated", {
  expect_length(version_skew_warnings(NULL), 0L)
  expect_length(version_skew_warnings(""), 0L)
})

test_that("a minor version difference is reported but not alarming", {
  w <- version_skew_warnings("4.5.3", worker_version = "4.4.1")
  expect_length(w, 1L)
  expect_match(w, "this worker runs R 4.4.1")
  expect_false(any(grepl("stringsAsFactors", w)))
})

test_that("straddling R 4.0 warns about stringsAsFactors in both directions", {
  old_worker <- version_skew_warnings("4.5.3", worker_version = "3.6.3")
  expect_match(old_worker, "stringsAsFactors", all = FALSE)

  old_host <- version_skew_warnings("3.6.3", worker_version = "4.5.3")
  expect_match(old_host, "stringsAsFactors", all = FALSE)
})

test_that("two old versions do not warn about factors", {
  w <- version_skew_warnings("3.6.1", worker_version = "3.6.3")
  expect_match(w, "this worker runs", all = FALSE)
  expect_false(any(grepl("stringsAsFactors", w)))
})

# ---- the shipped projects must model good practice --------------------------
# These examples are what people copy, so a factor leaking out of one of them
# would propagate into every project derived from it.

test_that("every shipped example sets stringsAsFactors explicitly", {
  for (ex in c("montecarlo", "benchmark")) {
    f <- file.path(example_dir(ex), "R", "run.R")
    skip_if_not(file.exists(f))
    expect_match(paste(readLines(f), collapse = " "), "stringsAsFactors = FALSE",
                 info = ex)
  }
})

test_that("the scaffolded stub sets stringsAsFactors explicitly", {
  p <- file.path(tempfile("scaffold-"), "mysim")
  jobr_new_project(p)
  expect_match(paste(readLines(file.path(p, "R", "run.R")), collapse = " "),
               "stringsAsFactors = FALSE")
})

test_that("example results carry character columns, not factors", {
  dir <- example_dir("benchmark")
  skip_if_not(dir.exists(dir))
  out <- load_entrypoint(dir, "R/run.R")(data.frame(id = 1, seconds = 0.02))
  expect_type(out$host, "character")
})

# ---- multi-core execution ---------------------------------------------------
# Found on a real run: every job came back as an errorValue, and because mirai
# RETURNS those rather than throwing, the worker submitted them as results. The
# host marked all 24 chunks complete and the jobset "finished" full of errors.

test_that("a multi-file project works across cores", {
  skip_if_not_installed("mirai")
  skip_on_cran()
  dir <- example_dir("benchmark")
  skip_if_not(dir.exists(dir))
  jobs <- data.frame(id = 1:4, seconds = 0.05)

  # The entrypoint calls burn(), defined in a sibling file. A closure shipped
  # to a daemon loses its enclosing environment, so this is exactly the case
  # that used to fail.
  out <- run_chunk(dir, "R/run.R", jobs, cores = 2)
  expect_length(out, 4L)
  expect_true(all(vapply(out, is.data.frame, logical(1))))
  expect_equal(sort(do.call(rbind, out)$id), 1:4)
})

test_that("a failing job raises an error instead of returning errorValues", {
  skip_if_not_installed("mirai")
  skip_on_cran()
  d <- tempfile("proj-"); dir.create(file.path(d, "R"), recursive = TRUE)
  writeLines("run_job <- function(row) stop('boom in job ', row$id)",
             file.path(d, "R", "run.R"))
  writeLines(c("Project: boom", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(d, "jobR.dcf"))
  jobs <- data.frame(id = 1:3)

  # Both paths must FAIL, not return error objects that look like results.
  expect_error(run_chunk(d, "R/run.R", jobs, cores = 1), "boom")
  expect_error(run_chunk(d, "R/run.R", jobs, cores = 2),
               "jobs in this chunk failed")
})

test_that("a chunk that errors on only some jobs still fails as a whole", {
  skip_if_not_installed("mirai")
  skip_on_cran()
  d <- tempfile("proj-"); dir.create(file.path(d, "R"), recursive = TRUE)
  writeLines(c("run_job <- function(row) {",
               "  if (row$id == 2) stop('only job two')",
               "  data.frame(id = row$id, stringsAsFactors = FALSE)",
               "}"), file.path(d, "R", "run.R"))
  writeLines(c("Project: partial", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(d, "jobR.dcf"))
  err <- tryCatch(run_chunk(d, "R/run.R", data.frame(id = 1:4), cores = 2),
                  error = function(e) conditionMessage(e))
  expect_match(err, "1 of 4 jobs in this chunk failed")
  expect_match(err, "only job two")
})

test_that("an empty chunk is not an error", {
  dir <- example_dir("benchmark")
  skip_if_not(dir.exists(dir))
  expect_equal(run_chunk(dir, "R/run.R", data.frame(id = integer()), cores = 1),
               list())
})

# ---- the report must not crash on bad input --------------------------------

test_that("a report over failed results explains itself", {
  errs <- list(list(structure(-1L, class = "errorValue"),
                    structure(-1L, class = "errorValue")))
  expect_error(jobr_benchmark_report(errs), "none of these results are data frames")
})

test_that("a report over results lacking the expected columns says which", {
  res <- list(list(data.frame(id = 1, value = 2)))
  expect_error(jobr_benchmark_report(res), "missing the column")
})

test_that("a report skips the odd bad result but still reports", {
  ok <- function(h) data.frame(id = 1, host = h, pid = 1, elapsed = 1,
                               finished = Sys.time(), stringsAsFactors = FALSE)
  res <- list(list(ok("alpha"), structure(-1L, class = "errorValue")))
  expect_warning(rep <- jobr_benchmark_report(res), "were skipped")
  expect_equal(rep$host, "alpha")
})


# ---- the heartbeat during a single long job ---------------------------------
# The heartbeat used to fire only between jobs, so a chunk of many short jobs
# kept its lease and a chunk containing one long job did not. That is backwards:
# the long job is the one that needs the lease held. A worker is single-
# threaded, so the only way out is for the job to run somewhere else -- which
# is why jobs go to a daemon even on one core.

slow_job_project <- function(dir, seconds) {
  dir.create(file.path(dir, "R"), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "run_job <- function(row) {",
    sprintf("  Sys.sleep(%f)", seconds),
    "  data.frame(x = row$x, y = row$x * 2, stringsAsFactors = FALSE)",
    "}"), file.path(dir, "R", "run.R"))
  writeLines(c("Project: slow", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(dir, "jobR.dcf"))
  dir
}

test_that("a single job longer than the interval is beaten through, not after", {
  skip_if_not_installed("mirai")
  skip_on_cran()
  d <- slow_job_project(tempfile("proj-"), seconds = 3)

  beats <- 0L
  out <- run_chunk(d, "R/run.R", data.frame(x = 1L), cores = 1,
                   heartbeat = function() beats <<- beats + 1L,
                   heartbeat_seconds = 0.5)

  expect_length(out, 1L)
  # One job, three seconds, a beat wanted every half second. Beating only
  # between jobs gives at most 1. The old code scored exactly that.
  expect_gt(beats, 3L)
})

test_that("in-process execution cannot beat during a job, and says so", {
  skip_on_cran()
  d <- slow_job_project(tempfile("proj-"), seconds = 2)

  # The fallback for a machine with no mirai, or one too short of memory to
  # want a second R process. It is the old behaviour, and this pins the cost of
  # it so that nobody mistakes the two paths for equivalent.
  withr::with_options(list(jobR.in_process = TRUE), {
    expect_false(use_daemons())
    beats <- 0L
    out <- run_chunk(d, "R/run.R", data.frame(x = 1L), cores = 1,
                     heartbeat = function() beats <<- beats + 1L,
                     heartbeat_seconds = 0.5)
    expect_length(out, 1L)
    expect_equal(beats, 1L)
  })
})

test_that("a chunk that outstays max_chunk_seconds stops being renewed", {
  skip_if_not_installed("mirai")
  skip_on_cran()
  d <- slow_job_project(tempfile("proj-"), seconds = 3)

  # Renewing while a job runs means a hung job is indistinguishable from a slow
  # one. This is the only thing that tells them apart, so it has to work.
  beats <- 0L
  expect_warning(
    run_chunk(d, "R/run.R", data.frame(x = 1L), cores = 1,
              heartbeat = function() beats <<- beats + 1L,
              heartbeat_seconds = 0.25, max_chunk_seconds = 1),
    "no longer renewing its lease")
  expect_lt(beats, 8L)
})

test_that("results are the same whether a job runs here or in a daemon", {
  skip_if_not_installed("mirai")
  skip_on_cran()
  dir <- example_dir("montecarlo")
  skip_if_not(dir.exists(dir))
  jobs <- data.frame(id = 1:4, n = 2000, seed = 1:4)

  # Compares against running the project by hand, which is what a user would
  # get and therefore the actual contract. Comparing run_chunk(cores = 1)
  # against run_chunk(cores = 2) no longer tests anything, now that both go
  # through a daemon -- and that comparison is what caught the RNG divergence
  # in the first place, so it needs a replacement rather than a deletion.
  runner <- load_entrypoint(dir, "R/run.R")
  by_hand <- do.call(rbind, lapply(seq_len(nrow(jobs)),
                                   function(i) runner(jobs[i, , drop = FALSE])))
  expect_equal(by_hand, do.call(rbind, run_chunk(dir, "R/run.R", jobs, cores = 1)))
  expect_equal(by_hand, do.call(rbind, run_chunk(dir, "R/run.R", jobs, cores = 2)))
})
