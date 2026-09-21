# What a correct distributed run looks like.
#
# Kept separate from host.R, and free of any container or network concern, so
# it can be tested on a machine that cannot run Docker at all. host.R sources
# this and turns the result into an exit code; tests/testthat/test-testbed.R
# exercises it directly against fixtures.

#' Check a completed testbed run.
#'
#' @param results As returned by `host_results()`: a list of chunks, each a
#'   list of per-job results.
#' @param chunk_states A data frame from `chunk_state()`, or NULL to skip the
#'   ledger check.
#' @param n_jobs How many jobs the jobset had.
#' @param expect_hosts Minimum number of distinct machines that must have
#'   contributed.
#'
#' @return A character vector of problems. Empty means the run was correct.
testbed_problems <- function(results, chunk_states, n_jobs, expect_hosts = 2) {
  problems <- character()
  note <- function(...) problems <<- c(problems, paste0(...))

  rows <- tryCatch(
    do.call(rbind, lapply(results, function(chunk) do.call(rbind, chunk))),
    error = function(e) NULL
  )

  if (is.null(rows) || !NROW(rows)) {
    note("no results were collected at all")
  } else if (!is.data.frame(rows)) {
    # errorValues rbind into something that is not a data frame. This is the
    # shape the multi-core corruption bug produced, and it must not read as
    # success.
    note("results did not combine into a data frame (class ",
         class(rows)[1], "); the jobs probably failed on the workers")
  } else {
    if (!identical(sort(rows$id), seq_len(as.integer(n_jobs)))) {
      note("jobs not covered exactly once: ", NROW(rows), " rows, ",
           length(unique(rows$id)), " distinct ids, expected ", n_jobs)
    }
    # Without this the testbed would pass with every worker silently failing to
    # connect and the host doing nothing -- which is precisely the failure a
    # multi-node test exists to catch.
    hosts <- unique(rows$host)
    if (length(hosts) < expect_hosts) {
      note("work ran on ", length(hosts), " host(s) (",
           paste(hosts, collapse = ", "), "); expected at least ", expect_hosts)
    }
    # A worker on R < 4.0 returns factors here if the project forgot
    # stringsAsFactors = FALSE. The bundled example sets it; this keeps it so.
    if (!is.character(rows$host)) {
      note("the host column came back as ", class(rows$host)[1],
           ", not character -- see ?versions")
    }
  }

  if (!is.null(chunk_states) && !all(chunk_states$state == "done")) {
    note(sum(chunk_states$state != "done"), " of ", nrow(chunk_states),
         " chunks are not done")
  }
  problems
}
