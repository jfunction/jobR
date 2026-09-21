# One directory for the whole file, many ledgers inside it.
#
# NB: not withr::local_tempdir() -- that is scoped to this helper's own frame
# and would be cleaned up before the caller ever writes to it. And deliberately
# not a fresh directory per ledger: the property tests below ask for hundreds,
# and creating that many directories in a tight loop fails intermittently on
# Windows (a dir.create that appears to succeed, followed by a write that
# cannot open the file). Creating files in one directory avoids the churn.
tmp_ledger <- local({
  dir <- NULL
  n <- 0L
  function() {
    if (is.null(dir) || !dir.exists(dir)) {
      dir <<- tempfile("jobr-ledgers-")
      dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    }
    n <<- n + 1L
    ledger_open(file.path(dir, sprintf("ledger-%05d.tsv", n)))
  }
})

# ---- chunk_plan -------------------------------------------------------------
# The original implementation used floor(n_jobs / chunksize), silently dropping
# the remainder. With 1001 jobs and chunksize 25 the last job vanished.

test_that("chunk_plan tiles every job exactly once", {
  for (n in c(1, 24, 25, 26, 100, 1000, 1001)) {
    for (cs in c(1, 7, 25, 1000)) {
      p <- chunk_plan(n, cs)
      covered <- unlist(Map(seq, p$start, p$end))
      expect_equal(covered, seq_len(n), info = sprintf("n=%d cs=%d", n, cs))
    }
  }
})

test_that("chunk_plan keeps a short final chunk", {
  p <- chunk_plan(1001, 25)
  expect_equal(nrow(p), 41L)
  expect_equal(p$start[41], 1001L)
  expect_equal(p$end[41], 1001L)
})

test_that("chunk_plan handles the degenerate cases", {
  expect_equal(nrow(chunk_plan(0, 10)), 0L)
  expect_equal(nrow(chunk_plan(5, 10)), 1L)
  expect_equal(chunk_plan(5, 10)$end, 5L)
  expect_error(chunk_plan(-1, 10))
  expect_error(chunk_plan(10, 0))
})

# ---- claiming ---------------------------------------------------------------
# The original used `if (length(idJobsUnsent) > 1)`, so when exactly one unsent
# chunk remained it was skipped and the jobset could never finish cleanly.

test_that("every chunk is claimed once before any is repeated", {
  led <- tmp_ledger()
  seen <- integer()
  for (i in 1:5) {
    res <- claim_chunk(led, "js", n_chunks = 5, worker = paste0("w", i), now = 1000)
    led <- res$ledger
    seen <- c(seen, res$chunk)
  }
  expect_equal(sort(seen), 1:5)
})

test_that("the final remaining chunk is claimable", {
  led <- tmp_ledger()
  for (k in 1:4) led <- ledger_append(led, "complete", "js", k, "w", now = 1000)
  res <- claim_chunk(led, "js", n_chunks = 5, worker = "w", now = 1000)
  expect_equal(res$chunk, 5L)
})

test_that("no work is handed out when everything is done", {
  led <- tmp_ledger()
  for (k in 1:3) led <- ledger_append(led, "complete", "js", k, "w", now = 1000)
  res <- claim_chunk(led, "js", n_chunks = 3, worker = "w", now = 1000)
  expect_null(res$chunk)
})

test_that("a live lease is not reissued", {
  led <- tmp_ledger()
  res <- claim_chunk(led, "js", 2, "w1", lease_seconds = 100, now = 1000)
  led <- res$ledger
  st <- chunk_state(led, "js", 2, now = 1050)
  expect_equal(st$state[res$chunk], "leased")
})

# ---- leases and disconnection ----------------------------------------------

test_that("a lapsed lease makes work claimable again", {
  led <- tmp_ledger()
  res <- claim_chunk(led, "js", 1, "gone", lease_seconds = 100, now = 1000)
  led <- res$ledger
  expect_equal(chunk_state(led, "js", 1, now = 1050)$state, "leased")
  expect_equal(chunk_state(led, "js", 1, now = 1101)$state, "open")

  res2 <- claim_chunk(led, "js", 1, "fresh", now = 1200)
  expect_equal(res2$chunk, 1L)
})

test_that("renewing extends a lease", {
  led <- tmp_ledger()
  led <- claim_chunk(led, "js", 1, "w", lease_seconds = 100, now = 1000)$ledger
  led <- ledger_append(led, "renew", "js", 1, "w", lease = 1300, now = 1090)
  expect_equal(chunk_state(led, "js", 1, now = 1150)$state, "leased")
  expect_equal(chunk_state(led, "js", 1, now = 1301)$state, "open")
})

test_that("an explicit failure reopens work immediately", {
  led <- tmp_ledger()
  led <- claim_chunk(led, "js", 1, "w", lease_seconds = 9999, now = 1000)$ledger
  led <- ledger_append(led, "fail", "js", 1, "w", now = 1010)
  expect_equal(chunk_state(led, "js", 1, now = 1020)$state, "open")
})

# ---- at-least-once delivery -------------------------------------------------
# A worker can finish a chunk, have its result land, and only then be presumed
# dead -- or be presumed dead, be replaced, and then report in late. Completion
# must be terminal either way, or two workers can ping-pong a chunk forever.

test_that("completion is terminal against a late duplicate assignment", {
  led <- tmp_ledger()
  led <- ledger_append(led, "complete", "js", 1, "fast", now = 1000)
  led <- ledger_append(led, "assign", "js", 1, "slow", lease = 2000, now = 1010)
  expect_equal(chunk_state(led, "js", 1, now = 1020)$state, "done")
})

test_that("a duplicate completion is harmless", {
  led <- tmp_ledger()
  led <- ledger_append(led, "complete", "js", 1, "a", now = 1000)
  led <- ledger_append(led, "complete", "js", 1, "b", now = 1005)
  expect_true(jobset_complete(led, "js", 1, now = 1010))
})

test_that("a stale failure cannot reopen completed work", {
  led <- tmp_ledger()
  led <- ledger_append(led, "complete", "js", 1, "a", now = 1000)
  led <- ledger_append(led, "fail", "js", 1, "zombie", now = 1005)
  expect_true(jobset_complete(led, "js", 1, now = 1010))
})

# ---- durability -------------------------------------------------------------

test_that("a ledger survives being reopened", {
  path <- file.path(withr::local_tempdir(), "l.tsv")
  led <- ledger_open(path)
  led <- claim_chunk(led, "js", 3, "w", now = 1000)$ledger
  led <- ledger_append(led, "complete", "js", 1, "w", now = 1010)

  reopened <- ledger_open(path)
  expect_equal(nrow(reopened$events), nrow(led$events))
  expect_true(jobset_complete(reopened, "js", 1, now = 1020))
})

test_that("a torn final line is tolerated", {
  path <- file.path(withr::local_tempdir(), "l.tsv")
  led <- ledger_open(path)
  led <- ledger_append(led, "complete", "js", 1, "w", now = 1000)
  cat("2\t1001.000\tcomp", file = path, append = TRUE)  # power cut mid-append

  reopened <- ledger_open(path)
  expect_equal(nrow(reopened$events), 1L)
  expect_true(jobset_complete(reopened, "js", 1, now = 1010))
})

test_that("unknown event types are refused", {
  led <- tmp_ledger()
  expect_error(ledger_append(led, "sent", "js", 1, "w"), "unknown ledger event type")
})

# ---- invariants over random histories --------------------------------------
# Rather than enumerate interleavings by hand, generate them and assert the
# properties that must hold for any history whatsoever.

test_that("state is well formed for arbitrary event histories", {
  set.seed(42)
  for (trial in 1:200) {
    led <- tmp_ledger()
    n <- sample(1:6, 1)
    now <- 1000
    for (step in seq_len(sample(1:25, 1))) {
      now <- now + sample(1:50, 1)
      k <- sample(seq_len(n), 1)
      type <- sample(LEDGER_TYPES, 1)
      led <- ledger_append(led, type, "js", k, paste0("w", sample(3, 1)),
                           lease = now + sample(c(1, 100), 1), now = now)
    }
    st <- chunk_state(led, "js", n, now = now)

    expect_equal(nrow(st), n)
    expect_equal(st$chunk, seq_len(n))
    expect_true(all(st$state %in% c("done", "leased", "open")))

    # Once complete, always complete: advancing the clock can only ever move
    # chunks from leased to open, never out of done.
    later <- chunk_state(led, "js", n, now = now + 1e6)
    expect_true(all(later$state[st$state == "done"] == "done"))
    expect_true(all(later$state[st$state == "open"] == "open"))
  }
})

test_that("progress counts always partition the chunks", {
  set.seed(7)
  for (trial in 1:100) {
    led <- tmp_ledger()
    n <- sample(1:8, 1)
    now <- 1000
    for (step in seq_len(sample(1:15, 1))) {
      now <- now + 10
      led <- ledger_append(led, sample(LEDGER_TYPES, 1), "js",
                           sample(seq_len(n), 1), "w", lease = now + 50, now = now)
    }
    p <- ledger_progress(led, "js", n, now = now)
    expect_equal(sum(p), n)
  }
})

test_that("jobsets are isolated from one another", {
  led <- tmp_ledger()
  led <- ledger_append(led, "complete", "a", 1, "w", now = 1000)
  expect_true(jobset_complete(led, "a", 1, now = 1010))
  expect_false(jobset_complete(led, "b", 1, now = 1010))
})

# ---- transient write failures ----------------------------------------------
# Windows antivirus and search indexers briefly hold newly written files open,
# so an append to a file that plainly exists can return "Permission denied" and
# succeed moments later. Losing a ledger event to a scanner would be a silent
# correctness bug, so appends retry.

test_that("a writable ledger is appended to on the first attempt", {
  led <- tmp_ledger()
  expect_true(ledger_write_line(led$path, "x\n"))
  expect_true(any(grepl("^x$", readLines(led$path, warn = FALSE))))
})

test_that("an unwritable path fails loudly rather than silently", {
  # A path whose parent directory does not exist can never become writable, so
  # this exercises the give-up branch rather than the retry branch.
  expect_error(
    ledger_write_line(file.path(tempfile("absent-"), "nope", "l.tsv"), "x\n",
                      attempts = 2L),
    "could not append to the ledger"
  )
})

test_that("a failed append leaves the in-memory ledger unchanged", {
  led <- tmp_ledger()
  led <- ledger_append(led, "assign", "js", 1, "w", lease = 2000, now = 1000)
  before <- nrow(led$events)

  led$path <- file.path(tempfile("gone-"), "nope", "l.tsv")
  expect_error(ledger_append(led, "complete", "js", 1, "w", now = 1010))
  # The event must not appear in memory when it could not reach disk, or a
  # restarted host would disagree with its own ledger.
  expect_equal(nrow(led$events), before)
})
