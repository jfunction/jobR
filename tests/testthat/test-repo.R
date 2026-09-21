# The host-served package repository.
#
# Stocking it needs CRAN, so that part is skipped when offline. Everything else
# -- the layout, the manifest, path safety, the sync plan, the file:// URL --
# is ordinary filesystem work and is tested here with no network at all.

fake_repo <- function(files = c("src/contrib/PACKAGES",
                                "src/contrib/praise_1.0.0.tar.gz")) {
  d <- tempfile("repo-")
  for (f in files) {
    p <- file.path(d, f)
    dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    writeLines(paste("contents of", f), p)
  }
  d
}

copy_tree <- function(from, to) {
  for (f in list.files(from, recursive = TRUE)) {
    t <- file.path(to, f)
    dir.create(dirname(t), recursive = TRUE, showWarnings = FALSE)
    file.copy(file.path(from, f), t)
  }
  to
}

# ---- layout -----------------------------------------------------------------
# R derives these paths itself when reading a repository and will not find
# files anywhere else, so they are not ours to choose.

test_that("the repository layout matches what R expects", {
  expect_equal(repo_subdir("source"), "src/contrib")
  expect_equal(repo_subdir("win.binary", "4.5"), "bin/windows/contrib/4.5")
  expect_equal(repo_subdir("mac.binary", "4.4"), "bin/macosx/contrib/4.4")
  expect_error(repo_subdir("nonsense"), "unsupported package type")
})

test_that("an R series is the first two components only", {
  expect_equal(r_series("4.5.3"), "4.5")
  expect_equal(r_series("3.6.3"), "3.6")
  expect_equal(r_series(getRversion()), r_series())
})

test_that("the repository lives under the host work directory", {
  expect_equal(repo_path(file.path("x", "host")), file.path("x", "host", "repo"))
})

# ---- manifest ---------------------------------------------------------------

test_that("a manifest lists every file with a hash", {
  m <- repo_manifest(fake_repo())
  expect_setequal(m$path,
                  c("src/contrib/PACKAGES", "src/contrib/praise_1.0.0.tar.gz"))
  expect_true(all(nchar(m$sha256) == 64))
  expect_true(all(m$size > 0))
  # Forward slashes whatever the platform: these paths cross the wire.
  expect_false(any(grepl("[\\]", m$path)))
})

test_that("an absent repository yields an empty manifest, not an error", {
  m <- repo_manifest(tempfile("absent-"))
  expect_equal(nrow(m), 0L)
  expect_setequal(names(m), c("path", "size", "sha256"))
})

# ---- path safety ------------------------------------------------------------
# A path arriving from a worker names a file the host will read and return.

test_that("traversal and absolute paths are refused", {
  bad <- c("../secret", "a/../../b", "/etc/passwd", "C:/Windows/x",
           "~/.ssh/id_rsa", "a\\b", "", "a//b", NA_character_)
  for (p in bad) expect_false(repo_path_ok(p), info = paste("accepted:", p))
})

test_that("ordinary repository paths are accepted", {
  ok <- c("src/contrib/PACKAGES", "bin/windows/contrib/4.5/praise_1.0.0.zip",
          "PACKAGES.gz")
  for (p in ok) expect_true(repo_path_ok(p), info = p)
})

test_that("non-strings are refused", {
  expect_false(repo_path_ok(NULL))
  expect_false(repo_path_ok(c("a", "b")))
  expect_false(repo_path_ok(42))
})

# ---- sync plan --------------------------------------------------------------
# This is what makes a return visit cost nothing, which is the whole point on a
# slow link.

test_that("everything is needed when nothing is cached", {
  d <- fake_repo()
  expect_equal(nrow(repo_sync_plan(repo_manifest(d), tempfile("local-"))), 2L)
})

test_that("nothing is needed when the cache is identical", {
  d <- fake_repo()
  local <- copy_tree(d, tempfile("local-"))
  expect_equal(nrow(repo_sync_plan(repo_manifest(d), local)), 0L)
})

test_that("only a changed file is re-fetched", {
  d <- fake_repo()
  local <- copy_tree(d, tempfile("local-"))
  writeLines("tampered", file.path(local, "src", "contrib", "PACKAGES"))
  expect_equal(repo_sync_plan(repo_manifest(d), local)$path,
               "src/contrib/PACKAGES")
})

test_that("an empty manifest plans nothing", {
  expect_equal(nrow(repo_sync_plan(repo_manifest(tempfile()), tempfile())), 0L)
})

# ---- url --------------------------------------------------------------------

test_that("the repository url is one R can actually read a repo through", {
  d <- fake_repo()
  u <- repo_url(d)
  expect_match(u, "^file:///")
  expect_false(grepl("[\\]", u))

  writeLines(c("Package: praise", "Version: 1.0.0", ""),
             file.path(d, "src", "contrib", "PACKAGES"))
  ap <- available.packages(repos = u, type = "source")
  expect_true("praise" %in% rownames(ap))
})

# ---- stocking (needs CRAN) --------------------------------------------------

test_that("stocking nothing is harmless", {
  expect_equal(nrow(repo_stock(character(), tempfile("repo-"))), 0L)
})

test_that("a stocked repository is readable by R", {
  skip_on_cran()
  reachable <- tryCatch(
    nrow(utils::available.packages(repos = "https://cloud.r-project.org",
                                   type = "source")) > 0,
    error = function(e) FALSE, warning = function(w) FALSE)
  skip_if_not(isTRUE(reachable), "no CRAN access")

  d <- tempfile("repo-")
  # praise is tiny and has no dependencies, so this stays quick.
  repo_stock("praise", d, types = "source", quiet = TRUE)
  m <- repo_manifest(d)
  expect_true(any(grepl("praise.*[.]tar[.]gz$", m$path)))
  expect_true(any(grepl("src/contrib/PACKAGES$", m$path)))

  expect_true("praise" %in%
                rownames(available.packages(repos = repo_url(d), type = "source")))
})

test_that("base packages are never stocked", {
  skip_on_cran()
  reachable <- tryCatch(
    nrow(utils::available.packages(repos = "https://cloud.r-project.org",
                                   type = "source")) > 0,
    error = function(e) FALSE, warning = function(w) FALSE)
  skip_if_not(isTRUE(reachable), "no CRAN access")

  d <- tempfile("repo-")
  # praise Suggests testthat, but recursive deps must never drag in `stats`,
  # `utils` and friends -- they ship with R and cannot be downloaded.
  repo_stock("praise", d, types = "source", quiet = TRUE)
  m <- repo_manifest(d)
  expect_false(any(grepl("/(stats|utils|methods|base)_", m$path)))
})
