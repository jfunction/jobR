#' @title Append-only work ledger
#' @description
#' The ledger is the durable record of what work exists, what has been handed
#' out, and what has come back. It is the one piece of jobR that must survive a
#' crash, a power cut, or the host process being restarted, so it is kept as a
#' plain append-only TSV file rather than a database: appends are cheap, replay
#' is total, and a human debugging over a bad link can read it with `cat`.
#'
#' Only the host writes to a ledger, so no locking is required.
#'
#' Work is tracked by *lease*, not merely by "sent" and "received". A bare
#' sent/received pair cannot distinguish a worker that is still busy from one
#' whose laptop lid closed twenty minutes ago. An assignment therefore carries
#' an expiry; a worker renews it while it makes progress, and a chunk whose
#' lease has lapsed becomes claimable again by anyone.
#'
#' @name ledger
NULL

LEDGER_COLS <- c("seq", "t", "type", "jobset", "chunk", "worker", "lease")

# Event types written to the log. Anything else is rejected on append so a
# typo cannot silently create a class of event that replay ignores.
LEDGER_TYPES <- c("assign", "renew", "complete", "fail")

#' Open (or create) a ledger
#'
#' @param path Path to the ledger file. Created if absent.
#'
#' @return A `jobr_ledger` object: a list of the path and the replayed state.
#' @export
ledger_open <- function(path) {
  if (!file.exists(path)) {
    dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
    writeLines(paste(LEDGER_COLS, collapse = "\t"), path)
  }
  structure(list(path = path, events = ledger_replay(path)), class = "jobr_ledger")
}

#' Replay a ledger file into a data frame of events
#'
#' @param path Path to the ledger file.
#'
#' @return A data frame with one row per event, in the order written.
#' @export
ledger_replay <- function(path) {
  if (!file.exists(path)) {
    return(empty_events())
  }
  lines <- readLines(path, warn = FALSE)
  lines <- lines[nzchar(lines)]
  if (length(lines) <= 1L) {
    return(empty_events())
  }
  # A partially written final line is possible if the host died mid-append.
  # Drop it rather than failing: the whole point of the log is to survive that.
  parts <- strsplit(lines[-1L], "\t", fixed = TRUE)
  ok <- vapply(parts, length, integer(1)) == length(LEDGER_COLS)
  parts <- parts[ok]
  if (!length(parts)) {
    return(empty_events())
  }
  m <- do.call(rbind, parts)
  data.frame(
    seq    = as.integer(m[, 1]),
    t      = as.numeric(m[, 2]),
    type   = m[, 3],
    jobset = m[, 4],
    chunk  = as.integer(m[, 5]),
    worker = m[, 6],
    lease  = as.numeric(m[, 7]),
    stringsAsFactors = FALSE
  )
}

empty_events <- function() {
  data.frame(
    seq = integer(), t = numeric(), type = character(), jobset = character(),
    chunk = integer(), worker = character(), lease = numeric(),
    stringsAsFactors = FALSE
  )
}

#' Append an event to a ledger
#'
#' @param led A `jobr_ledger`.
#' @param type One of `"assign"`, `"renew"`, `"complete"`, `"fail"`.
#' @param jobset Jobset identifier.
#' @param chunk Integer chunk index.
#' @param worker Worker identifier.
#' @param lease Absolute expiry time (seconds since epoch). Ignored for
#'   `"complete"` and `"fail"`.
#' @param now Current time, injectable so tests need not sleep.
#'
#' @return The updated ledger, invisibly.
#' @export
ledger_append <- function(led, type, jobset, chunk, worker = "",
                          lease = 0, now = unix_time()) {
  if (!type %in% LEDGER_TYPES) {
    stop("unknown ledger event type: ", type, call. = FALSE)
  }
  seq <- nrow(led$events) + 1L
  row <- data.frame(
    seq = seq, t = now, type = type, jobset = jobset, chunk = as.integer(chunk),
    worker = worker, lease = lease, stringsAsFactors = FALSE
  )
  ledger_write_line(led$path,
                    paste(paste(format_field(row), collapse = "\t"), "\n", sep = ""))
  # Only after the write succeeds. If it could not be persisted, the in-memory
  # view must not claim it was, or a restarted host would disagree with its own
  # ledger about what happened.
  led$events <- rbind(led$events, row)
  invisible(led)
}

# Appending can fail transiently on Windows, where antivirus and search
# indexers briefly hold a file open after it is written: the open returns
# "Permission denied" for a file that plainly exists and is writable a moment
# later. The ledger is the one thing that has to survive, and losing an event
# to a scanner would be a silent correctness bug, so retry briefly before
# giving up. A genuine permissions problem still surfaces, just a little later.
ledger_write_line <- function(path, line, attempts = 6L) {
  for (i in seq_len(attempts)) {
    ok <- tryCatch({
      con <- file(path, open = "a")
      on.exit(close(con), add = TRUE)
      writeLines(line, con, sep = "")
      TRUE
    }, error = function(e) FALSE, warning = function(w) FALSE)
    if (ok) return(invisible(TRUE))
    if (i < attempts) Sys.sleep(0.02 * i)
  }
  stop("could not append to the ledger at ", path,
       " after ", attempts, " attempts", call. = FALSE)
}

format_field <- function(row) {
  c(row$seq, sprintf("%.3f", row$t), row$type, row$jobset,
    row$chunk, row$worker, sprintf("%.3f", row$lease))
}

#' Plan chunk boundaries for a jobset
#'
#' Splits `n_jobs` rows into chunks of at most `chunksize`. The final chunk is
#' short when the division is not exact; it is never dropped.
#'
#' @param n_jobs Number of jobs in the jobset.
#' @param chunksize Maximum jobs per chunk.
#'
#' @return A data frame of `chunk`, `start`, `end` (inclusive, 1-based).
#' @export
chunk_plan <- function(n_jobs, chunksize) {
  n_jobs <- as.integer(n_jobs)
  chunksize <- as.integer(chunksize)
  if (is.na(n_jobs) || n_jobs < 0L) stop("n_jobs must be a non-negative integer", call. = FALSE)
  if (is.na(chunksize) || chunksize < 1L) stop("chunksize must be a positive integer", call. = FALSE)
  if (n_jobs == 0L) {
    return(data.frame(chunk = integer(), start = integer(), end = integer()))
  }
  n_chunks <- as.integer(ceiling(n_jobs / chunksize))
  start <- (seq_len(n_chunks) - 1L) * chunksize + 1L
  data.frame(
    chunk = seq_len(n_chunks),
    start = start,
    end   = pmin(start + chunksize - 1L, n_jobs)
  )
}

#' Current state of every chunk in a jobset
#'
#' @param led A `jobr_ledger`.
#' @param jobset Jobset identifier.
#' @param n_chunks Total number of chunks in the jobset.
#' @param now Current time, injectable for tests.
#'
#' @return A data frame of `chunk`, `state` (`"done"`, `"leased"`, `"open"`),
#'   `worker`, and `lease`.
#' @export
chunk_state <- function(led, jobset, n_chunks, now = unix_time()) {
  ev <- led$events
  ev <- ev[ev$jobset == jobset, , drop = FALSE]

  state  <- rep("open", n_chunks)
  worker <- rep("", n_chunks)
  lease  <- rep(0, n_chunks)

  # Replay in order. Later events supersede earlier ones for a given chunk,
  # except that "done" is terminal: a duplicate result from a worker that was
  # presumed dead must not reopen a chunk that already completed.
  for (i in seq_len(nrow(ev))) {
    k <- ev$chunk[i]
    if (is.na(k) || k < 1L || k > n_chunks) next
    if (state[k] == "done") next
    switch(ev$type[i],
      assign = { state[k] <- "leased"; worker[k] <- ev$worker[i]; lease[k] <- ev$lease[i] },
      renew  = { if (state[k] == "leased") lease[k] <- ev$lease[i] },
      fail   = { state[k] <- "open"; worker[k] <- ""; lease[k] <- 0 },
      complete = { state[k] <- "done"; worker[k] <- ev$worker[i]; lease[k] <- 0 }
    )
  }

  # A lapsed lease is indistinguishable from an abandoned one, which is the
  # point: the work becomes claimable again without anyone reporting a failure.
  expired <- state == "leased" & lease <= now
  state[expired] <- "open"

  data.frame(
    chunk = seq_len(n_chunks), state = state, worker = worker, lease = lease,
    stringsAsFactors = FALSE
  )
}

#' Claim the next chunk of work
#'
#' Prefers chunks that have never been attempted, so that fresh work is always
#' started before anything is duplicated. Only once every chunk has been tried
#' does it reissue one whose lease has lapsed.
#'
#' @param led A `jobr_ledger`.
#' @param jobset Jobset identifier.
#' @param n_chunks Total number of chunks in the jobset.
#' @param worker Worker claiming the chunk.
#' @param lease_seconds How long the claim is good for.
#' @param now Current time, injectable for tests.
#'
#' @return A list of `chunk` and the updated `ledger`, or `NULL` for `chunk`
#'   when no work is available.
#' @export
claim_chunk <- function(led, jobset, n_chunks, worker,
                        lease_seconds = 300, now = unix_time()) {
  st <- chunk_state(led, jobset, n_chunks, now = now)
  open <- st$chunk[st$state == "open"]
  if (!length(open)) {
    return(list(chunk = NULL, ledger = led))
  }
  ever <- unique(led$events$chunk[led$events$jobset == jobset])
  unattempted <- setdiff(open, ever)
  chunk <- if (length(unattempted)) min(unattempted) else min(open)
  led <- ledger_append(led, "assign", jobset, chunk, worker,
                       lease = now + lease_seconds, now = now)
  list(chunk = chunk, ledger = led)
}

#' Is a jobset finished?
#'
#' @param led A `jobr_ledger`.
#' @param jobset Jobset identifier.
#' @param n_chunks Total number of chunks.
#' @param now Current time, injectable for tests.
#'
#' @return `TRUE` when every chunk has completed.
#' @export
jobset_complete <- function(led, jobset, n_chunks, now = unix_time()) {
  if (n_chunks == 0L) return(TRUE)
  all(chunk_state(led, jobset, n_chunks, now = now)$state == "done")
}

#' Summarise progress for a jobset
#'
#' @param led A `jobr_ledger`.
#' @param jobset Jobset identifier.
#' @param n_chunks Total number of chunks.
#' @param now Current time, injectable for tests.
#'
#' @return A named integer vector of chunk counts by state.
#' @export
ledger_progress <- function(led, jobset, n_chunks, now = unix_time()) {
  st <- chunk_state(led, jobset, n_chunks, now = now)
  c(done   = sum(st$state == "done"),
    leased = sum(st$state == "leased"),
    open   = sum(st$state == "open"))
}

unix_time <- function() as.numeric(Sys.time())
