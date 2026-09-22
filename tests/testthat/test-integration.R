# End-to-end tests over real sockets and real processes. See
# helper-integration.R for the scaffolding and the reasoning behind it.

start_host <- function(work_dir, project_dir, n_jobs, chunksize,
                       url, phrase, lease = 300, max_seconds = 90,
                       ready_file = tempfile("ready-")) {
  p <- bg(function(project_dir, n_jobs, chunksize, url, phrase, work_dir, lease, max_seconds, ready_file) {
    h <- host_new(project_dir, jobs = data.frame(x = seq_len(n_jobs)),
                  chunksize = chunksize, passphrase = phrase,
                  work_dir = work_dir, lease_seconds = lease, jobset = "test")
    jobr_serve(h, url, max_seconds = max_seconds, ready_file = ready_file,
               quiet = TRUE)
    "host-finished"
  }, list(project_dir = project_dir, n_jobs = n_jobs, chunksize = chunksize,
          url = url, phrase = phrase, work_dir = work_dir,
          lease = lease, max_seconds = max_seconds, ready_file = ready_file))
  attr(p, "ready_file") <- ready_file
  p
}

# Wait for the host to be genuinely bound, not merely dialable.
await_host <- function(p) {
  wait_until(function() file.exists(attr(p, "ready_file")), timeout = 30,
             what = "host to bind its socket")
  p
}

start_worker <- function(url, phrase, cache = tempfile("cache-"), max_seconds = 60) {
  bg(function(url, phrase, cache, max_seconds) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              max_seconds = max_seconds)
  }, list(url = url, phrase = phrase, cache = cache, max_seconds = max_seconds))
}

# ---- the happy path ---------------------------------------------------------

test_that("one host and one worker compute the right answer", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url <- test_url(); phrase <- "alpha-bravo-charlie-delta"

  h <- start_host(work, proj, n_jobs = 20, chunksize = 5, url = url, phrase = phrase)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  w <- start_worker(url, phrase)
  on.exit(kill_quietly(w), add = TRUE)
  wait_until(function() !w$is_alive(), timeout = 60, what = "worker to finish")

  expect_equal(collected(work, "test"), serial_expectation(20),
               ignore_attr = TRUE)
  expect_ledger_sane(work, "test", n_chunks = 4)
})

test_that("several workers share one jobset without duplicating or losing work", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url <- test_url(); phrase <- "echo-foxtrot-golf-hotel"

  h <- start_host(work, proj, n_jobs = 60, chunksize = 5, url = url, phrase = phrase)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  ws <- lapply(1:3, function(i) start_worker(url, phrase))
  on.exit(lapply(ws, kill_quietly), add = TRUE)
  wait_until(function() all(!vapply(ws, function(w) w$is_alive(), logical(1))),
             timeout = 90, what = "workers to finish")

  # The oracle: identical to a serial run, every job present exactly once.
  expect_equal(collected(work, "test"), serial_expectation(60), ignore_attr = TRUE)
  st <- expect_ledger_sane(work, "test", n_chunks = 12)
  expect_true(all(st$state == "done"))
})

# ---- a worker vanishing mid-chunk ------------------------------------------
# The scenario this package exists for: somebody's laptop lid closes, or the
# power goes out, while they are halfway through a chunk.

test_that("work is recovered when a worker dies holding a lease", {
  skip_unless_integration()
  work <- tempfile("host-")
  sentinel <- file.path(tempfile("sent-"), "reached")
  proj <- write_demo_project(tempfile("proj-"), stall_at = 7, sentinel = sentinel)
  url <- test_url(); phrase <- "india-juliet-kilo-lima"

  # A short lease so the reissue happens in test time rather than in minutes.
  h <- start_host(work, proj, n_jobs = 20, chunksize = 5, url = url,
                  phrase = phrase, lease = 5, max_seconds = 120)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  victim <- start_worker(url, phrase, max_seconds = 120)
  on.exit(kill_quietly(victim), add = TRUE)

  # Deterministic: the sentinel proves the worker is inside job 7 right now.
  wait_until(function() file.exists(sentinel), timeout = 60,
             what = "worker to reach the stall point")
  victim$kill()

  # A replacement joins. The stalled job no longer stalls (the sentinel is
  # already there), so it should complete the reissued chunk normally.
  rescuer <- start_worker(url, phrase, max_seconds = 120)
  on.exit(kill_quietly(rescuer), add = TRUE)
  wait_until(function() !rescuer$is_alive(), timeout = 120,
             what = "replacement worker to finish")

  expect_equal(collected(work, "test"), serial_expectation(20), ignore_attr = TRUE)
  st <- expect_ledger_sane(work, "test", n_chunks = 4)
  expect_true(all(st$state == "done"))
})

# ---- authentication over the wire ------------------------------------------

test_that("a worker with the wrong passphrase is refused", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url <- test_url()

  h <- start_host(work, proj, n_jobs = 5, chunksize = 5, url = url,
                  phrase = "mike-november-oscar-papa", max_seconds = 25)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  w <- start_worker(url, "quebec-romeo-sierra-tango", max_seconds = 20)
  on.exit(kill_quietly(w), add = TRUE)
  wait_until(function() !w$is_alive(), timeout = 40, what = "worker to exit")

  expect_match(paste(w$read_all_error_lines(), collapse = " "), "could not join")
  expect_null(collected(work, "test"))
})

# ---- bundle caching ---------------------------------------------------------

test_that("a returning worker re-fetches nothing when the project is unchanged", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url <- test_url(); phrase <- "uniform-victor-whiskey-xray"
  cache <- tempfile("cache-")

  # Each worker takes a bounded number of chunks, leaving the jobset unfinished
  # so the host is still listening when the second worker arrives. Bounding by
  # chunks rather than by time keeps this deterministic: these jobs are trivial,
  # and a time-bounded worker would race through all of them.
  h <- start_host(work, proj, n_jobs = 400, chunksize = 5, url = url,
                  phrase = phrase, max_seconds = 90)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  w1 <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = FALSE, max_chunks = 2)
  }, list(url = url, phrase = phrase, cache = cache))
  on.exit(kill_quietly(w1), add = TRUE)
  wait_until(function() !w1$is_alive(), timeout = 60, what = "first worker")
  expect_match(paste(w1$read_all_error_lines(), collapse = " "), "fetching project bundle")

  # Second run against the same cache: the hash matches, so nothing transfers.
  w2 <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = FALSE, max_chunks = 2)
  }, list(url = url, phrase = phrase, cache = cache))
  on.exit(kill_quietly(w2), add = TRUE)
  wait_until(function() !w2$is_alive(), timeout = 40, what = "second worker")
  out2 <- paste(w2$read_all_error_lines(), collapse = " ")
  expect_match(out2, "already current")
  expect_no_match(out2, "fetching project bundle")
})

# ---- the host restarting ----------------------------------------------------

test_that("a jobset resumes after the host process is killed", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url1 <- test_url(); url2 <- test_url(); phrase <- "yankee-zulu-alpha-bravo"

  h1 <- start_host(work, proj, n_jobs = 40, chunksize = 5, url = url1,
                   phrase = phrase, max_seconds = 120)
  on.exit(kill_quietly(h1), add = TRUE)
  await_host(h1)

  # Bounded by chunks rather than by time. These jobs are trivial, so a worker
  # left to run freely finishes all eight before the test can interrupt
  # anything, and there is no partial state left to resume from.
  w1 <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE, max_chunks = 3)
  }, list(url = url1, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(w1), add = TRUE)
  wait_until(function() !w1$is_alive(), timeout = 60, what = "first worker")

  kill_quietly(h1)
  partial <- length(list.files(file.path(work, "results", "test")))
  expect_equal(partial, 3)

  # Same working directory, new process: the ledger carries the progress over.
  h2 <- start_host(work, proj, n_jobs = 40, chunksize = 5, url = url2,
                   phrase = phrase, max_seconds = 120)
  on.exit(kill_quietly(h2), add = TRUE)
  await_host(h2)

  w2 <- start_worker(url2, phrase, max_seconds = 120)
  on.exit(kill_quietly(w2), add = TRUE)
  wait_until(function() !w2$is_alive(), timeout = 120, what = "worker to finish")

  expect_equal(collected(work, "test"), serial_expectation(40), ignore_attr = TRUE)
  expect_true(all(expect_ledger_sane(work, "test", 8)$state == "done"))
})

# ---- a worker whose environment is broken -----------------------------------
# Found on a real two-machine run: the client lacked mirai, so every chunk
# failed identically, was handed back, claimed again, and failed again. The
# same error streamed forever and the jobset could never finish.

test_that("a worker failing every chunk gives up instead of spinning", {
  skip_unless_integration()
  work <- tempfile("host-")
  # An entrypoint that always throws, standing in for any systematically
  # broken environment: a missing package, an unreadable path, a bad library.
  proj <- tempfile("proj-"); dir.create(file.path(proj, "R"), recursive = TRUE)
  writeLines(c("run_job <- function(row) stop('this machine is misconfigured')"),
             file.path(proj, "R", "run.R"))
  writeLines(c("Project: broken", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(proj, "jobR.dcf"))
  url <- test_url(); phrase <- "alpha-alpha-alpha-alpha"

  h <- start_host(work, proj, n_jobs = 100, chunksize = 5, url = url,
                  phrase = phrase, max_seconds = 60)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  w <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = FALSE,
              max_failures = 3L, max_seconds = 45)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(w), add = TRUE)

  # The point is that it STOPS. Before max_failures existed this ran until the
  # timeout, emitting the same error over and over.
  wait_until(function() !w$is_alive(), timeout = 60, what = "worker to give up")
  err <- paste(w$read_all_error_lines(), collapse = " ")
  expect_match(err, "giving up after 3 chunks failed in a row")
  expect_match(err, "misconfigured")

  # And it gave the work back rather than marking it done.
  expect_null(collected(work, "test"))
})

test_that("an occasional chunk failure does not stop a healthy worker", {
  skip_unless_integration()
  work <- tempfile("host-")
  # Fails only on job 3, and only the first time it is seen.
  sentinel <- file.path(tempfile("sent-"), "seen")
  proj <- tempfile("proj-"); dir.create(file.path(proj, "R"), recursive = TRUE)
  writeLines(c(
    sprintf("sentinel <- %s", deparse(sentinel)),
    "run_job <- function(row) {",
    "  if (row$x == 3 && !file.exists(sentinel)) {",
    "    dir.create(dirname(sentinel), recursive = TRUE, showWarnings = FALSE)",
    "    file.create(sentinel)",
    "    stop('transient')",
    "  }",
    "  data.frame(x = row$x, y = row$x * 2, stringsAsFactors = FALSE)",
    "}"), file.path(proj, "R", "run.R"))
  writeLines(c("Project: flaky", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(proj, "jobR.dcf"))
  url <- test_url(); phrase <- "bravo-bravo-bravo-bravo"

  h <- start_host(work, proj, n_jobs = 20, chunksize = 5, url = url,
                  phrase = phrase, lease = 5, max_seconds = 90)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  w <- start_worker(url, phrase, max_seconds = 90)
  on.exit(kill_quietly(w), add = TRUE)
  wait_until(function() !w$is_alive(), timeout = 90, what = "worker to finish")

  # One failure resets on the next success, so the run completes in full.
  expect_equal(collected(work, "test"), serial_expectation(20), ignore_attr = TRUE)
  expect_true(all(expect_ledger_sane(work, "test", 4)$state == "done"))
})

# ---- the heartbeat ----------------------------------------------------------
# A chunk that takes longer than its lease must not be taken away from the
# worker still computing it. Before renewal was wired up, the lease expired
# mid-computation and the chunk was silently handed to someone else and done
# twice. These tests make the chunk deliberately outlive the lease.

# How many times each chunk was handed out. One apiece means nothing was
# reissued; more means a lease lapsed while somebody was still working.
assigns_per_chunk <- function(work_dir, jobset, n_chunks) {
  led <- ledger_open(file.path(work_dir, "ledger.tsv"))
  ev <- led$events
  ev <- ev[ev$jobset == jobset & ev$type == "assign", , drop = FALSE]
  vapply(seq_len(n_chunks), function(k) sum(ev$chunk == k), integer(1))
}

# Jobs that each take a known wall-clock time, so a chunk can be made longer
# than the lease on purpose.
write_slow_project <- function(dir, seconds) {
  dir.create(file.path(dir, "R"), recursive = TRUE, showWarnings = FALSE)
  writeLines(c(
    "run_job <- function(row) {",
    sprintf("  Sys.sleep(%f)", seconds),
    "  data.frame(x = row$x, y = row$x * 2, stringsAsFactors = FALSE)",
    "}"), file.path(dir, "R", "run.R"))
  writeLines(c("Project: demo", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(dir, "jobR.dcf"))
  dir
}

test_that("a chunk outliving its lease is not stolen from a live worker", {
  skip_unless_integration()
  work <- tempfile("host-")
  # 10 jobs of 1s in one chunk = ~10s of work against a 4s lease.
  proj <- write_slow_project(tempfile("proj-"), seconds = 1)
  url <- test_url(); phrase <- "hotel-india-juliet-kilo"

  h <- start_host(work, proj, n_jobs = 10, chunksize = 10, url = url,
                  phrase = phrase, lease = 4, max_seconds = 120)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  a <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              renew_seconds = 1, max_seconds = 110)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(a), add = TRUE)

  # A SECOND worker is essential. With only one, a lapsed lease goes unnoticed
  # because nobody else is there to claim the chunk -- the test would pass
  # whether or not renewal worked. This one is waiting to pounce.
  wait_until(function() nchar(paste(readLines(file.path(work, "ledger.tsv"),
                                              warn = FALSE), collapse = "")) > 60,
             timeout = 30, what = "first worker to claim the chunk")
  b <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              poll_seconds = 1, max_seconds = 110)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(b), add = TRUE)

  wait_until(function() !a$is_alive() && !b$is_alive(), timeout = 120,
             what = "both workers to finish")

  expect_equal(collected(work, "test"), serial_expectation(10), ignore_attr = TRUE)
  # The assertion that discriminates: handed out exactly once. Without renewal
  # the lease lapses at 4s, worker B claims it, and this becomes 2.
  expect_equal(assigns_per_chunk(work, "test", 1), 1L)
})

test_that("successive over-long chunks each stay with the worker running them", {
  skip_unless_integration()
  work <- tempfile("host-")
  proj <- write_slow_project(tempfile("proj-"), seconds = 0.8)
  url <- test_url(); phrase <- "lima-mike-november-oscar"

  # 3 chunks of 5 x 0.8s = ~4s each, against a 3s lease, with a rival waiting.
  h <- start_host(work, proj, n_jobs = 15, chunksize = 5, url = url,
                  phrase = phrase, lease = 3, max_seconds = 150)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  a <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              renew_seconds = 1, max_seconds = 140)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(a), add = TRUE)
  wait_until(function() nchar(paste(readLines(file.path(work, "ledger.tsv"),
                                              warn = FALSE), collapse = "")) > 60,
             timeout = 30, what = "first claim")

  b <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              renew_seconds = 1, poll_seconds = 1, max_seconds = 140)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(b), add = TRUE)

  wait_until(function() !a$is_alive() && !b$is_alive(), timeout = 150,
             what = "both workers to finish")

  expect_equal(collected(work, "test"), serial_expectation(15), ignore_attr = TRUE)
  # Two workers, three chunks, none reissued: each was renewed while it ran.
  expect_equal(assigns_per_chunk(work, "test", 3), c(1L, 1L, 1L))
})

test_that("a worker that dies still loses its lease despite having renewed", {
  skip_unless_integration()
  work <- tempfile("host-")
  sentinel <- file.path(tempfile("sent-"), "reached")
  # Stalls forever inside job 3, having already renewed a few times.
  proj <- write_demo_project(tempfile("proj-"), stall_at = 3, sentinel = sentinel)
  url <- test_url(); phrase <- "papa-quebec-romeo-sierra"

  h <- start_host(work, proj, n_jobs = 10, chunksize = 5, url = url,
                  phrase = phrase, lease = 5, max_seconds = 120)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  victim <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              renew_seconds = 1, max_seconds = 110)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(victim), add = TRUE)
  wait_until(function() file.exists(sentinel), timeout = 60,
             what = "worker to reach the stall point")
  victim$kill()

  # Renewal stops when the process dies, so the lease must still lapse.
  rescuer <- start_worker(url, phrase, max_seconds = 110)
  on.exit(kill_quietly(rescuer), add = TRUE)
  wait_until(function() !rescuer$is_alive(), timeout = 120, what = "replacement")

  expect_equal(collected(work, "test"), serial_expectation(10), ignore_attr = TRUE)
  expect_true(all(expect_ledger_sane(work, "test", 2)$state == "done"))
})

# ---- the host-served package repository -------------------------------------
# The point of the feature: the host downloads a package once, and workers get
# it over the LAN instead of each visiting CRAN. Proven by giving the worker a
# private, empty library so it genuinely does not have the package.

test_that("a worker installs a missing package from the host, not CRAN", {
  skip_unless_integration()
  reachable <- tryCatch(
    nrow(utils::available.packages(repos = "https://cloud.r-project.org",
                                   type = "source")) > 0,
    error = function(e) FALSE, warning = function(w) FALSE)
  skip_if_not(isTRUE(reachable), "no CRAN access to stock the host")

  # Choose a package this machine does NOT already have. Hard-coding one makes
  # the test worthless on any machine that happens to have it: the worker never
  # needs the host, and the test passes for the wrong reason. All candidates are
  # tiny and dependency-free, ordered obscure-first so that a well-stocked
  # development machine still finds one free. A fresh CI runner takes the
  # first.
  candidates <- c("fortunes", "zeallot", "whisker", "praise", "brew", "bitops",
                  "ini", "prettyunits", "rprojroot", "crayon", "R6")
  have <- rownames(utils::installed.packages())
  pkg <- setdiff(candidates, have)[1]
  skip_if(is.na(pkg), "every candidate package is already installed here")

  work <- tempfile("host-")
  proj <- tempfile("proj-"); dir.create(file.path(proj, "R"), recursive = TRUE)
  # requireNamespace rather than a specific call, so any candidate works.
  writeLines(c(
    sprintf("PKG <- %s", deparse(pkg)),
    "run_job <- function(row) {",
    "  data.frame(x = row$x, y = row$x * 2,",
    "             dep = requireNamespace(PKG, quietly = TRUE),",
    "             stringsAsFactors = FALSE)",
    "}"), file.path(proj, "R", "run.R"))
  writeLines(c("Project: needsdep", "Entrypoint: R/run.R", "Files: R/run.R",
               "Lockfile: renv.lock"), file.path(proj, "jobR.dcf"))
  writeLines(sprintf('{ "Packages": { "%s": { "Package": "%s" } } }', pkg, pkg),
             file.path(proj, "renv.lock"))

  url <- test_url(); phrase <- "sierra-tango-uniform-victor"
  ready <- tempfile("ready-")

  # The host stocks the repository before serving, as a user would.
  h <- bg(function(proj, work, url, phrase, ready) {
    hst <- host_new(proj, jobs = data.frame(x = 1:6), chunksize = 3,
                    passphrase = phrase, work_dir = work, jobset = "test")
    host_serve_packages(hst, types = "source", quiet = TRUE)
    jobr_serve(hst, url, max_seconds = 240, ready_file = ready, quiet = TRUE)
  }, list(proj = proj, work = work, url = url, phrase = phrase, ready = ready))
  on.exit(kill_quietly(h), add = TRUE)
  wait_until(function() file.exists(ready), timeout = 180,
             what = "host to stock its repository and bind")
  expect_gt(nrow(repo_manifest(repo_path(work))), 0)

  # The worker installs into a private library, so a success there proves the
  # package arrived over the socket rather than already being present.
  wlib <- tempfile("wlib-"); dir.create(wlib, recursive = TRUE)
  w <- bg(function(url, phrase, cache, wlib, pkg) {
    .libPaths(c(wlib, .libPaths()))
    jobr_join(url, phrase, cache_dir = cache, quiet = FALSE, max_seconds = 200)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-"),
          wlib = wlib, pkg = pkg))
  on.exit(kill_quietly(w), add = TRUE)
  wait_until(function() !w$is_alive(), timeout = 240, what = "worker to finish")

  out <- paste(w$read_all_error_lines(), collapse = " ")
  expect_match(out, "fetching from the host")
  expect_true(pkg %in% rownames(utils::installed.packages(lib.loc = wlib)))
  expect_equal(collected(work, "test"), serial_expectation(6), ignore_attr = TRUE)
})

# ---- a link that is not there yet, or not there any more ---------------------
# Treating the first unanswered request as proof the host has gone costs the
# machine: on the intermittent links this package is built for, it is the
# difference between donating a laptop and babysitting a session.
#
# The mid-run case -- a link that dies while the worker is holding a chunk --
# needs real network impairment and lives in docker/docker-compose.partition.yml,
# because nothing a single process can do to itself is a faithful partition.
# What can be tested here is the same retry path from the other end: a host
# that is not listening yet.

test_that("a worker waits for a host that is not up yet", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url <- test_url(); phrase <- "india-juliet-kilo-lima"

  # Deliberately backwards: the worker starts first, against an address where
  # nothing is listening. Every request it makes goes unanswered.
  w <- start_worker(url, phrase, max_seconds = 120)
  on.exit(kill_quietly(w), add = TRUE)

  # Long enough that the old code -- which gave up on the first silence -- is
  # certainly dead by now, and the new code is certainly inside its retry loop.
  Sys.sleep(8)
  expect_true(w$is_alive())

  h <- start_host(work, proj, n_jobs = 20, chunksize = 5, url = url,
                  phrase = phrase, max_seconds = 120)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  wait_until(function() !w$is_alive(), timeout = 120, what = "worker to finish")
  expect_equal(collected(work, "test"), serial_expectation(20), ignore_attr = TRUE)
  expect_ledger_sane(work, "test", n_chunks = 4)
})

test_that("a worker told not to retry still fails fast", {
  skip_unless_integration()
  url <- test_url()

  # The retry budget must be a choice, not a new floor. Someone scripting
  # against a host they know is up wants the old behaviour, and a test suite
  # that cannot turn it off would take a minute per unreachable host.
  w <- bg(function(url) {
    tryCatch({
      jobr_join(url, "mike-november-oscar-papa", cache_dir = tempfile("cache-"),
                reconnect_seconds = 0, quiet = TRUE)
      "joined"
    }, error = function(e) "gave-up")
  }, list(url = url))
  on.exit(kill_quietly(w), add = TRUE)

  wait_until(function() !w$is_alive(), timeout = 45, what = "worker to give up")
  expect_equal(w$get_result(), "gave-up")
})

# ---- the host waiting for its workers ---------------------------------------

test_that("the host does not vanish the moment the last chunk lands", {
  skip_unless_integration()
  work <- tempfile("host-"); proj <- write_demo_project(tempfile("proj-"))
  url <- test_url(); phrase <- "romeo-sierra-tango-uniform"

  h <- start_host(work, proj, n_jobs = 20, chunksize = 5, url = url,
                  phrase = phrase, max_seconds = 120)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  w <- start_worker(url, phrase, max_seconds = 120)
  on.exit(kill_quietly(w), add = TRUE)
  wait_until(function() !w$is_alive(), timeout = 60, what = "worker to finish")

  # The worker reached the end without ever being left to guess: it was told
  # the jobset was done, said goodbye, and the host then stopped of its own
  # accord rather than being waited out. If the host were still sitting in its
  # linger, this would time out.
  wait_until(function() !h$is_alive(), timeout = 30, what = "host to shut down")
  expect_equal(h$get_result(), "host-finished")
})


# ---- one job longer than the lease ------------------------------------------
# The case the between-jobs heartbeat could never cover, and the one that
# matters most: a sensitivity analysis whose single run takes minutes. The
# existing lease tests all use many short jobs, so they were satisfied by
# beating between them and would pass even with this broken.

test_that("a single job longer than the lease keeps its chunk", {
  skip_unless_integration()
  skip_if_not_installed("mirai")
  work <- tempfile("host-")
  # One job of 12s against a 4s lease. Nothing happens between jobs, because
  # there is no between.
  proj <- write_slow_project(tempfile("proj-"), seconds = 12)
  url <- test_url(); phrase <- "tango-uniform-victor-whiskey"

  h <- start_host(work, proj, n_jobs = 1, chunksize = 1, url = url,
                  phrase = phrase, lease = 4, max_seconds = 150)
  on.exit(kill_quietly(h), add = TRUE)
  await_host(h)

  a <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              renew_seconds = 1, max_seconds = 140)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(a), add = TRUE)

  # A rival, as ever. With only one worker a lapsed lease goes unnoticed and
  # the test would pass whether or not anything was renewed.
  wait_until(function() nchar(paste(readLines(file.path(work, "ledger.tsv"),
                                              warn = FALSE), collapse = "")) > 60,
             timeout = 60, what = "the first worker to claim the chunk")
  b <- bg(function(url, phrase, cache) {
    jobr_join(url, phrase, cache_dir = cache, quiet = TRUE,
              poll_seconds = 1, max_seconds = 140)
  }, list(url = url, phrase = phrase, cache = tempfile("cache-")))
  on.exit(kill_quietly(b), add = TRUE)

  wait_until(function() !a$is_alive() && !b$is_alive(), timeout = 150,
             what = "both workers to finish")

  expect_equal(collected(work, "test"), serial_expectation(1), ignore_attr = TRUE)
  # The assertion that discriminates. Renewing only between jobs leaves this
  # chunk unrenewed for its whole 12 seconds, the lease lapses at 4, worker B
  # takes it, and this becomes 2.
  expect_equal(assigns_per_chunk(work, "test", 1), 1L)
})
