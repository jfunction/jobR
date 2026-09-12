#' @title Worker side
#' @description
#' Joining is meant to be one line on a machine that has never seen the project
#' before. The worker authenticates, discovers what the project needs, fetches
#' the bundle only if its cached copy is out of date, refuses to start if any
#' declared package is missing, and then pulls chunks until there are none left.
#'
#' Failing loudly at join time rather than per-chunk is deliberate. A worker
#' with the wrong packages installed that accepts work anyway will quietly
#' return an error for every chunk it is handed, and because errors look like
#' completed work to a naive scheduler, it can consume an entire jobset in
#' seconds and leave nothing usable behind.
#'
#' @name join
NULL

#' Join a host and process jobs until the jobset is done
#'
#' @param url Host URL, e.g. `"tcp://192.168.1.5:5555"`.
#' @param passphrase Enrolment passphrase from the host.
#' @param cache_dir Where to keep the unpacked project bundle.
#' @param tls Optional `tlsConfig` for verifying the host.
#' @param cores Local cores to use per chunk. 1 runs serially.
#' @param timeout_ms Per-request timeout.
#' @param poll_seconds How long to wait before asking again when every chunk is
#'   currently leased to another worker. Leases lapse, so this is a pause, not
#'   a reason to stop.
#' @param max_chunks Stop after contributing this many chunks. Lets a machine
#'   donate a bounded amount of work rather than staying until the jobset ends.
#' @param max_seconds Give up after this long.
#' @param quiet Suppress progress output.
#'
#' @return A list with `chunks_done` and `jobset`, invisibly.
#' @export
jobr_join <- function(url, passphrase,
                      cache_dir = file.path(tempdir(), "jobr-worker"),
                      tls = NULL, cores = 1L, timeout_ms = 5000,
                      poll_seconds = 2, max_chunks = Inf, max_seconds = Inf,
                      quiet = FALSE) {
  sock <- nanonext::socket("req", dial = url, tls = tls)
  on.exit(close(sock), add = TRUE)
  started <- unix_time()

  # `fatal` distinguishes the two situations a silent host can mean. During
  # join, no reply is a real failure worth reporting. Once working, it usually
  # means the jobset finished and the host shut down, which is this worker's
  # cue to stop -- not an error. Any chunk still leased simply lapses and is
  # picked up by whoever runs next.
  call <- function(req, fatal = TRUE) {
    # The send result must be checked. A req socket that failed to send is not
    # entitled to receive, so recv'ing anyway reports "incorrect state" and
    # hides whatever actually went wrong.
    sent <- nanonext::send(sock, req, mode = "serial", block = timeout_ms)
    if (!identical(as.integer(sent), 0L)) {
      if (fatal) {
        stop("could not send to host: ", nanonext::nng_error(sent), call. = FALSE)
      }
      return(NULL)
    }
    reply <- nanonext::recv(sock, mode = "serial", block = timeout_ms)
    if (inherits(reply, "errorValue")) {
      if (fatal) {
        stop("no reply from host (errorValue ", as.integer(reply), ")", call. = FALSE)
      }
      return(NULL)
    }
    reply
  }

  hi <- call(list(op = "hello", passphrase = passphrase))
  if (!isTRUE(hi$ok)) stop("could not join: ", hi$error, call. = FALSE)
  if (!quiet) message("joined '", hi$project, "': ", hi$n_jobs, " jobs in ",
                      hi$n_chunks, " chunks")

  missing <- packages_missing(hi$packages)
  if (length(missing)) {
    stop("this machine is missing packages the project needs: ",
         paste(missing, collapse = ", "),
         "\ninstall them, then join again", call. = FALSE)
  }

  project_dir <- file.path(cache_dir, hi$project)
  if (bundle_stale(project_dir, hi$hash)) {
    if (!quiet) message("fetching project bundle...")
    b <- call(list(op = "bundle", token = hi$token))
    zipfile <- tempfile(fileext = ".zip")
    writeBin(b$data, zipfile)
    unlink(project_dir, recursive = TRUE)
    bundle_unpack(zipfile, project_dir, expect_hash = hi$hash)
    bundle_stamp(project_dir, hi$hash)
    unlink(zipfile)
  } else if (!quiet) {
    message("project bundle already current, nothing to fetch")
  }

  runner <- load_entrypoint(project_dir, hi$entrypoint)

  done <- 0L
  repeat {
    if (unix_time() - started > max_seconds) break
    if (done >= max_chunks) break
    cl <- call(list(op = "claim", token = hi$token), fatal = FALSE)
    if (is.null(cl)) {
      if (!quiet) message("host is no longer answering, stopping")
      break
    }
    if (!isTRUE(cl$ok)) break
    if (is.null(cl$chunk)) {
      # No chunk free at this instant. That is not the same as no work left:
      # chunks may be leased to workers that will not come back, and those
      # leases lapse shortly. Exiting here would abandon exactly the work this
      # package exists to recover, so wait and ask again.
      if (isTRUE(cl$done)) break
      if (!quiet) message("  all chunks held by other workers, waiting...")
      Sys.sleep(poll_seconds)
      next
    }

    if (!quiet) message("  chunk ", cl$chunk, " (", nrow(cl$jobs), " jobs)")
    out <- tryCatch(run_chunk(runner, cl$jobs, cores = cores),
                    error = function(e) e)
    if (inherits(out, "error")) {
      # Hand the chunk back rather than submitting a result that is really an
      # error. Someone else, or this worker on a later pass, can retry it.
      call(list(op = "fail", token = hi$token, chunk = cl$chunk), fatal = FALSE)
      if (!quiet) message("  chunk ", cl$chunk, " failed: ", conditionMessage(out))
      next
    }
    if (is.null(call(list(op = "submit", token = hi$token, chunk = cl$chunk,
                          results = out), fatal = FALSE))) {
      if (!quiet) message("host vanished before chunk ", cl$chunk, " was accepted")
      break
    }
    done <- done + 1L
  }

  if (!quiet) message("worker finished, ", done, " chunks processed")
  invisible(list(chunks_done = done, jobset = hi$jobset))
}

#' Source a project entrypoint and return its `run_job`
#'
#' @param project_dir Unpacked project directory.
#' @param entrypoint Relative path to the entrypoint script.
#'
#' @return The project's `run_job` function.
#' @export
load_entrypoint <- function(project_dir, entrypoint) {
  env <- new.env(parent = globalenv())
  path <- file.path(project_dir, entrypoint)
  if (!file.exists(path)) stop("entrypoint not found: ", path, call. = FALSE)

  # Source with the PROJECT ROOT as the working directory, not the entrypoint's
  # own directory. Paths in the manifest are project-relative, so a project that
  # says `source("R/helpers.R")` should find it whether or not the entrypoint
  # itself happens to live in R/.
  project_dir <- normalizePath(project_dir, mustWork = TRUE)
  old <- setwd(project_dir)
  on.exit(setwd(old), add = TRUE)

  # Projects that need their own data files should build paths from this rather
  # than rely on the working directory, which is only theirs while sourcing.
  assign("jobr_project_dir", project_dir, envir = env)
  sys.source(entrypoint, envir = env, chdir = FALSE)
  if (!exists("run_job", envir = env, inherits = FALSE)) {
    stop("entrypoint '", entrypoint, "' must define a function named run_job",
         call. = FALSE)
  }
  get("run_job", envir = env)
}

#' Run one chunk of jobs
#'
#' @param runner A `run_job` function taking one row of the jobs data frame.
#' @param jobs A data frame of jobs.
#' @param cores Local cores. 1 runs serially; more uses local mirai daemons.
#'
#' @return A list of per-row results, in row order.
#' @export
run_chunk <- function(runner, jobs, cores = 1L) {
  n <- nrow(jobs)
  if (n == 0L) return(list())
  if (cores <= 1L) {
    return(lapply(seq_len(n), function(i) runner(jobs[i, , drop = FALSE])))
  }
  # Within a worker, mirai parallelises across that machine's own cores. The
  # division of labour is deliberate: jobR moves work between machines, mirai
  # moves it between cores.
  mirai::daemons(as.integer(cores), .compute = "jobr_local")
  on.exit(mirai::daemons(0L, .compute = "jobr_local"), add = TRUE)
  m <- mirai::mirai_map(
    seq_len(n),
    function(i) runner(jobs[i, , drop = FALSE]),
    runner = runner, jobs = jobs, .compute = "jobr_local"
  )
  m[]
}
