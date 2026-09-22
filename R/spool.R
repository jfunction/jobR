#' @title Results a worker has computed but not yet delivered
#' @description
#' The host keeps a durable ledger; until this existed, the worker kept nothing.
#' That is the wrong way round. The worker is the machine on the unreliable
#' link, doing the expensive part, and a submit that failed threw the results
#' away — an hour of computation lost because a connection blinked at the wrong
#' moment, and the chunk reissued so that somebody else could compute it again.
#'
#' The spool is the worker's half of the ledger. Results that cannot be
#' delivered are written to disk, survive the R session ending, and are offered
#' again the next time a host is reachable. Because completion is terminal, a
#' late delivery for a chunk somebody else has already finished is harmless: the
#' host records it and the count does not change.
#'
#' It is kept deliberately separate from the project cache. The cache is a
#' cache — discardable, re-fetchable from the host. A spooled result is the only
#' copy of work that has already been paid for, so it lives with the user's data
#' rather than in `tempdir()`, which R removes when the session ends.
#'
#' @name spool
NULL

#' Where jobR keeps data that must outlive the session
#'
#' `tools::R_user_dir()` when the R in use has it, and the same platform
#' conventions by hand when it does not. R gained that function in 4.0, and
#' this package supports 3.6, which is exactly the vintage of machine most
#' likely to be donating cycles.
#'
#' The fallback follows the conventions implemented by the `rappdirs` package
#' (MIT). `rappdirs` itself is not a dependency: it needs compilation, which
#' would put a toolchain in front of precisely the older Windows user this
#' package exists to include.
#'
#' @param what Subdirectory under the package's data directory.
#'
#' @return An absolute path. The directory is not created.
#' @keywords internal
jobr_data_dir <- function(what = NULL) {
  base <- if (exists("R_user_dir", envir = asNamespace("tools"), inherits = FALSE)) {
    get("R_user_dir", envir = asNamespace("tools"))("jobR", "data")
  } else if (.Platform$OS.type == "windows") {
    # Laid out exactly as R_user_dir() would, so that upgrading R across the
    # 4.0 boundary finds the same spool rather than orphaning it.
    root <- Sys.getenv("APPDATA", Sys.getenv("LOCALAPPDATA", "~"))
    file.path(root, "R", "data", "R", "jobR")
  } else if (Sys.info()[["sysname"]] == "Darwin") {
    file.path("~", "Library", "Application Support", "org.R-project.R", "R", "jobR")
  } else {
    root <- Sys.getenv("XDG_DATA_HOME")
    if (!nzchar(root)) root <- file.path("~", ".local", "share")
    file.path(root, "R", "jobR")
  }
  p <- if (is.null(what)) base else file.path(base, what)
  path.expand(p)
}

#' Default location for the spool
#'
#' @return An absolute path.
#' @export
spool_dir <- function() jobr_data_dir("spool")

# A jobset identifier reaches this from the host, so it is not this machine's
# to trust as a path component. Host-generated ids are hex, but `jobset` is a
# user-settable argument to host_new(), and a worker should not be one bad
# string away from writing outside its own spool.
spool_key <- function(jobset, chunk) {
  # Dots are replaced along with everything else. A name that survived as
  # "..foo" would produce a file that list.files() treats as hidden and never
  # returns, so the result would be written and then be invisible forever --
  # silent loss of exactly the work this exists to protect.
  safe <- gsub("[^A-Za-z0-9_-]", "_", as.character(jobset))
  safe <- substr(safe, 1L, 64L)
  if (!nzchar(safe)) safe <- "jobset"
  sprintf("%s-%06d.rds", safe, as.integer(chunk))
}

#' Set aside results that could not be delivered
#'
#' @param jobset Jobset identifier.
#' @param chunk Chunk index.
#' @param results The per-job results for that chunk.
#' @param dir Spool directory.
#'
#' @return The path written, invisibly.
#' @export
spool_write <- function(jobset, chunk, results, dir = spool_dir()) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, spool_key(jobset, chunk))
  # Written to a temporary name and renamed, so that a crash midway leaves no
  # half-written file that would later be read back as a result.
  tmp <- paste0(path, ".partial")
  saveRDS(list(jobset = jobset, chunk = as.integer(chunk),
               results = results, at = unix_time()), tmp)
  ok <- file.rename(tmp, path)
  if (!ok) {
    unlink(tmp)
    stop("could not write spooled results to ", path, call. = FALSE)
  }
  invisible(path)
}

#' What is waiting to be delivered
#'
#' @param jobset Restrict to one jobset, or NULL for all.
#' @param dir Spool directory.
#'
#' @return A data frame of `jobset`, `chunk`, `at`, `bytes` and `path`, empty
#'   if nothing is spooled.
#' @export
spool_list <- function(jobset = NULL, dir = spool_dir()) {
  empty <- data.frame(jobset = character(), chunk = integer(), at = numeric(),
                      bytes = numeric(), path = character(),
                      stringsAsFactors = FALSE)
  files <- list.files(dir, pattern = "\\.rds$", full.names = TRUE,
                      all.files = TRUE)
  if (!length(files)) return(empty)

  rows <- lapply(files, function(f) {
    # A spooled file that cannot be read is not worth failing a join over.
    # Leave it; expiry will clear it.
    h <- tryCatch(readRDS(f), error = function(e) NULL)
    if (is.null(h) || is.null(h$chunk)) return(NULL)
    data.frame(jobset = as.character(h$jobset), chunk = as.integer(h$chunk),
               at = as.numeric(h$at), bytes = file.size(f), path = f,
               stringsAsFactors = FALSE)
  })
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (!length(rows)) return(empty)
  out <- do.call(rbind, rows)
  if (!is.null(jobset)) out <- out[out$jobset == jobset, , drop = FALSE]
  out[order(out$jobset, out$chunk), , drop = FALSE]
}

#' Read one spooled entry
#'
#' @param path Path from [spool_list()].
#'
#' @return The stored list, or NULL if it cannot be read.
#' @keywords internal
spool_read <- function(path) tryCatch(readRDS(path), error = function(e) NULL)

#' Discard spooled results
#'
#' @param paths Paths from [spool_list()].
#'
#' @return The number removed, invisibly.
#' @export
spool_drop <- function(paths) {
  invisible(sum(unlink(paths) == 0L))
}

#' Discard spooled results older than a given age
#'
#' Results cannot wait forever. A worker whose host never returns would
#' otherwise keep them until the disk filled, and a result whose jobset has
#' long since been abandoned is of no use to anybody.
#'
#' @param max_age_seconds Maximum age. `Inf` keeps everything.
#' @param dir Spool directory.
#'
#' @return The number removed, invisibly.
#' @export
spool_expire <- function(max_age_seconds = 7 * 24 * 3600, dir = spool_dir()) {
  if (!is.finite(max_age_seconds)) return(invisible(0L))
  # Swept first: a spool holding nothing but debris would otherwise return
  # early and never clear it.
  unlink(list.files(dir, pattern = "\\.partial$", full.names = TRUE,
                    all.files = TRUE))
  have <- spool_list(dir = dir)
  if (!nrow(have)) return(invisible(0L))
  stale <- have$path[(unix_time() - have$at) > max_age_seconds]
  if (!length(stale)) return(invisible(0L))
  spool_drop(stale)
}

#' Show what this machine has computed but not delivered
#'
#' Nobody will think to look in a data directory. This is the way to find out
#' whether a worker is holding results, and [jobr_spool_clear()] is the way to
#' throw them away.
#'
#' @param jobset Restrict to one jobset, or NULL for all.
#' @param dir Spool directory.
#'
#' @return A data frame, invisibly, with `age` in hours added for reading.
#' @export
jobr_spool <- function(jobset = NULL, dir = spool_dir()) {
  have <- spool_list(jobset, dir = dir)
  if (!nrow(have)) {
    message("nothing spooled: every result this machine computed was delivered")
    return(invisible(have))
  }
  have$age_hours <- round((unix_time() - have$at) / 3600, 1)
  message(nrow(have), " undelivered chunk(s) in ", dir)
  print(have[, c("jobset", "chunk", "age_hours", "bytes")])
  invisible(have)
}

#' Throw away spooled results
#'
#' @param jobset Restrict to one jobset, or NULL for all.
#' @param dir Spool directory.
#'
#' @return The number removed, invisibly.
#' @export
jobr_spool_clear <- function(jobset = NULL, dir = spool_dir()) {
  have <- spool_list(jobset, dir = dir)
  if (!nrow(have)) return(invisible(0L))
  n <- spool_drop(have$path)
  message("discarded ", n, " undelivered chunk(s)")
  invisible(n)
}
