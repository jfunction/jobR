#' @title A workload with a known runtime
#' @description
#' Evaluating a distributed system needs a job whose cost you know in advance,
#' otherwise you cannot tell a speedup from a fast machine. These helpers build
#' one: each job burns a set number of seconds of real CPU, so a run of 240 jobs
#' at one second each is 240 CPU-seconds no matter whose laptop it lands on, and
#' the wall-clock time tells you directly how much parallelism you actually got.
#'
#' The work is deliberately CPU-bound rather than `Sys.sleep()`. Sleeping would
#' show scheduling working but would parallelise perfectly even on one core,
#' which is exactly the thing being measured.
#'
#' @name benchmark
NULL

#' Burn a fixed amount of CPU time
#'
#' @param seconds Approximate seconds of CPU to consume.
#'
#' @return The accumulated value, which exists only so the work cannot be
#'   optimised away.
#' @export
#'
#' @examples
#' system.time(jobr_burn(0.1))
jobr_burn <- function(seconds) {
  t0 <- Sys.time()
  x <- 0
  repeat {
    x <- x + sum(sqrt(stats::runif(2000)))
    if (as.numeric(difftime(Sys.time(), t0, units = "secs")) >= seconds) break
  }
  x
}

#' Build a benchmark jobs data frame
#'
#' @param n Number of jobs.
#' @param seconds CPU seconds each job should take.
#'
#' @return A data frame suitable for passing to [host_new()].
#' @export
#'
#' @examples
#' head(jobr_benchmark_jobs(10, seconds = 0.5))
jobr_benchmark_jobs <- function(n = 240, seconds = 1) {
  data.frame(id = seq_len(n), seconds = seconds)
}

#' Estimate how long a benchmark run should take
#'
#' @param n Number of jobs.
#' @param seconds CPU seconds per job.
#' @param cores Total cores contributing across all machines.
#'
#' @return A named numeric vector of expected seconds, invisibly; printed as a
#'   short report.
#' @export
#'
#' @examples
#' jobr_estimate(240, seconds = 1, cores = c(laptop_a = 4, laptop_b = 8))
jobr_estimate <- function(n = 240, seconds = 1, cores = 1) {
  total_cpu <- n * seconds
  total_cores <- sum(cores)
  per <- total_cpu / cores
  message("benchmark estimate")
  message("  total work    : ", n, " jobs x ", seconds, "s = ", total_cpu, " CPU-seconds")
  message("  one core alone: ", round(total_cpu), "s (", round(total_cpu / 60, 1), " min)")
  if (total_cores > 1) {
    message("  across ", total_cores, " cores: ~", round(total_cpu / total_cores), "s",
            "  (perfect scaling; expect a little more)")
  }
  if (!is.null(names(cores)) && length(cores) > 1) {
    message("  if each machine takes work in proportion to its cores:")
    for (i in seq_along(cores)) {
      message("    ", names(cores)[i], ": ~", round(cores[i] / total_cores * n),
              " jobs")
    }
  }
  invisible(c(cpu_seconds = total_cpu, ideal_seconds = total_cpu / total_cores))
}

#' Summarise which machine did what
#'
#' @param results Results as returned by [host_results()].
#'
#' @return A data frame of one row per machine: jobs done, CPU seconds
#'   contributed, and share of the total.
#' @export
jobr_benchmark_report <- function(results) {
  rows <- do.call(rbind, lapply(results, function(chunk) do.call(rbind, chunk)))
  if (is.null(rows) || !nrow(rows)) {
    return(data.frame(host = character(), jobs = integer(),
                      cpu_seconds = numeric(), share = numeric()))
  }
  by_host <- split(rows, rows$host)
  out <- data.frame(
    host        = names(by_host),
    jobs        = vapply(by_host, nrow, integer(1)),
    cpu_seconds = round(vapply(by_host, function(d) sum(d$elapsed), numeric(1)), 1),
    row.names   = NULL,
    stringsAsFactors = FALSE
  )
  out$share <- round(out$jobs / sum(out$jobs), 3)
  out[order(-out$jobs), ]
}
