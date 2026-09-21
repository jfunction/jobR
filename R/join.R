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
#' @param max_failures Stop after this many chunks fail in a row. Repeated
#'   failures usually mean this machine is misconfigured rather than that the
#'   work is bad, and a worker that keeps failing hands chunks back to the pool
#'   indefinitely.
#' @param renew_seconds How often to renew the lease on the chunk being
#'   worked on. Defaults to a third of the lease the host advertises, so two
#'   renewals can be lost before the chunk is given to someone else.
#' @param use_host_packages When the host serves a package repository, fetch
#'   missing packages from it rather than from CRAN. FALSE always uses CRAN.
#' @param max_seconds Give up after this long.
#' @param quiet Suppress progress output.
#'
#' @return A list with `chunks_done` and `jobset`, invisibly.
#' @export
jobr_join <- function(url, passphrase,
                      cache_dir = file.path(tempdir(), "jobr-worker"),
                      tls = NULL, cores = 1L, timeout_ms = 5000,
                      poll_seconds = 2, max_chunks = Inf, max_seconds = Inf,
                      max_failures = 5L, renew_seconds = NULL,
                      use_host_packages = TRUE, quiet = FALSE) {
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

  hi <- call(list(op = "hello", passphrase = passphrase,
                  r_version = r_version_string()))
  if (!isTRUE(hi$ok)) stop("could not join: ", hi$error, call. = FALSE)
  if (!quiet) message("joined '", hi$project, "': ", hi$n_jobs, " jobs in ",
                      hi$n_chunks, " chunks")
  if (!quiet) for (w in version_skew_warnings(hi$host_r_version)) message("note: ", w)

  missing <- packages_missing(hi$packages)
  if (length(missing) && isTRUE(hi$serves_packages) && use_host_packages) {
    # The host has these packages already and is on the other end of this very
    # socket. Fetching from it beats every worker pulling the same bytes from
    # CRAN, which on a metered or slow link is the real cost of joining.
    if (!quiet) {
      message("missing ", length(missing), " package(s); fetching from the ",
              "host rather than CRAN")
    }
    missing <- tryCatch(
      repo_pull_install(call, missing, file.path(cache_dir, "repo"),
                        token = hi$token, quiet = quiet),
      error = function(e) {
        if (!quiet) message("  could not install from the host: ",
                            conditionMessage(e))
        missing
      }
    )
  }
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

  # mirai is Suggested, not required: it is only needed to spread a chunk
  # across this machine's own cores. Discovering that at the point of running a
  # chunk is far too late -- the chunk fails, is handed back, claimed again,
  # and fails identically forever. Check it once, here, and carry on serially
  # if it is absent, because a worker contributing one core is still a worker.
  if (cores > 1L && !requireNamespace("mirai", quietly = TRUE)) {
    message("cores = ", cores, " needs the 'mirai' package, which is not ",
            "installed on this machine.\n",
            "  running one job at a time instead. To use all ", cores,
            " cores:  install.packages(\"mirai\")")
    cores <- 1L
  }

  # Loaded once here so a broken entrypoint fails at join rather than being
  # discovered chunk by chunk. run_chunk re-resolves it from the cache.
  load_entrypoint_cached(project_dir, hi$entrypoint)

  done <- 0L
  consecutive_failures <- 0L
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

    # Renew at a third of the lease, so two renewals can be lost before the
    # host gives the chunk to someone else. The host states the lease length
    # when it hands out the chunk, so the two never disagree.
    lease <- if (is.null(cl$lease_seconds)) 300 else cl$lease_seconds
    every <- if (is.null(renew_seconds)) max(5, lease / 3) else renew_seconds
    beat <- function() {
      r <- call(list(op = "renew", token = hi$token, chunk = cl$chunk),
                fatal = FALSE)
      # A refusal means the lease lapsed and the chunk now belongs to someone
      # else. Finishing it is wasted but harmless -- the submit will be a
      # duplicate, and completion is terminal -- so say so and carry on.
      if (!is.null(r) && !isTRUE(r$ok) && !quiet) {
        message("  lost the lease on chunk ", cl$chunk, ": ", r$error)
      }
      invisible(NULL)
    }

    out <- tryCatch(run_chunk(project_dir, hi$entrypoint, cl$jobs, cores = cores,
                              heartbeat = beat, heartbeat_seconds = every),
                    error = function(e) e)
    if (inherits(out, "error")) {
      # Hand the chunk back rather than submitting a result that is really an
      # error. Someone else, or this worker on a later pass, can retry it.
      call(list(op = "fail", token = hi$token, chunk = cl$chunk), fatal = FALSE)
      consecutive_failures <- consecutive_failures + 1L
      if (!quiet) message("  chunk ", cl$chunk, " failed: ", conditionMessage(out))

      # Something wrong with this machine rather than with that chunk -- a
      # missing package, an unreadable path -- fails every chunk identically.
      # Without a limit the worker spins, and each failure hands work back to
      # the pool, so a single broken machine can churn the whole jobset.
      if (consecutive_failures >= max_failures) {
        stop("giving up after ", max_failures, " chunks failed in a row on this ",
             "machine.\n  This usually means the environment is wrong rather ",
             "than the work.\n  Last error: ", conditionMessage(out),
             call. = FALSE)
      }
      next
    }
    consecutive_failures <- 0L
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
#' Takes the project rather than a loaded function, because a `run_job` closure
#' cannot be sent to another process intact. mirai evaluates a mapped function
#' in a fresh environment, so a closure's enclosing environment does not travel
#' with it: `run_job` would arrive, but anything it was defined alongside --
#' every helper in every other file the manifest lists -- would not. Each daemon
#' therefore sources the project itself, exactly as a serial worker does.
#'
#' @param project_dir Unpacked project directory.
#' @param entrypoint Relative path to the entrypoint, from the manifest.
#' @param jobs A data frame of jobs.
#' @param cores Local cores. 1 runs serially; more uses local mirai daemons.
#' @param heartbeat Optional zero-argument function called periodically while
#'   the chunk runs, used by [jobr_join()] to renew its lease. A worker is
#'   single-threaded, so without somewhere to call from during a long chunk
#'   there is no way to tell the host it is still alive.
#' @param heartbeat_seconds How often, at most, to call `heartbeat`.
#'
#' @return A list of per-row results, in row order.
#' @export
run_chunk <- function(project_dir, entrypoint, jobs, cores = 1L,
                      heartbeat = NULL, heartbeat_seconds = 60) {
  n <- nrow(jobs)
  if (n == 0L) return(list())

  # Rate-limited so that a chunk of ten thousand fast jobs does not send ten
  # thousand renewals.
  last_beat <- unix_time()
  beat <- function() {
    if (is.null(heartbeat)) return(invisible(NULL))
    if (unix_time() - last_beat < heartbeat_seconds) return(invisible(NULL))
    last_beat <<- unix_time()
    heartbeat()
  }

  # mirai is Suggested. Degrade rather than fail: a machine without it can
  # still contribute, just one job at a time. [jobr_join()] checks this once at
  # join time so the warning is not repeated for every chunk.
  if (cores > 1L && !requireNamespace("mirai", quietly = TRUE)) {
    warning("'mirai' is not installed; running this chunk serially instead of ",
            "on ", cores, " cores", call. = FALSE)
    cores <- 1L
  }

  if (cores <= 1L) {
    runner <- load_entrypoint_cached(project_dir, entrypoint)
    # Between jobs is the only point a serial worker is free to talk to the
    # host. A single job longer than the lease is therefore still beyond reach;
    # that is a limit of the chunk size chosen, not of the heartbeat.
    return(lapply(seq_len(n), function(i) {
      out <- runner(jobs[i, , drop = FALSE])
      beat()
      out
    }))
  }

  # Within a worker, mirai parallelises across that machine's own cores. The
  # division of labour is deliberate: jobR moves work between machines, mirai
  # moves it between cores.
  mirai::daemons(as.integer(cores), .compute = "jobr_local")
  on.exit(mirai::daemons(0L, .compute = "jobr_local"), add = TRUE)

  # `.args` supplies constants. mirai_map's `...` would instead iterate over
  # them in parallel with `.x`, the way Map() does -- passing the project there
  # silently maps over its characters rather than handing it to every call.
  m <- mirai::mirai_map(
    seq_len(n),
    function(i, .pd, .ep, .jobs, .load, .rng) {
      # mirai gives its daemons L'Ecuyer-CMRG, which is the right default for
      # drawing independent parallel streams. jobR's contract is the opposite:
      # a job carries its own seed and must produce the same answer wherever it
      # runs. Under a different generator set.seed(42) yields a different
      # stream, so the same job would give different numbers depending on how
      # many cores the worker happened to use. Match the worker's generator.
      if (!identical(RNGkind(), .rng)) {
        suppressWarnings(do.call(RNGkind, as.list(.rng)))
      }
      # Cached in the daemon's global environment: sourcing a project may be
      # expensive -- it can load data or fit a model -- and a daemon handles
      # many jobs, so doing it once per daemon rather than once per job matters.
      #
      # R CMD check flags this as an assignment to the global environment. It
      # is a false positive: this function body is evaluated inside a mirai
      # daemon, a separate process with its own global environment, and never
      # in the user's session. Static analysis cannot see the process boundary.
      runner <- get0(".jobr_runner", envir = globalenv(), ifnotfound = NULL)
      if (is.null(runner)) {
        runner <- .load(.pd, .ep)
        assign(".jobr_runner", runner, envir = globalenv())
      }
      runner(.jobs[i, , drop = FALSE])
    },
    # load_entrypoint is passed rather than called as jobR::load_entrypoint so
    # that daemons need not resolve the jobR namespace, and so there is only
    # one definition of how a project is loaded. It uses nothing but base
    # functions, so losing its closure environment in transit costs nothing.
    .args = list(.pd = normalizePath(project_dir), .ep = entrypoint,
                 .jobs = jobs, .load = load_entrypoint, .rng = RNGkind()),
    .compute = "jobr_local"
  )

  # Collecting with m[] would block until the whole chunk finished, leaving no
  # opportunity to renew. Poll instead, and beat while waiting.
  if (!is.null(heartbeat)) {
    repeat {
      if (!any(as.logical(mirai::unresolved(m)))) break
      Sys.sleep(min(1, heartbeat_seconds / 4))
      beat()
    }
  }
  results <- m[]

  # mirai reports a failed task by RETURNING an errorValue, not by throwing.
  # Left unchecked these are submitted to the host as though they were results:
  # the ledger marks every chunk complete and the jobset finishes full of
  # errors. Turn them back into an R error so the chunk is failed and reissued.
  bad <- vapply(results, function(x) inherits(x, "errorValue"), logical(1))
  if (any(bad)) {
    stop(sum(bad), " of ", n, " jobs in this chunk failed. First failure: ",
         chunk_error_text(results[[which(bad)[1]]]), call. = FALSE)
  }
  results
}

# miraiError carries its message as a character vector rather than as a
# condition message, so neither accessor alone covers both cases.
chunk_error_text <- function(x) {
  msg <- tryCatch(conditionMessage(x), error = function(e) NULL)
  if (is.null(msg) || !length(msg)) msg <- as.character(x)
  trimws(paste(msg, collapse = " "))
}

# Sourcing a project is not free -- it may load data or fit something -- so the
# serial path caches per project, mirroring the per-daemon cache above.
.runner_cache <- new.env(parent = emptyenv())

load_entrypoint_cached <- function(project_dir, entrypoint) {
  key <- paste(project_dir, entrypoint, sep = "|")
  runner <- get0(key, envir = .runner_cache, ifnotfound = NULL)
  if (is.null(runner)) {
    runner <- load_entrypoint(project_dir, entrypoint)
    assign(key, runner, envir = .runner_cache)
  }
  runner
}

#' Fetch a host's package repository and install from it
#'
#' Reassembles the host's repository locally, transferring only the files this
#' machine does not already have, then installs with `repos = "file:///..."` so
#' R's own resolution and version checking apply rather than anything invented
#' here.
#'
#' @param call A function taking a request list and returning the host's reply,
#'   as [jobr_join()] uses internally.
#' @param packages Packages still needed.
#' @param dir Where to assemble the local copy. Kept between joins, so a second
#'   visit transfers nothing.
#' @param token The session token from enrolment; the repository operations are
#'   authenticated like every other one.
#' @param lib Library to install into.
#' @param quiet Suppress progress.
#'
#' @return The packages still missing afterwards.
#' @export
repo_pull_install <- function(call, packages, dir, token = NULL,
                              lib = .libPaths()[1], quiet = FALSE) {
  reply <- call(list(op = "repo_manifest", token = token))
  if (is.null(reply) || !isTRUE(reply$ok) || !NROW(reply$manifest)) {
    return(packages)
  }
  plan <- repo_sync_plan(reply$manifest, dir)
  if (nrow(plan) && !quiet) {
    message("  fetching ", nrow(plan), " file(s), ",
            format(round(sum(plan$size) / 1024^2, 1), nsmall = 1), " MB")
  }
  for (i in seq_len(nrow(plan))) {
    got <- call(list(op = "repo_file", token = token, path = plan$path[i]))
    if (is.null(got) || !isTRUE(got$ok)) {
      stop("host refused ", plan$path[i], ": ",
           if (is.null(got)) "no reply" else got$error, call. = FALSE)
    }
    target <- file.path(dir, plan$path[i])
    dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
    writeBin(got$data, target)
    # Verified on arrival. A truncated package would otherwise fail later, deep
    # inside install.packages, with a far less obvious message.
    if (!identical(digest::digest(file = target, algo = "sha256"),
                   plan$sha256[i])) {
      unlink(target)
      stop("checksum mismatch on ", plan$path[i], call. = FALSE)
    }
  }
  repo_install(packages, dir, lib = lib, quiet = quiet)
}
