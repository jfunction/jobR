#' @title Project bundles
#' @description
#' A bundle is what a worker needs in order to run somebody else's jobs: the
#' project's source, a declaration of which R packages it depends on, and a
#' content hash over both.
#'
#' The hash is computed over file contents, never over the zip's bytes, because
#' zip archives embed modification times. Hashing the archive would make every
#' rebuild look like a change and force every worker to re-download a bundle
#' that had not actually moved. On a metered mobile link that is the difference
#' between usable and not, so it is worth the small extra care.
#'
#' The manifest is DCF, the same format as `DESCRIPTION`. It is declarative on
#' purpose: a worker must be able to discover what a project needs *without*
#' executing any of that project's code first.
#'
#' @name bundle
NULL

MANIFEST_FILE <- "jobR.dcf"

#' Read a project manifest
#'
#' @param dir Project directory containing `jobR.dcf`.
#'
#' @return A list with `project`, `entrypoint`, `files`, and `lockfile`.
#' @export
manifest_read <- function(dir) {
  path <- file.path(dir, MANIFEST_FILE)
  if (!file.exists(path)) {
    stop("no ", MANIFEST_FILE, " found in ", dir, call. = FALSE)
  }
  d <- read.dcf(path)
  field <- function(name, required = TRUE) {
    if (!name %in% colnames(d)) {
      if (required) stop(MANIFEST_FILE, " is missing required field: ", name, call. = FALSE)
      return(NULL)
    }
    unname(trimws(d[1L, name]))
  }
  split_list <- function(x) {
    if (is.null(x) || !nzchar(x)) return(character())
    trimws(unlist(strsplit(x, "[,\n]")))
  }

  project <- field("Project")
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", project)) {
    stop("Project must be alphanumeric (dots, dashes and underscores allowed): ", project,
         call. = FALSE)
  }
  files <- split_list(field("Files"))
  files <- files[nzchar(files)]
  if (!length(files)) stop(MANIFEST_FILE, " lists no Files", call. = FALSE)

  entry <- field("Entrypoint")
  if (!entry %in% files) {
    stop("Entrypoint '", entry, "' must also appear in Files", call. = FALSE)
  }

  list(
    project    = project,
    entrypoint = entry,
    files      = files,
    lockfile   = field("Lockfile", required = FALSE)
  )
}

#' Content hash for a set of project files
#'
#' Stable across rebuilds, machines and filesystems: it depends only on the
#' sorted relative paths and the bytes they contain.
#'
#' @param dir Project directory.
#' @param files Relative paths within `dir`.
#'
#' @return A single sha256 string.
#' @export
bundle_hash <- function(dir, files) {
  files <- sort(unique(files))
  missing <- files[!file.exists(file.path(dir, files))]
  if (length(missing)) {
    stop("manifest lists files that do not exist: ",
         paste(missing, collapse = ", "), call. = FALSE)
  }
  per <- vapply(
    files,
    function(f) digest::digest(file = file.path(dir, f), algo = "sha256"),
    character(1), USE.NAMES = FALSE
  )
  digest::digest(paste(files, per, sep = ":", collapse = "\n"), algo = "sha256")
}

#' Build a bundle from a project directory
#'
#' @param dir Project directory containing a `jobR.dcf` manifest.
#' @param out Path for the resulting `.zip`. Defaults to a temporary file.
#'
#' @return A list with `path`, `hash`, `manifest` and `packages`.
#' @export
bundle_create <- function(dir, out = tempfile(fileext = ".zip")) {
  man <- manifest_read(dir)
  files <- bundle_file_set(dir, man)
  hash <- bundle_hash(dir, files)

  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  # zip::zip() with `root` preserves each file's path relative to the project
  # directory. zipr() would flatten R/run.R to run.R, which both breaks
  # sourcing and silently changes the hash on the far side.
  zip::zip(zipfile = out, files = files, root = dir)

  list(path = out, hash = hash, manifest = man, packages = bundle_packages(dir, man))
}

# The exact set of files a bundle covers. Used by both the builder and the
# verifier so the two can never disagree about what was hashed.
bundle_file_set <- function(dir, man) {
  files <- c(man$files, MANIFEST_FILE)
  if (!is.null(man$lockfile) && file.exists(file.path(dir, man$lockfile))) {
    files <- c(files, man$lockfile)
  }
  sort(unique(files))
}

#' Packages a bundle declares, read from its lockfile
#'
#' @param dir Project directory.
#' @param man A manifest as returned by [manifest_read()].
#'
#' @return A character vector of package names, possibly empty.
#' @export
bundle_packages <- function(dir, man = manifest_read(dir)) {
  if (is.null(man$lockfile)) return(character())
  path <- file.path(dir, man$lockfile)
  if (!file.exists(path)) return(character())
  # Parsed by hand rather than via renv so that a host can serve a bundle
  # without renv installed. Only the package names are needed here.
  txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
  pkgs <- regmatches(txt, gregexpr('"Package"\\s*:\\s*"([^"]+)"', txt))[[1]]
  unique(gsub('.*"Package"\\s*:\\s*"([^"]+)".*', "\\1", pkgs))
}

#' Unpack a bundle and verify it matches an expected hash
#'
#' @param zipfile Path to the bundle zip.
#' @param exdir Directory to unpack into.
#' @param expect_hash Hash the bundle must have. Extraction is rolled back if
#'   it does not match.
#'
#' @return The path the bundle was unpacked to.
#' @export
bundle_unpack <- function(zipfile, exdir, expect_hash = NULL) {
  dir.create(exdir, recursive = TRUE, showWarnings = FALSE)
  zip::unzip(zipfile, exdir = exdir)
  if (!is.null(expect_hash)) {
    man <- manifest_read(exdir)
    # Deliberately strict: every file the manifest names must be present. A
    # truncated transfer must fail verification rather than quietly hashing
    # whichever subset happened to arrive.
    files <- bundle_file_set(exdir, man)
    got <- tryCatch(bundle_hash(exdir, files), error = function(e) {
      unlink(exdir, recursive = TRUE)
      stop("bundle is incomplete: ", conditionMessage(e), call. = FALSE)
    })
    if (!identical(got, expect_hash)) {
      unlink(exdir, recursive = TRUE)
      stop("bundle hash mismatch: expected ", substr(expect_hash, 1, 12),
           " got ", substr(got, 1, 12), call. = FALSE)
    }
  }
  exdir
}

#' Is a cached bundle still current?
#'
#' Lets a worker reconnect and transfer nothing when the project has not
#' changed, which is the usual case.
#'
#' @param cache_dir Directory holding a previously unpacked bundle.
#' @param expect_hash The hash the host is currently advertising.
#'
#' @return `TRUE` when the cache is absent or out of date.
#' @export
bundle_stale <- function(cache_dir, expect_hash) {
  stamp <- file.path(cache_dir, ".jobr-hash")
  if (!file.exists(stamp)) return(TRUE)
  !identical(readLines(stamp, warn = FALSE)[1], expect_hash)
}

#' Record the hash of an unpacked bundle so it can be cached
#'
#' @param cache_dir Directory holding the unpacked bundle.
#' @param hash The bundle's hash.
#'
#' @return `cache_dir`, invisibly.
#' @export
bundle_stamp <- function(cache_dir, hash) {
  writeLines(hash, file.path(cache_dir, ".jobr-hash"))
  invisible(cache_dir)
}

#' Report which of a bundle's packages are missing locally
#'
#' Checked before any work is accepted so a worker fails loudly at join time
#' rather than silently returning errors for every chunk it is handed.
#'
#' @param packages Package names the bundle declares.
#' @param lib Library paths to search.
#'
#' @return The names that are not installed.
#' @export
packages_missing <- function(packages, lib = .libPaths()) {
  if (!length(packages)) return(character())
  installed <- rownames(utils::installed.packages(lib.loc = lib))
  setdiff(packages, installed)
}
