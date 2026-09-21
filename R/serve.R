#' @title Host side
#' @description
#' The host owns the jobs, the bundle and the ledger, and hands chunks out to
#' whoever authenticates. It is deliberately a plain request/reply loop: one
#' request at a time, no threads, no shared mutable state beyond the ledger.
#' Claims and submissions are small and quick, so serialising them costs almost
#' nothing and buys a server whose behaviour can be reasoned about completely.
#'
#' The request handler is kept separate from the socket loop so that nearly all
#' of the host's behaviour -- authentication, leasing, duplicate submission,
#' completion -- is testable as ordinary function calls with no network in
#' sight. Only [jobr_serve()] touches a socket.
#'
#' @name serve
NULL

#' Create host state
#'
#' @param project_dir Directory containing `jobR.dcf` and the project source.
#' @param jobs A data frame; each row is one job.
#' @param chunksize Jobs handed out per claim.
#' @param passphrase Enrolment credential. Generated if not supplied.
#' @param work_dir Where the ledger, bundle and results are kept.
#' @param lease_seconds How long a claim is valid before it may be reissued.
#' @param jobset Identifier for this batch of work.
#'
#' @return A `jobr_host` environment.
#' @export
host_new <- function(project_dir, jobs, chunksize = 25,
                     passphrase = passphrase_new(),
                     work_dir = file.path(tempdir(), "jobr-host"),
                     lease_seconds = 300,
                     jobset = id_new()) {
  stopifnot(is.data.frame(jobs))
  dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)

  bundle <- bundle_create(project_dir, out = file.path(work_dir, "bundle.zip"))
  plan <- chunk_plan(nrow(jobs), chunksize)
  results_dir <- file.path(work_dir, "results", jobset)
  dir.create(results_dir, recursive = TRUE, showWarnings = FALSE)

  state <- new.env(parent = emptyenv())
  state$jobs          <- jobs
  state$plan          <- plan
  state$n_chunks      <- nrow(plan)
  state$jobset        <- jobset
  state$bundle        <- bundle
  state$passphrase    <- passphrase
  state$tokens        <- character()
  state$workers       <- character()
  state$lease_seconds <- lease_seconds
  state$work_dir      <- work_dir
  state$results_dir   <- results_dir
  state$ledger        <- ledger_open(file.path(work_dir, "ledger.tsv"))
  class(state) <- "jobr_host"

  # Any lease still outstanding at startup belongs to a worker that was talking
  # to a previous host process. That socket died when the host did, so the lease
  # can never be renewed and the worker can never submit against it. Expiring
  # them now means a restarted host resumes immediately instead of waiting out
  # a lease nobody is holding.
  stale <- chunk_state(state$ledger, state$jobset, state$n_chunks)
  for (k in stale$chunk[stale$state == "leased"]) {
    state$ledger <- ledger_append(state$ledger, "fail", state$jobset, k,
                                  "host-restart")
  }
  state
}

#' Handle one protocol request
#'
#' Pure with respect to the network: takes a request list, mutates host state,
#' returns a reply list.
#'
#' @param state A `jobr_host`.
#' @param req A request list with at least `op`.
#' @param now Current time, injectable for tests.
#'
#' @return A reply list, always containing `ok`.
#' @export
handle_request <- function(state, req, now = unix_time()) {
  if (!is.list(req) || is.null(req$op)) {
    return(list(ok = FALSE, error = "malformed request"))
  }

  # Enrolment is the only unauthenticated operation.
  if (identical(req$op, "hello")) {
    if (is.null(req$passphrase) || !passphrase_equal(req$passphrase, state$passphrase)) {
      return(list(ok = FALSE, error = "bad passphrase"))
    }
    token <- token_new()
    state$tokens <- c(state$tokens, token)
    # Record what each worker is running. A mixed fleet is normal and usually
    # fine, but when results come back looking odd the first question is always
    # "what R is that machine on", and the answer should already be to hand.
    if (!is.null(req$r_version)) {
      state$workers <- c(state$workers,
                         stats::setNames(req$r_version, substr(token, 1, 8)))
    }
    return(list(
      ok = TRUE, token = token, jobset = state$jobset,
      project = state$bundle$manifest$project,
      entrypoint = state$bundle$manifest$entrypoint,
      hash = state$bundle$hash, packages = state$bundle$packages,
      n_chunks = state$n_chunks, n_jobs = nrow(state$jobs),
      host_r_version = r_version_string()
    ))
  }

  if (is.null(req$token) || !any(vapply(state$tokens, constant_time_equal,
                                        logical(1), req$token))) {
    return(list(ok = FALSE, error = "not authenticated"))
  }
  worker <- substr(req$token, 1, 8)

  switch(req$op,
    bundle = list(
      ok = TRUE, hash = state$bundle$hash,
      data = readBin(state$bundle$path, "raw",
                     n = file.info(state$bundle$path)$size)
    ),

    claim = {
      res <- claim_chunk(state$ledger, state$jobset, state$n_chunks, worker,
                         lease_seconds = state$lease_seconds, now = now)
      state$ledger <- res$ledger
      if (is.null(res$chunk)) {
        list(ok = TRUE, chunk = NULL,
             done = jobset_complete(state$ledger, state$jobset, state$n_chunks, now))
      } else {
        rows <- state$plan[res$chunk, ]
        list(ok = TRUE, chunk = res$chunk,
             jobs = state$jobs[rows$start:rows$end, , drop = FALSE],
             lease_seconds = state$lease_seconds)
      }
    },

    submit = {
      if (is.null(req$chunk)) {
        list(ok = FALSE, error = "submit needs a chunk")
      } else {
        # Written before the ledger records completion. If the host dies
        # between the two, replay reissues the chunk and the result is simply
        # overwritten with an identical one -- harmless. The reverse order
        # would lose results.
        saveRDS(req$results,
                file.path(state$results_dir, sprintf("%06d.rds", req$chunk)))
        state$ledger <- ledger_append(state$ledger, "complete", state$jobset,
                                      req$chunk, worker, now = now)
        list(ok = TRUE,
             done = jobset_complete(state$ledger, state$jobset, state$n_chunks, now))
      }
    },

    renew = {
      state$ledger <- ledger_append(state$ledger, "renew", state$jobset,
                                    req$chunk, worker,
                                    lease = now + state$lease_seconds, now = now)
      list(ok = TRUE)
    },

    fail = {
      state$ledger <- ledger_append(state$ledger, "fail", state$jobset,
                                    req$chunk, worker, now = now)
      list(ok = TRUE)
    },

    status = list(
      ok = TRUE, jobset = state$jobset, n_chunks = state$n_chunks,
      workers = state$workers,
      progress = as.list(ledger_progress(state$ledger, state$jobset,
                                         state$n_chunks, now)),
      done = jobset_complete(state$ledger, state$jobset, state$n_chunks, now)
    ),

    list(ok = FALSE, error = paste0("unknown op: ", req$op))
  )
}

#' Serve jobs until the jobset is complete
#'
#' @param state A `jobr_host` from [host_new()].
#' @param url URL to listen on, e.g. `"tcp://0.0.0.0:5555"`.
#' @param tls Optional `tlsConfig` from [host_credentials()].
#' @param timeout_ms How long to block waiting for each request.
#' @param max_seconds Stop after this long regardless of progress.
#' @param ready_file Optional path written once the socket is actually bound,
#'   and removed on exit. Supervisors and tests need an observable readiness
#'   signal: dialling cannot provide one, because nanonext connects
#'   asynchronously and a dial to an address with nothing behind it succeeds
#'   just as readily as a dial to a live host.
#' @param quiet Suppress progress output.
#'
#' @return The host state, invisibly.
#' @export
jobr_serve <- function(state, url, tls = NULL, timeout_ms = 1000,
                       max_seconds = Inf, ready_file = NULL, quiet = FALSE) {
  sock <- nanonext::socket("rep", listen = url, tls = tls)
  on.exit(close(sock), add = TRUE)
  started <- unix_time()

  # Readiness has to be observable from outside the process. A dial cannot tell
  # you: nanonext connects asynchronously, so dialling an address with nothing
  # behind it succeeds just as readily as dialling a live host. Supervisors and
  # tests need a signal that only appears once the socket is actually bound.
  if (!is.null(ready_file)) {
    dir.create(dirname(ready_file), recursive = TRUE, showWarnings = FALSE)
    writeLines(url, ready_file)
    on.exit(unlink(ready_file), add = TRUE)
  }

  if (!quiet) {
    message("jobR host listening on ", url)
    message("  project   : ", state$bundle$manifest$project)
    message("  jobs      : ", nrow(state$jobs), " in ", state$n_chunks, " chunks")
    message("  passphrase: ", state$passphrase)
  }

  repeat {
    if (unix_time() - started > max_seconds) break
    req <- nanonext::recv(sock, mode = "serial", block = timeout_ms)
    if (inherits(req, "errorValue")) next          # timeout: loop and re-check
    reply <- tryCatch(handle_request(state, req),
                      error = function(e) list(ok = FALSE, error = conditionMessage(e)))
    nanonext::send(sock, reply, mode = "serial", block = timeout_ms)

    if (!quiet && identical(req$op, "submit")) {
      p <- ledger_progress(state$ledger, state$jobset, state$n_chunks)
      message(sprintf("  %d/%d chunks done", p[["done"]], state$n_chunks))
    }
    if (jobset_complete(state$ledger, state$jobset, state$n_chunks)) break
  }
  invisible(state)
}

#' Collect completed results in chunk order
#'
#' @param state A `jobr_host`.
#'
#' @return A list of per-chunk results, ordered by chunk index.
#' @export
host_results <- function(state) {
  files <- sort(list.files(state$results_dir, pattern = "\\.rds$", full.names = TRUE))
  lapply(files, readRDS)
}

#' Generate TLS credentials for a host
#'
#' Provides encryption and lets a worker confirm it is talking to the host it
#' expects. It does *not* authenticate the worker -- that is what the
#' passphrase is for. See `vignette("security")` for why.
#'
#' @param cn Common name; the address workers will dial.
#'
#' @return A list of `server` (for [jobr_serve()]) and `client` (to hand out).
#' @export
host_credentials <- function(cn = "127.0.0.1") {
  cert <- nanonext::write_cert(cn = cn)
  list(server = nanonext::tls_config(server = cert$server),
       client = cert$client[1],
       ca     = cert$client)
}
