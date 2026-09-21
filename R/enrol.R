#' @title Enrolment credentials
#' @description
#' Two kinds of secret are in play, and they are deliberately different shapes.
#'
#' The *passphrase* is what one human gives another: a few words from the EFF
#' wordlist, readable over a phone line or a patchy voice call and typeable
#' without ambiguity. It is long-lived and identifies a host to the people
#' allowed to contribute to it.
#'
#' The *token* is what the software uses afterwards: opaque hex, issued in
#' exchange for a valid passphrase, held only for the life of a session, and
#' revocable without disturbing anybody else.
#'
#' All entropy is drawn locally via nanonext's CSPRNG. Nothing here contacts a
#' network service -- an earlier version of this package fetched entropy from
#' random.org, which meant a host could not generate its own credential without
#' working internet. That is precisely backwards for the deployments this
#' package targets.
#'
#' @name enrol
NULL

#' Generate a human-transferable passphrase
#'
#' @param n_words Number of words. Four words from the EFF long list carry
#'   roughly 51 bits, which is ample for a credential that is also rate-limited
#'   by a human typing it.
#'
#' @return A single dash-separated string.
#' @export
passphrase_new <- function(n_words = 4) {
  words <- passphrase_wordlist()
  idx <- random_below(length(words), n_words)
  paste(words[idx], collapse = "-")
}

#' Split a passphrase into its words
#'
#' @param phrase A dash-separated passphrase.
#'
#' @return A character vector of words, lowercased and trimmed.
#' @export
passphrase_words <- function(phrase) {
  tolower(trimws(unlist(strsplit(phrase, "-", fixed = TRUE))))
}

#' Compare two passphrases
#'
#' Tolerant of case and surrounding whitespace, because this string is going to
#' be read aloud and retyped. The comparison runs in time independent of how
#' many leading characters match.
#'
#' @param a,b Passphrases to compare.
#'
#' @return `TRUE` when they match.
#' @export
passphrase_equal <- function(a, b) {
  x <- passphrase_words(a)
  y <- passphrase_words(b)
  if (length(x) != length(y)) return(FALSE)
  constant_time_equal(paste(x, collapse = "-"), paste(y, collapse = "-"))
}

#' Generate an opaque session token
#'
#' @param bytes Number of random bytes.
#'
#' @return A hex string.
#' @export
token_new <- function(bytes = 16) nanonext::random(bytes)

#' Generate a short identifier
#'
#' @param bytes Number of random bytes.
#'
#' @return A hex string.
#' @export
id_new <- function(bytes = 5) nanonext::random(bytes)

#' Compare two strings without leaking match length through timing
#'
#' @param a,b Strings to compare.
#'
#' @return `TRUE` when identical.
#' @export
constant_time_equal <- function(a, b) {
  ca <- charToRaw(as.character(a))
  cb <- charToRaw(as.character(b))
  if (length(ca) != length(cb)) return(FALSE)
  if (!length(ca)) return(TRUE)
  sum(as.integer(xor(ca, cb))) == 0L
}

#' Uniform random integers in `1:n`, without modulo bias
#'
#' @param n Upper bound, inclusive.
#' @param count How many to draw.
#'
#' @return An integer vector of length `count`.
#' @keywords internal
random_below <- function(n, count = 1L) {
  out <- integer(0)
  limit <- floor(2^32 / n) * n          # reject above this to keep it uniform
  while (length(out) < count) {
    # nanonext::random() accepts at most 1024 bytes per call, so draw in
    # batches of 256 four-byte words rather than asking for everything at once.
    raw <- nanonext::random(1024L, convert = FALSE)
    vals <- vapply(seq_len(256L), function(i) {
      b <- as.integer(raw[((i - 1L) * 4L + 1L):(i * 4L)])
      b[1] * 16777216 + b[2] * 65536 + b[3] * 256 + b[4]
    }, numeric(1))
    vals <- vals[vals < limit]
    out <- c(out, as.integer(vals %% n) + 1L)
  }
  out[seq_len(count)]
}

#' The passphrase wordlist
#'
#' @return A character vector of candidate words.
#' @keywords internal
passphrase_wordlist <- function() {
  # Resolved leniently so the package works both installed and merely sourced,
  # which matters for the integration tests that run it out of a checkout.
  wl <- tryCatch(
    get0("passphraseWords", envir = asNamespace("jobR"), ifnotfound = NULL),
    error = function(e) NULL
  )
  if (is.null(wl)) wl <- get0("passphraseWords", envir = globalenv(), ifnotfound = NULL)
  if (is.null(wl)) stop("passphrase wordlist unavailable", call. = FALSE)
  words <- unique(wl$word)

  # Four of the EFF words contain a hyphen: drop-down, felt-tip, t-shirt and
  # yo-yo. A passphrase is itself hyphen-separated, so drawing one makes the
  # separator ambiguous -- a four-word passphrase reads as five, and splitting
  # it does not round-trip. That matters precisely because this credential is
  # meant to be read aloud. Dropping them costs 4 words out of 7776, which is
  # 0.0007 of a bit.
  words[grepl("^[a-z]+$", words)]
}
