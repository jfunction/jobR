demo_project <- function(body = "run_job <- function(row) row$x * 2\n") {
  d <- tempfile("proj-"); dir.create(file.path(d, "R"), recursive = TRUE)
  writeLines(body, file.path(d, "R", "run.R"))
  writeLines(c("Project: demo", "Entrypoint: R/run.R", "Files: R/run.R"),
             file.path(d, "jobR.dcf"))
  d
}

demo_host <- function(n = 10, chunksize = 5, ...) {
  host_new(demo_project(), jobs = data.frame(x = seq_len(n)),
           chunksize = chunksize, passphrase = "open-sesame-friend-please",
           work_dir = tempfile("host-"), ...)
}

auth <- function(h) handle_request(h, list(op = "hello", passphrase = "open-sesame-friend-please"))$token

# ---- authentication ---------------------------------------------------------

test_that("a correct passphrase yields a token and a project description", {
  h <- demo_host()
  r <- handle_request(h, list(op = "hello", passphrase = "open-sesame-friend-please"))
  expect_true(r$ok)
  expect_match(r$token, "^[0-9a-f]{32}$")
  expect_equal(r$project, "demo")
  expect_equal(r$n_chunks, 2L)
  expect_equal(r$n_jobs, 10L)
})

test_that("a wrong passphrase is refused and issues no token", {
  h <- demo_host()
  r <- handle_request(h, list(op = "hello", passphrase = "not-the-right-words-here"))
  expect_false(r$ok)
  expect_match(r$error, "bad passphrase")
  expect_length(h$tokens, 0L)
})

test_that("passphrase matching survives case and spacing", {
  h <- demo_host()
  expect_true(handle_request(h, list(op = "hello",
                                     passphrase = " Open-Sesame-Friend-Please "))$ok)
})

test_that("every other operation requires a token", {
  h <- demo_host()
  for (op in c("claim", "submit", "bundle", "status", "renew", "fail")) {
    r <- handle_request(h, list(op = op))
    expect_false(r$ok, info = op)
    expect_match(r$error, "not authenticated", info = op)
  }
})

test_that("a forged token is refused", {
  h <- demo_host(); auth(h)
  r <- handle_request(h, list(op = "claim", token = strrep("a", 32)))
  expect_false(r$ok)
})

test_that("malformed and unknown requests are handled, not crashed on", {
  h <- demo_host(); tok <- auth(h)
  expect_false(handle_request(h, list())$ok)
  expect_false(handle_request(h, "nonsense")$ok)
  expect_match(handle_request(h, list(op = "frobnicate", token = tok))$error, "unknown op")
})

# ---- claiming and completing ------------------------------------------------

test_that("claims cover the jobset then run out", {
  h <- demo_host(n = 10, chunksize = 5)
  tok <- auth(h)
  a <- handle_request(h, list(op = "claim", token = tok))
  b <- handle_request(h, list(op = "claim", token = tok))
  expect_setequal(c(a$chunk, b$chunk), 1:2)
  expect_equal(nrow(a$jobs), 5L)

  handle_request(h, list(op = "submit", token = tok, chunk = a$chunk, results = list()))
  handle_request(h, list(op = "submit", token = tok, chunk = b$chunk, results = list()))
  c3 <- handle_request(h, list(op = "claim", token = tok))
  expect_null(c3$chunk)
  expect_true(c3$done)
})

test_that("the jobs handed out are the right rows", {
  h <- demo_host(n = 10, chunksize = 4)
  tok <- auth(h)
  seen <- list()
  for (i in 1:3) {
    r <- handle_request(h, list(op = "claim", token = tok))
    seen[[i]] <- r$jobs$x
  }
  expect_equal(sort(unlist(seen)), 1:10)
  expect_equal(lengths(seen), c(4L, 4L, 2L))   # short final chunk preserved
})

test_that("submitting persists the result and marks progress", {
  h <- demo_host(n = 4, chunksize = 2)
  tok <- auth(h)
  ch <- handle_request(h, list(op = "claim", token = tok))$chunk
  r <- handle_request(h, list(op = "submit", token = tok, chunk = ch,
                              results = list("payload")))
  expect_true(r$ok)
  expect_false(r$done)
  expect_equal(handle_request(h, list(op = "status", token = tok))$progress$done, 1L)
  expect_length(host_results(h), 1L)
  expect_equal(host_results(h)[[1]], list("payload"))
})

test_that("submit without a chunk is refused", {
  h <- demo_host(); tok <- auth(h)
  expect_false(handle_request(h, list(op = "submit", token = tok, results = 1))$ok)
})

# ---- workers disappearing ---------------------------------------------------

test_that("a lapsed lease lets another worker take the chunk", {
  h <- demo_host(n = 5, chunksize = 5, lease_seconds = 60)
  tok <- auth(h)
  first <- handle_request(h, list(op = "claim", token = tok), now = 1000)
  expect_equal(first$chunk, 1L)

  # Same instant: the chunk is held, so there is nothing to give out.
  expect_null(handle_request(h, list(op = "claim", token = tok), now = 1010)$chunk)
  # After the lease lapses it becomes available again.
  expect_equal(handle_request(h, list(op = "claim", token = tok), now = 1100)$chunk, 1L)
})

test_that("renewing keeps a chunk held", {
  h <- demo_host(n = 5, chunksize = 5, lease_seconds = 60)
  tok <- auth(h)
  handle_request(h, list(op = "claim", token = tok), now = 1000)
  handle_request(h, list(op = "renew", token = tok, chunk = 1), now = 1050)
  expect_null(handle_request(h, list(op = "claim", token = tok), now = 1100)$chunk)
})

test_that("an explicit failure returns the chunk immediately", {
  h <- demo_host(n = 5, chunksize = 5, lease_seconds = 9999)
  tok <- auth(h)
  handle_request(h, list(op = "claim", token = tok), now = 1000)
  handle_request(h, list(op = "fail", token = tok, chunk = 1), now = 1010)
  expect_equal(handle_request(h, list(op = "claim", token = tok), now = 1020)$chunk, 1L)
})

test_that("a late duplicate submission does not corrupt completion", {
  h <- demo_host(n = 5, chunksize = 5, lease_seconds = 60)
  tok <- auth(h)
  handle_request(h, list(op = "claim", token = tok), now = 1000)
  handle_request(h, list(op = "submit", token = tok, chunk = 1,
                         results = list("first")), now = 1100)
  # The presumed-dead worker reports in afterwards.
  r <- handle_request(h, list(op = "submit", token = tok, chunk = 1,
                              results = list("second")), now = 1200)
  expect_true(r$ok)
  expect_true(r$done)
  expect_length(host_results(h), 1L)
})

# ---- bundle transfer --------------------------------------------------------

test_that("an authenticated worker can fetch a verifiable bundle", {
  h <- demo_host(); tok <- auth(h)
  b <- handle_request(h, list(op = "bundle", token = tok))
  expect_true(b$ok)
  expect_true(is.raw(b$data))

  zipfile <- tempfile(fileext = ".zip")
  writeBin(b$data, zipfile)
  out <- bundle_unpack(zipfile, tempfile("w-"), expect_hash = b$hash)
  expect_equal(load_entrypoint(out, "R/run.R")(data.frame(x = 21)), 42)
})

# ---- durability -------------------------------------------------------------

test_that("progress survives rebuilding host state from the ledger", {
  work <- tempfile("host-")
  proj <- demo_project()
  jobs <- data.frame(x = 1:10)
  h <- host_new(proj, jobs, chunksize = 5, passphrase = "a-b-c-d", work_dir = work)
  tok <- auth2 <- handle_request(h, list(op = "hello", passphrase = "a-b-c-d"))$token
  ch <- handle_request(h, list(op = "claim", token = tok))$chunk
  handle_request(h, list(op = "submit", token = tok, chunk = ch, results = list(1)))

  # Host process dies; a new one starts against the same working directory.
  h2 <- host_new(proj, jobs, chunksize = 5, passphrase = "a-b-c-d",
                 work_dir = work, jobset = h$jobset)
  tok2 <- handle_request(h2, list(op = "hello", passphrase = "a-b-c-d"))$token
  st <- handle_request(h2, list(op = "status", token = tok2))
  expect_equal(st$progress$done, 1L)
  expect_equal(handle_request(h2, list(op = "claim", token = tok2))$chunk, 2L)
})

test_that("tokens from a previous host process are not honoured", {
  work <- tempfile("host-"); proj <- demo_project(); jobs <- data.frame(x = 1:4)
  h <- host_new(proj, jobs, 2, passphrase = "a-b-c-d", work_dir = work)
  old <- handle_request(h, list(op = "hello", passphrase = "a-b-c-d"))$token
  h2 <- host_new(proj, jobs, 2, passphrase = "a-b-c-d", work_dir = work,
                 jobset = h$jobset)
  expect_false(handle_request(h2, list(op = "claim", token = old))$ok)
})

# ---- entrypoints that span several files ------------------------------------
# A single-file project cannot exercise path resolution, and the first real
# multi-file example broke because sourcing ran with the entrypoint's own
# directory as the working directory rather than the project root.

test_that("an entrypoint can source a sibling file by project-relative path", {
  d <- tempfile("proj-"); dir.create(file.path(d, "R"), recursive = TRUE)
  writeLines("helper <- function(x) x * 3", file.path(d, "R", "helper.R"))
  writeLines(c('source("R/helper.R")',
               "run_job <- function(row) helper(row$x)"),
             file.path(d, "R", "run.R"))
  writeLines(c("Project: multi", "Entrypoint: R/run.R",
               "Files: R/run.R, R/helper.R"), file.path(d, "jobR.dcf"))

  runner <- load_entrypoint(d, "R/run.R")
  expect_equal(runner(data.frame(x = 5)), 15)
})

test_that("a project can locate its own data files", {
  d <- tempfile("proj-"); dir.create(file.path(d, "data"), recursive = TRUE)
  writeLines("7", file.path(d, "data", "n.txt"))
  writeLines(c('n <- as.numeric(readLines(file.path(jobr_project_dir, "data", "n.txt")))',
               "run_job <- function(row) row$x * n"),
             file.path(d, "run.R"))
  writeLines(c("Project: withdata", "Entrypoint: run.R",
               "Files: run.R, data/n.txt"), file.path(d, "jobR.dcf"))

  runner <- load_entrypoint(d, "run.R")
  expect_equal(runner(data.frame(x = 6)), 42)
})

test_that("sourcing an entrypoint does not leave the working directory moved", {
  d <- tempfile("proj-"); dir.create(d, recursive = TRUE)
  writeLines("run_job <- function(row) row$x", file.path(d, "run.R"))
  writeLines(c("Project: wd", "Entrypoint: run.R", "Files: run.R"),
             file.path(d, "jobR.dcf"))
  before <- getwd()
  load_entrypoint(d, "run.R")
  expect_equal(getwd(), before)
})

test_that("an entrypoint without run_job is rejected", {
  d <- tempfile("proj-"); dir.create(d, recursive = TRUE)
  writeLines("something_else <- function(x) x", file.path(d, "run.R"))
  writeLines(c("Project: norun", "Entrypoint: run.R", "Files: run.R"),
             file.path(d, "jobR.dcf"))
  expect_error(load_entrypoint(d, "run.R"), "must define a function named run_job")
})

test_that("the bundled montecarlo example is a valid project", {
  ex <- example_dir("montecarlo")
  skip_if_not(dir.exists(ex))
  man <- manifest_read(ex)
  expect_equal(man$project, "montecarlo")
  runner <- load_entrypoint(ex, man$entrypoint)
  out <- runner(data.frame(id = 1, n = 5000, seed = 42))
  expect_s3_class(out, "data.frame")
  expect_true(abs(out$estimate - pi) < 0.2)
})

# ---- R version reporting ----------------------------------------------------
# Machines people already own run whatever R they already have. jobR does not
# refuse them, but it does record what each is running, because "what R is that
# machine on" is the first question when results come back looking odd.

test_that("the host records the R version each worker reports", {
  h <- demo_host()
  handle_request(h, list(op = "hello", passphrase = "open-sesame-friend-please",
                         r_version = "3.6.3"))
  tok <- handle_request(h, list(op = "hello",
                                passphrase = "open-sesame-friend-please",
                                r_version = "4.5.3"))$token
  st <- handle_request(h, list(op = "status", token = tok))
  expect_setequal(unname(st$workers), c("3.6.3", "4.5.3"))
})

test_that("a worker that reports no version is still admitted", {
  h <- demo_host()
  r <- handle_request(h, list(op = "hello", passphrase = "open-sesame-friend-please"))
  expect_true(r$ok)
  expect_length(h$workers, 0L)
})

test_that("hello tells the worker what the host is running", {
  h <- demo_host()
  r <- handle_request(h, list(op = "hello", passphrase = "open-sesame-friend-please"))
  expect_equal(r$host_r_version, r_version_string())
})
