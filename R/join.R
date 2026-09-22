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
#' @param reconnect_seconds How long to keep retrying a request that got no
#'   reply before concluding the host is really gone. A link that drops for a
#'   moment is the normal condition on the networks this package is for, and
#'   treating the first missed reply as the end of the run loses the machine
#'   and whatever chunk it was holding. Set to 0 to give up immediately.
#' @param max_chunk_seconds Stop renewing a chunk's lease once it has been
#'   running this long. Because the lease is now renewed while a job runs, a
#'   job that has hung looks exactly like one that is merely slow, and both
#'   hold their chunk indefinitely. This is the cap on that. The default never
#'   gives up, because only the person who wrote the jobs knows how long they
#'   ought to take.
#' @param spool_dir Where to keep results that could not be delivered, so that
#'   they survive this R session and are offered again on the next join. See
#'   [spool]. `NULL` disables spooling, and undelivered results are lost as
#'   soon as the worker stops.
#' @param spool_max_age Discard spooled results older than this, in seconds,
#'   checked when joining. A host that never comes back would otherwise leave
#'   them on disk indefinitely.
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
                      reconnect_seconds = 60, max_chunk_seconds = Inf,
                      # jobr_data_dir(), not spool_dir(): a default argument is
                      # evaluated in this function's own frame, where the name
                      # spool_dir is the promise being evaluated, and R stops
                      # with "recursive default argument reference".
                      spool_dir = jobr_data_dir("spool"),
                      spool_max_age = 7 * 24 * 3600,
                      use_host_packages = TRUE, quiet = FALSE) {
  sock <- nanonext::socket("req", dial = url, tls = tls)
  on.exit(close(sock), add = TRUE)
  started <- unix_time()
  why <- NULL

  # Set once the host has issued a token, and replaced if it ever issues
  # another. `reauthing` stops re-enrolment recursing: the hello that renews a
  # token is itself a call(), and a host that rejected it would otherwise send
  # us round again.
  token <- NULL
  reauthing <- FALSE

  # One exchange. Returns NULL if nothing came back, and records why.
  attempt <- function(req, block) {
    # The send result must be checked. A req socket that failed to send is not
    # entitled to receive, so recv'ing anyway reports "incorrect state" and
    # hides whatever actually went wrong.
    sent <- nanonext::send(sock, req, mode = "serial", block = block)
    if (!identical(as.integer(sent), 0L)) {
      why <<- paste0("could not send: ", nanonext::nng_error(sent))
      return(NULL)
    }
    reply <- nanonext::recv(sock, mode = "serial", block = block)
    if (inherits(reply, "errorValue")) {
      why <<- paste0("no reply: ", nanonext::nng_error(reply))
      return(NULL)
    }
    reply
  }

  # A timed-out exchange leaves a request outstanding in the req socket's state
  # machine, and the connection under it may be half dead: a partition does not
  # close a socket, it just stops delivering. A fresh socket is cheap and
  # leaves no state to reason about.
  redial <- function() {
    tryCatch(close(sock), error = function(e) NULL)
    sock <<- nanonext::socket("req", dial = url, tls = tls)
  }

  # Silence does not mean the host has gone. On an intermittent link it far
  # more often means a moment's outage, and a worker that stops at the first
  # missed reply loses the machine along with whatever chunk it was holding.
  #
  # Retrying is only sound because the host no longer goes silent for the one
  # innocent reason it used to: it stays up after the last chunk and tells
  # every worker the jobset is done (see linger_seconds in jobr_serve). With
  # that settled, silence means the link, so keep trying with backoff for a
  # bounded budget.
  #
  # `retry = FALSE` is for calls that must not block the work they protect:
  # the lease heartbeat, and handing a chunk back after a failure. Both are
  # advisory -- if they do not get through, the lease simply lapses, which is
  # exactly what it is for.
  # A host that has restarted has forgotten every token it ever issued --
  # host_new() starts with none -- so it answers a worker that was mid-jobset
  # with "not authenticated". That is not a credential problem: this worker
  # still holds the passphrase, and the honest response is to introduce itself
  # again rather than to stop. Without this, restarting a host silently
  # dismisses every worker attached to it, which on a machine that is meant to
  # run for weeks is the difference between a blip and an outage.
  reauth <- function() {
    if (reauthing) return(FALSE)
    reauthing <<- TRUE
    on.exit(reauthing <<- FALSE, add = TRUE)
    again <- call(list(op = "hello", passphrase = passphrase,
                       r_version = r_version_string()), fatal = FALSE)
    # A refusal here is real: the passphrase has changed, or this is a
    # different host altogether. Stopping is then correct.
    if (!isTRUE(again$ok)) return(FALSE)
    token <<- again$token
    if (!quiet) message("  the host restarted; re-enrolled and carrying on")
    TRUE
  }

  call <- function(req, fatal = TRUE, retry = TRUE, block = timeout_ms) {
    reply <- attempt(req, block)

    # An authenticated request refused for authentication alone is worth one
    # more try with a fresh token. Anything else the host says is its answer.
    if (!is.null(reply) && !isTRUE(reply$ok) && !is.null(req$token) &&
        identical(reply$error, "not authenticated") && reauth()) {
      req$token <- token
      again <- attempt(req, block)
      if (!is.null(again)) return(again)
    }

    if (!is.null(reply)) return(reply)
    redial()

    budget <- if (retry) reconnect_seconds else 0
    # Never keep trying past the worker's own deadline.
    give_up <- min(unix_time() + budget, started + max_seconds)

    if (budget > 0 && unix_time() < give_up) {
      if (!quiet) message("  lost contact with the host (", why,
                          "); retrying for up to ", round(budget), "s")
      pause <- 1
      repeat {
        left <- give_up - unix_time()
        if (left <= 0) break
        Sys.sleep(min(pause, left))
        reply <- attempt(req, block)
        if (!is.null(reply)) {
          if (!quiet) message("  back in touch with the host")
          return(reply)
        }
        redial()
        pause <- min(pause * 2, 8)
      }
    }

    if (fatal) stop("no reply from the host at ", url, ": ", why, call. = FALSE)
    NULL
  }

  hi <- call(list(op = "hello", passphrase = passphrase,
                  r_version = r_version_string()))
  if (!isTRUE(hi$ok)) stop("could not join: ", hi$error, call. = FALSE)
  token <- hi$token
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
                        token = token, quiet = quiet),
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

  # Anything this machine computed for this jobset but never managed to hand
  # over. Delivered before asking for new work: those results are CPU already
  # spent, and they are at risk until the host has them, whereas work not yet
  # claimed is at risk of nothing.
  drain_spool <- function() {
    if (is.null(spool_dir)) return(invisible(0L))
    have <- spool_list(hi$jobset, dir = spool_dir)
    if (!nrow(have)) return(invisible(0L))
    if (!quiet) message("delivering ", nrow(have), " chunk(s) held from an ",
                        "earlier session")
    sent <- 0L
    for (i in seq_len(nrow(have))) {
      entry <- spool_read(have$path[i])
      if (is.null(entry)) { spool_drop(have$path[i]); next }
      r <- call(list(op = "submit", token = token, chunk = entry$chunk,
                     results = entry$results), fatal = FALSE)
      # Only discard once the host has said it has them. A failed delivery
      # leaves the file exactly where it was for the next attempt.
      if (is.null(r) || !isTRUE(r$ok)) break
      spool_drop(have$path[i])
      sent <- sent + 1L
      if (!quiet) message("  chunk ", entry$chunk, " delivered late")
    }
    invisible(sent)
  }

  if (!is.null(spool_dir)) spool_expire(spool_max_age, dir = spool_dir)

  project_dir <- file.path(cache_dir, hi$project)
  if (bundle_stale(project_dir, hi$hash)) {
    if (!quiet) message("fetching project bundle...")
    b <- call(list(op = "bundle", token = token))
    zipfile <- tempfile(fileext = ".zip")
    writeBin(b$data, zipfile)
    unlink(project_dir, recursive = TRUE)
    bundle_unpack(zipfile, project_dir, expect_hash = hi$hash)
    bundle_stamp(project_dir, hi$hash)
    unlink(zipfile)
  } else if (!quiet) {
    message("project bundle already current, nothing to fetch")
  }

  # mirai is Suggested, not required, and its absence costs more than cores.
  # Jobs normally run in a daemon even on a single core, because that is what
  # keeps this process free to renew the lease while a job is running. Without
  # it the jobs run here, this process blocks inside run_job(), and a single
  # job longer than the lease cannot be renewed -- the chunk is reissued and
  # the work is done twice.
  #
  # Discovering that at the point of running a chunk is far too late: the chunk
  # fails, is handed back, claimed again, and fails identically forever. Check
  # once, here, and carry on regardless, because a worker that can only manage
  # short jobs is still a worker.
  if (!use_daemons()) {
    if (isTRUE(getOption("jobR.in_process", FALSE))) {
      if (!quiet) message("running jobs in this process by request; a single ",
                          "job longer than the lease cannot renew it")
    } else {
      message("the 'mirai' package is not installed on this machine.\n",
              "  Jobs will run one at a time in this process, and a single job ",
              "longer than the\n  host's lease cannot be renewed, so its chunk ",
              "may be reissued to someone else.\n",
              "  To fix both:  install.packages(\"mirai\")")
    }
    cores <- 1L
  } else {
    # Once per session rather than once per chunk. Spawning a daemon takes the
    # better part of a second, which is nothing against an hour-long job and a
    # great deal against a chunk of five short ones.
    if (isTRUE(daemons_ensure(cores))) {
      on.exit(mirai::daemons(0L, .compute = "jobr_local"), add = TRUE)
    }
  }

  # Loaded once here so a broken entrypoint fails at join rather than being
  # discovered chunk by chunk. run_chunk re-resolves it from the cache.
  load_entrypoint_cached(project_dir, hi$entrypoint)

  done <- 0L
  consecutive_failures <- 0L
  # Whether the host has already told us, in a reply we received, that the
  # jobset is finished. If it has, it has also stopped waiting for us, and
  # there is nothing left to say.
  told_done <- FALSE
  repeat {
    if (unix_time() - started > max_seconds) break
    if (done >= max_chunks) break
    drain_spool()
    cl <- call(list(op = "claim", token = token), fatal = FALSE)
    if (is.null(cl)) {
      if (!quiet) message("the host is still unreachable after ",
                          round(reconnect_seconds), "s, stopping")
      break
    }
    if (!isTRUE(cl$ok)) break
    if (is.null(cl$chunk)) {
      # No chunk free at this instant. That is not the same as no work left:
      # chunks may be leased to workers that will not come back, and those
      # leases lapse shortly. Exiting here would abandon exactly the work this
      # package exists to recover, so wait and ask again.
      if (isTRUE(cl$done)) { told_done <- TRUE; break }
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
      # No retry, and a short block. This runs between jobs inside the chunk,
      # so a heartbeat that waits out a dead link stalls the very work the
      # lease is protecting. If it does not get through, the lease lapses --
      # which is what a lease is for.
      r <- call(list(op = "renew", token = token, chunk = cl$chunk),
                fatal = FALSE, retry = FALSE,
                block = min(timeout_ms, 2000))
      # A refusal means the lease lapsed and the chunk now belongs to someone
      # else. Finishing it is wasted but harmless -- the submit will be a
      # duplicate, and completion is terminal -- so say so and carry on.
      if (!is.null(r) && !isTRUE(r$ok) && !quiet) {
        message("  lost the lease on chunk ", cl$chunk, ": ", r$error)
      }
      invisible(NULL)
    }

    out <- tryCatch(run_chunk(project_dir, hi$entrypoint, cl$jobs, cores = cores,
                              heartbeat = beat, heartbeat_seconds = every,
                              max_chunk_seconds = max_chunk_seconds),
                    error = function(e) e)
    if (inherits(out, "error")) {
      # Hand the chunk back rather than submitting a result that is really an
      # error. Someone else, or this worker on a later pass, can retry it.
      # Advisory: if it does not arrive, the lease lapses and the chunk is
      # reissued anyway. Not worth spending the reconnect budget on.
      call(list(op = "fail", token = token, chunk = cl$chunk),
           fatal = FALSE, retry = FALSE)
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
    # The one call worth spending the whole reconnect budget on: the work is
    # already done, and giving up here throws it away. A duplicate submit is
    # harmless -- completion is terminal in the ledger -- so resubmitting a
    # chunk that lapsed and was reissued costs nothing but the bytes.
    sub <- call(list(op = "submit", token = token, chunk = cl$chunk,
                     results = out), fatal = FALSE)
    if (is.null(sub)) {
      # The work is done and the only copy is in this process. Discarding it
      # here is what used to happen, and it meant a blink of the network cost
      # however long the chunk took to compute. Write it down instead; the
      # next loop, or the next session, delivers it.
      if (is.null(spool_dir)) {
        if (!quiet) message("could not deliver chunk ", cl$chunk,
                            " and spooling is off; it will be reissued")
        break
      }
      kept <- tryCatch({
        spool_write(hi$jobset, cl$chunk, out, dir = spool_dir)
        TRUE
      }, error = function(e) {
        if (!quiet) message("could not spool chunk ", cl$chunk, ": ",
                            conditionMessage(e))
        FALSE
      })
      if (!kept) break
      if (!quiet) message("could not deliver chunk ", cl$chunk,
                          " -- held on disk, will be offered again")
      done <- done + 1L
      next
    }
    done <- done + 1L

    # The submit reply already says whether that was the last chunk, and the
    # host stops once every worker has been told. Looping round to ask for more
    # would be answered by silence from a host that shut down for the best of
    # reasons, and the worker would spend its whole reconnect budget
    # establishing that the run had ended well.
    if (isTRUE(sub$done)) { told_done <- TRUE; break }
  }

  # Tell the host not to wait for this worker at the end of the jobset --
  # unless it has already said the jobset is over, in which case it has
  # stopped waiting for anyone and is very likely gone. Best effort and
  # deliberately cheap: if it does not arrive, the host's linger caps the wait.
  if (!told_done) {
    call(list(op = "bye", token = token), fatal = FALSE, retry = FALSE,
         block = min(timeout_ms, 2000))
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

#' Should jobs run in a daemon rather than in this process?
#'
#' Running them in a daemon is what lets a worker renew its lease while a
#' single job is still running: the worker process itself never executes user
#' code, so it is always free to talk to the host. The alternative, running
#' jobs inline, blocks the only thread there is, and a job longer than the
#' lease becomes unreachable.
#'
#' Set `options(jobR.in_process = TRUE)` to force jobs inline. That saves an R
#' process on a machine short of memory, and it is how the fallback path is
#' tested, but it reinstates the limit above.
#'
#' @return TRUE if mirai is available and in-process execution was not asked
#'   for.
#' @keywords internal
use_daemons <- function() {
  if (isTRUE(getOption("jobR.in_process", FALSE))) return(FALSE)
  requireNamespace("mirai", quietly = TRUE)
}

#' Make sure the jobR daemons exist
#'
#' @param n How many daemons are wanted.
#'
#' @return TRUE if this call started them, and the caller should therefore stop
#'   them; FALSE if they were already running. [jobr_join()] starts them once
#'   for a whole session rather than paying the spawn cost on every chunk, and
#'   this is how [run_chunk()] knows not to shut down someone else's.
#' @keywords internal
daemons_ensure <- function(n) {
  st <- tryCatch(mirai::status(.compute = "jobr_local"), error = function(e) NULL)
  live <- tryCatch(as.integer(st$connections)[1L], error = function(e) 0L)
  if (isTRUE(live > 0L)) return(FALSE)
  mirai::daemons(max(1L, as.integer(n)), .compute = "jobr_local")
  TRUE
}

#' Run one chunk of jobs
#'
#' Takes the project rather than a loaded function, because a `run_job` closure
#' cannot be sent to another process intact. mirai evaluates a mapped function
#' in a fresh environment, so a closure's enclosing environment does not travel
#' with it: `run_job` would arrive, but anything it was defined alongside --
#' every helper in every other file the manifest lists -- would not. Each daemon
#' therefore sources the project itself.
#'
#' Jobs run in a daemon even when `cores` is 1. That looks like waste and is
#' the entire point: see [use_daemons()].
#'
#' @param project_dir Unpacked project directory.
#' @param entrypoint Relative path to the entrypoint, from the manifest.
#' @param jobs A data frame of jobs.
#' @param cores Local cores to spread the chunk across. 1 still uses a daemon.
#' @param heartbeat Optional zero-argument function called periodically while
#'   the chunk runs, used by [jobr_join()] to renew its lease.
#' @param heartbeat_seconds How often, at most, to call `heartbeat`.
#' @param max_chunk_seconds Stop renewing once a chunk has been running this
#'   long. Renewing while a job runs makes a hung job indistinguishable from a
#'   slow one, and both keep the lease; this is the cap on that. The default
#'   never gives up, because only the person who wrote the jobs knows how long
#'   they ought to take.
#'
#' @return A list of per-row results, in row order.
#' @export
run_chunk <- function(project_dir, entrypoint, jobs, cores = 1L,
                      heartbeat = NULL, heartbeat_seconds = 60,
                      max_chunk_seconds = Inf) {
  n <- nrow(jobs)
  if (n == 0L) return(list())

  # Rate-limited so that a chunk of ten thousand fast jobs does not send ten
  # thousand renewals.
  started   <- unix_time()
  last_beat <- started
  beat <- function() {
    if (is.null(heartbeat)) return(invisible(NULL))
    if (unix_time() - last_beat < heartbeat_seconds) return(invisible(NULL))
    last_beat <<- unix_time()
    heartbeat()
  }

  if (!use_daemons()) {
    # No daemon, so the jobs run here and this process is blocked inside
    # run_job() for as long as they take. Between jobs is then the only moment
    # it can talk to the host, which puts a single job longer than the lease
    # out of reach -- the limitation daemons exist to remove. [jobr_join()]
    # states this once, at join time, rather than once per chunk.
    runner <- load_entrypoint_cached(project_dir, entrypoint)
    return(lapply(seq_len(n), function(i) {
      out <- runner(jobs[i, , drop = FALSE])
      beat()
      out
    }))
  }

  # Within a worker, mirai parallelises across that machine's own cores. The
  # division of labour is deliberate: jobR moves work between machines, mirai
  # moves it between cores.
  owned <- daemons_ensure(cores)
  if (isTRUE(owned)) {
    on.exit(mirai::daemons(0L, .compute = "jobr_local"), add = TRUE)
  }

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
  # opportunity to renew. Poll instead, and beat while waiting. This is the one
  # place a lease can be renewed *during* a job rather than between jobs, and
  # it works only because the job is running in another process.
  if (!is.null(heartbeat)) {
    repeat {
      if (!any(as.logical(mirai::unresolved(m)))) break
      if (unix_time() - started > max_chunk_seconds) {
        warning("this chunk has run for more than ", max_chunk_seconds,
                "s; no longer renewing its lease, so it may be reissued to ",
                "another worker. A duplicate result is harmless.", call. = FALSE)
        break
      }
      # A second is short enough that a finished chunk is submitted promptly,
      # and long enough that an hour-long job costs only a few thousand
      # wake-ups on a machine that may be running on battery.
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
