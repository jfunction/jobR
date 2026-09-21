#' @title Working across different R versions
#' @description
#' A fleet of machines people already own is a fleet of mismatched R versions.
#' That is the normal case for this package, not an edge case, so jobR keeps its
#' own floor as low as its dependencies allow and tries to make the differences
#' that *do* matter visible rather than mysterious.
#'
#' The floor is R 3.6, which is what nanonext requires. Note that the language
#' version is rarely the real constraint: CRAN builds binaries only for the
#' current R and the one before it, so on an older R the compiled dependencies
#' have to be built from source. See `vignette`-free notes in `HOME-TEST.md`.
#'
#' @section The difference that actually bites:
#' R 4.0.0 changed `data.frame()` to default `stringsAsFactors = FALSE`; before
#' that it defaulted to `TRUE`. A `run_job()` that builds a data frame with a
#' character column therefore returns **characters** on a worker running R 4.x
#' and **factors** on a worker running R 3.6 — same code, same project, same
#' bundle.
#'
#' This is worse than it first looks. When the host combines the chunks, the
#' type of the combined column depends on which chunk is first, and in a
#' distributed run that is whichever machine happened to finish first. The same
#' jobset can produce differently-typed results on two runs. Worse still,
#' `as.numeric()` on a factor returns the level *codes*, so a column of
#' numeric-looking strings silently becomes 1, 2, 3.
#'
#' The fix is one argument, and it is worth writing even in projects that will
#' only ever run on one machine:
#'
#' ```r
#' run_job <- function(row) {
#'   data.frame(id = row$id, label = "whatever", stringsAsFactors = FALSE)
#' }
#' ```
#'
#' @name versions
NULL

#' This machine's R version as a short string
#'
#' @return For example `"4.5.3"`.
#' @export
r_version_string <- function() {
  paste(R.version$major, R.version$minor, sep = ".")
}

#' Warnings worth showing when host and worker differ
#'
#' @param host_version The host's R version string, or `NULL` if it did not
#'   report one.
#' @param worker_version This machine's R version; injectable for tests.
#'
#' @return A character vector of warnings, empty when there is nothing to say.
#' @export
version_skew_warnings <- function(host_version, worker_version = r_version_string()) {
  out <- character()
  if (is.null(host_version) || !nzchar(host_version)) return(out)

  w <- numeric_version(worker_version)
  h <- numeric_version(host_version)
  if (w == h) return(out)

  out <- c(out, paste0("this worker runs R ", worker_version,
                       "; the host runs R ", host_version))

  # The one difference that silently changes results rather than failing loudly.
  if (xor(w < numeric_version("4.0.0"), h < numeric_version("4.0.0"))) {
    out <- c(out, paste0(
      "R 4.0 changed the data.frame() default for stringsAsFactors, so a ",
      "run_job() that builds character columns will return factors on one ",
      "side and characters on the other. Pass stringsAsFactors = FALSE ",
      "explicitly in the project. See ?versions"))
  }
  out
}
