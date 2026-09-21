#' @title The jobR.dcf project manifest
#' @name jobR.dcf
#' @description
#' Every jobR project is an ordinary directory containing a file called
#' `jobR.dcf`. That file is the project's contract with the workers: it says
#' what the project is called, which files travel to each machine, which of
#' them defines the work, and which packages the work needs.
#'
#' It is written in DCF, the same plain `Field: value` format as a package
#' `DESCRIPTION`:
#'
#' ```
#' Project: montecarlo
#' Entrypoint: R/run.R
#' Files: R/run.R, R/estimate.R
#' Lockfile: renv.lock
#' ```
#'
#' @section Fields:
#' \describe{
#'   \item{`Project`}{Required. A short name, letters and digits (dots, dashes
#'     and underscores allowed). It names the directory the bundle unpacks into
#'     on each worker, so it may not contain path separators.}
#'   \item{`Entrypoint`}{Required. The one file that defines `run_job()`. Must
#'     also be listed in `Files`.}
#'   \item{`Files`}{Required. Every file that should travel to the workers,
#'     comma or newline separated, as paths relative to the project directory.
#'     Anything not listed does not travel -- there is no implicit "send the
#'     whole folder", so a stray 2 GB CSV cannot accidentally be shipped to
#'     four machines.}
#'   \item{`Lockfile`}{Optional. Usually `renv.lock`. jobR reads only the
#'     package *names* from it and refuses to start a worker that is missing
#'     any of them, so people find out at join time rather than after every
#'     chunk has failed.}
#' }
#'
#' @section Why a separate file rather than R code:
#' A worker has to find out what a project needs *before* it runs any of that
#' project's code. If the file list lived in an R script, discovering it would
#' mean sourcing the script, which is the thing being decided about. So the
#' manifest is declarative and inert.
#'
#' @section The entrypoint:
#' The entrypoint is sourced once per worker, with the project directory as the
#' working directory, and must define a function `run_job(row)`. It receives a
#' single-row data frame -- one row of whatever you passed as `jobs` -- and may
#' return anything that `saveRDS()` can store.
#'
#' ```r
#' run_job <- function(row) {
#'   data.frame(id = row$id, estimate = simulate(row$n, row$seed))
#' }
#' ```
#'
#' The entrypoint may `source()` its siblings by project-relative path, and a
#' variable `jobr_project_dir` holds the unpacked project's absolute path for
#' projects that need to read their own data files.
#'
#' @seealso [jobr_new_project()] to scaffold one, [jobr_check_project()] to
#'   validate one.
NULL

#' Create a new jobR project
#'
#' Writes a directory containing a commented `jobR.dcf` and a stub entrypoint,
#' ready to edit.
#'
#' @param path Directory to create.
#' @param name Project name. Defaults to the directory's basename.
#'
#' @return `path`, invisibly.
#' @export
#'
#' @examples
#' p <- jobr_new_project(file.path(tempdir(), "mysim"))
#' cat(readLines(file.path(p, "jobR.dcf")), sep = "\n")
jobr_new_project <- function(path, name = basename(path)) {
  if (!grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", name)) {
    stop("project name must be alphanumeric (dots, dashes, underscores allowed): ",
         name, call. = FALSE)
  }
  if (dir.exists(path) && length(list.files(path))) {
    stop("directory already exists and is not empty: ", path, call. = FALSE)
  }
  dir.create(file.path(path, "R"), recursive = TRUE, showWarnings = FALSE)

  writeLines(c(
    "# The jobR project manifest. See ?jobR.dcf for the full reference.",
    "#",
    "# Project    a short name; becomes the directory workers unpack into",
    "# Entrypoint the one file that defines run_job(); must appear in Files",
    "# Files      everything that travels to the workers, comma separated.",
    "#            Nothing travels unless it is listed here.",
    "# Lockfile   optional renv.lock; workers refuse to start if they are",
    "#            missing any package it names",
    "",
    paste("Project:", name),
    "Entrypoint: R/run.R",
    "Files: R/run.R"
  ), file.path(path, "jobR.dcf"))

  writeLines(c(
    "# Sourced once per worker, with the project directory as the working",
    "# directory. Must define run_job().",
    "#",
    "# `row` is one row of the data frame you passed to host_new(), as a",
    "# single-row data frame. Return anything saveRDS() can store.",
    "#",
    "# Sibling files listed in Files can be sourced by relative path:",
    "#   source(\"R/helpers.R\")",
    "# and `jobr_project_dir` holds this project's absolute path if you need",
    "# to read your own data files.",
    "",
    "run_job <- function(row) {",
    "  # stringsAsFactors = FALSE is explicit on purpose: R 3.6 and earlier",
    "  # default it to TRUE, so without it a worker on an old R returns",
    "  # factors where a worker on R 4.x returns characters. See ?versions.",
    "  data.frame(id = row$id, result = row$x * 2,",
    "             stringsAsFactors = FALSE)",
    "}"
  ), file.path(path, "R", "run.R"))

  message("created project '", name, "' at ", path,
          "\nedit R/run.R, then check it with jobr_check_project(\"", path, "\")")
  invisible(path)
}

#' Check that a project is well formed
#'
#' Validates the manifest, confirms every listed file exists, sources the
#' entrypoint, and confirms it defines `run_job()`. Run this before asking
#' anyone else to join.
#'
#' @param dir Project directory.
#' @param quiet Suppress the report.
#'
#' @return A list of `ok` and `problems`, invisibly.
#' @export
jobr_check_project <- function(dir, quiet = FALSE) {
  problems <- character()
  note <- function(...) problems <<- c(problems, paste0(...))

  man <- tryCatch(manifest_read(dir), error = function(e) {
    note("manifest: ", conditionMessage(e))
    NULL
  })

  if (!is.null(man)) {
    missing_files <- man$files[!file.exists(file.path(dir, man$files))]
    if (length(missing_files)) {
      note("Files lists paths that do not exist: ",
           paste(missing_files, collapse = ", "))
    }

    if (!is.null(man$lockfile) && !file.exists(file.path(dir, man$lockfile))) {
      note("Lockfile '", man$lockfile, "' does not exist")
    }

    runner <- tryCatch(load_entrypoint(dir, man$entrypoint),
                       error = function(e) { note("entrypoint: ", conditionMessage(e)); NULL })
    if (!is.null(runner) && length(formals(runner)) < 1L) {
      note("run_job() must take at least one argument (a single-row data frame)")
    }

    pkgs <- bundle_packages(dir, man)
    absent <- packages_missing(pkgs)
    if (length(absent)) {
      note("packages named in the lockfile are not installed here: ",
           paste(absent, collapse = ", "))
    }
  }

  ok <- !length(problems)
  if (!quiet) {
    if (ok) {
      message("project looks good: ", man$project,
              " (", length(man$files), " file(s), entrypoint ", man$entrypoint, ")")
    } else {
      message("found ", length(problems), " problem(s):")
      for (p in problems) message("  - ", p)
    }
  }
  invisible(list(ok = ok, problems = problems))
}
