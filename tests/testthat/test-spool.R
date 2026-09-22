# The worker's half of the ledger. Until this existed the host kept a durable
# record and the worker kept nothing, which is backwards: the worker is the
# machine on the unreliable link, and it is holding the expensive part.

test_that("a spooled result round-trips", {
  d <- tempfile("spool-")
  spool_write("js1", 3L, list(data.frame(x = 1:3)), dir = d)

  have <- spool_list(dir = d)
  expect_equal(nrow(have), 1L)
  expect_equal(have$jobset, "js1")
  expect_equal(have$chunk, 3L)
  expect_gt(have$bytes, 0)

  back <- spool_read(have$path)
  expect_equal(back$chunk, 3L)
  expect_equal(back$results, list(data.frame(x = 1:3)))
})

test_that("an empty or missing spool is not an error", {
  expect_equal(nrow(spool_list(dir = tempfile("never-"))), 0L)
  d <- tempfile("spool-"); dir.create(d)
  expect_equal(nrow(spool_list(dir = d)), 0L)
})

test_that("entries are listed per jobset and per chunk", {
  d <- tempfile("spool-")
  spool_write("alpha", 2L, "a2", dir = d)
  spool_write("alpha", 1L, "a1", dir = d)
  spool_write("beta",  1L, "b1", dir = d)

  expect_equal(nrow(spool_list(dir = d)), 3L)
  expect_equal(spool_list("alpha", dir = d)$chunk, c(1L, 2L))
  expect_equal(spool_list("beta", dir = d)$chunk, 1L)
  expect_equal(nrow(spool_list("gamma", dir = d)), 0L)
})

test_that("rewriting a chunk replaces rather than duplicates it", {
  d <- tempfile("spool-")
  spool_write("js", 1L, "first", dir = d)
  spool_write("js", 1L, "second", dir = d)
  have <- spool_list(dir = d)
  expect_equal(nrow(have), 1L)
  expect_equal(spool_read(have$path)$results, "second")
})

test_that("a half-written file is never read back as a result", {
  # saveRDS writes to a .partial name and renames, so a crash midway leaves
  # something that is plainly not a result rather than a truncated one.
  d <- tempfile("spool-"); dir.create(d, recursive = TRUE)
  writeLines("not an rds", file.path(d, "js-000001.rds.partial"))
  expect_equal(nrow(spool_list(dir = d)), 0L)

  spool_expire(0, dir = d)
  expect_length(list.files(d, pattern = "partial"), 0L)
})

test_that("an unreadable entry is skipped rather than failing the listing", {
  # A join must not die because one spooled file got corrupted. Expiry clears
  # it in due course.
  d <- tempfile("spool-"); dir.create(d, recursive = TRUE)
  spool_write("js", 1L, "good", dir = d)
  writeLines("garbage", file.path(d, "js-000002.rds"))

  have <- spool_list(dir = d)
  expect_equal(nrow(have), 1L)
  expect_equal(have$chunk, 1L)
})

test_that("expiry drops what is stale and keeps what is not", {
  d <- tempfile("spool-")
  spool_write("js", 1L, "x", dir = d)
  expect_equal(spool_expire(3600, dir = d), 0L)
  expect_equal(nrow(spool_list(dir = d)), 1L)

  expect_equal(spool_expire(0, dir = d), 1L)
  expect_equal(nrow(spool_list(dir = d)), 0L)
})

test_that("expiry never runs when the age is infinite", {
  d <- tempfile("spool-")
  spool_write("js", 1L, "x", dir = d)
  expect_equal(spool_expire(Inf, dir = d), 0L)
  expect_equal(nrow(spool_list(dir = d)), 1L)
})

test_that("a jobset name cannot escape the spool directory", {
  # The jobset identifier arrives from the host, so it is not this machine's
  # to trust as a path component.
  d <- tempfile("spool-")
  p <- spool_write("../../escape", 1L, "x", dir = d)
  expect_equal(normalizePath(dirname(p)), normalizePath(d))
  expect_false(grepl("\\.\\.", basename(p)))
  expect_equal(nrow(spool_list(dir = d)), 1L)
})

test_that("clearing removes only the jobset asked for", {
  d <- tempfile("spool-")
  spool_write("keep", 1L, "k", dir = d)
  spool_write("drop", 1L, "d", dir = d)

  suppressMessages(jobr_spool_clear("drop", dir = d))
  have <- spool_list(dir = d)
  expect_equal(nrow(have), 1L)
  expect_equal(have$jobset, "keep")
})

test_that("the data directory is absolute and separate from the cache", {
  # A spooled result is the only copy of work already paid for, so it must not
  # live in tempdir(), which R removes when the session ends.
  d <- spool_dir()
  expect_true(nzchar(d))
  expect_false(startsWith(normalizePath(d, mustWork = FALSE),
                          normalizePath(tempdir(), mustWork = FALSE)))
  expect_match(d, "jobR")
})
