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
