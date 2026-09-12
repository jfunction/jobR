make_project <- function(lock = TRUE, body = "run_job <- function(x) x * 2\n") {
  d <- tempfile("proj-"); dir.create(file.path(d, "R"), recursive = TRUE)
  writeLines(body, file.path(d, "R", "run.R"))
  writeLines(c(
    "Project: demo",
    "Entrypoint: R/run.R",
    "Files: R/run.R",
    if (lock) "Lockfile: renv.lock"
  ), file.path(d, "jobR.dcf"))
  if (lock) {
    writeLines(c('{ "Packages": {',
                 '  "stats":   { "Package": "stats",   "Version": "4.0.0" },',
                 '  "notreal": { "Package": "notreal", "Version": "1.0.0" } } }'),
               file.path(d, "renv.lock"))
  }
  d
}

# ---- manifest ---------------------------------------------------------------

test_that("a well formed manifest parses", {
  man <- manifest_read(make_project())
  expect_equal(man$project, "demo")
  expect_equal(man$entrypoint, "R/run.R")
  expect_equal(man$files, "R/run.R")
  expect_equal(man$lockfile, "renv.lock")
})

test_that("a manifest without a lockfile is allowed", {
  expect_null(manifest_read(make_project(lock = FALSE))$lockfile)
})

test_that("a missing manifest is an error", {
  expect_error(manifest_read(tempfile()), "no jobR.dcf")
})

test_that("an entrypoint outside Files is refused", {
  d <- make_project()
  writeLines(c("Project: demo", "Entrypoint: R/nope.R", "Files: R/run.R"),
             file.path(d, "jobR.dcf"))
  expect_error(manifest_read(d), "must also appear in Files")
})

test_that("project names are constrained", {
  d <- make_project()
  # A project name reaches the filesystem on the host, so path separators and
  # traversal must not survive parsing.
  for (bad in c("../escape", "a/b", "has space", "")) {
    writeLines(c(paste("Project:", bad), "Entrypoint: R/run.R", "Files: R/run.R"),
               file.path(d, "jobR.dcf"))
    expect_error(manifest_read(d), info = bad)
  }
})

# ---- hashing ----------------------------------------------------------------

test_that("the hash depends on content, not on file mtime", {
  d <- make_project()
  h1 <- bundle_hash(d, c("R/run.R", "jobR.dcf"))
  Sys.setFileTime(file.path(d, "R", "run.R"), Sys.time() + 5000)
  expect_equal(bundle_hash(d, c("R/run.R", "jobR.dcf")), h1)
})

test_that("the hash changes when content changes", {
  d <- make_project()
  h1 <- bundle_hash(d, "R/run.R")
  writeLines("run_job <- function(x) x * 3", file.path(d, "R", "run.R"))
  expect_false(identical(bundle_hash(d, "R/run.R"), h1))
})

test_that("the hash does not depend on the order files are listed", {
  d <- make_project()
  expect_equal(bundle_hash(d, c("R/run.R", "jobR.dcf")),
               bundle_hash(d, c("jobR.dcf", "R/run.R")))
})

test_that("hashing a file that does not exist is an error", {
  expect_error(bundle_hash(make_project(), "R/ghost.R"), "do not exist")
})

# ---- build, transfer, verify ------------------------------------------------

test_that("a bundle round-trips and verifies", {
  d <- make_project()
  b <- bundle_create(d)
  expect_true(file.exists(b$path))

  out <- bundle_unpack(b$path, tempfile("unpack-"), expect_hash = b$hash)
  expect_true(file.exists(file.path(out, "R", "run.R")))
  expect_equal(manifest_read(out)$project, "demo")
})

test_that("a tampered bundle is rejected and leaves nothing behind", {
  d <- make_project()
  b <- bundle_create(d)
  exdir <- tempfile("unpack-")
  expect_error(bundle_unpack(b$path, exdir, expect_hash = strrep("0", 64)),
               "hash mismatch")
  expect_false(dir.exists(exdir))
})

test_that("rebuilding unchanged sources yields the same hash", {
  d <- make_project()
  expect_equal(bundle_create(d)$hash, bundle_create(d)$hash)
})

# ---- caching ----------------------------------------------------------------

test_that("an absent or stale cache is detected, a current one is not", {
  d <- make_project()
  b <- bundle_create(d)
  cache <- tempfile("cache-")

  expect_true(bundle_stale(cache, b$hash))          # nothing cached yet
  bundle_unpack(b$path, cache, expect_hash = b$hash)
  bundle_stamp(cache, b$hash)
  expect_false(bundle_stale(cache, b$hash))         # nothing to transfer

  writeLines("run_job <- function(x) x + 1", file.path(d, "R", "run.R"))
  expect_true(bundle_stale(cache, bundle_create(d)$hash))
})

# ---- dependency reporting ---------------------------------------------------

test_that("declared packages are read from the lockfile", {
  expect_setequal(bundle_packages(make_project()), c("stats", "notreal"))
})

test_that("a project without a lockfile declares no packages", {
  expect_equal(bundle_packages(make_project(lock = FALSE)), character())
})

test_that("missing packages are reported before work is accepted", {
  miss <- packages_missing(bundle_packages(make_project()))
  expect_true("notreal" %in% miss)
  expect_false("stats" %in% miss)
  expect_equal(packages_missing(character()), character())
})
