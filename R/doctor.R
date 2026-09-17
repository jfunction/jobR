#' @title Preflight checks
#' @description
#' Getting two machines talking is where most of the friction is, and almost
#' all of it is one of three things: listening on loopback instead of the LAN,
#' a host firewall silently dropping the inbound connection, or typing the
#' wrong address. These helpers check all three before you ask anyone else to
#' join.
#'
#' @name doctor
NULL

#' LAN addresses this machine can be reached on
#'
#' @return A character vector of IPv4 addresses, loopback and link-local
#'   removed. Empty if none could be determined.
#' @export
#'
#' @examples
#' # Shells out to the platform's networking tool, so the output is specific to
#' # the machine it runs on and it is not executed during R CMD check.
#' \dontrun{
#' jobr_lan_address()
#' }
jobr_lan_address <- function() {
  raw <- NULL
  # stderr is merged into stdout rather than discarded. Asking to discard it
  # makes R build a shell redirect to the null device, which on Windows under
  # R CMD check leaves a stray file literally named 'NULL' in the working
  # directory. Merging avoids the redirect entirely, and stderr noise is
  # harmless here because only IPv4-shaped text survives the filter below.
  for (cmd in list(list("ip", c("-4", "addr")), list("ifconfig", character()),
                   list("ipconfig", character()))) {
    if (nzchar(Sys.which(cmd[[1]]))) {
      raw <- tryCatch(system2(cmd[[1]], cmd[[2]], stdout = TRUE, stderr = TRUE),
                      error = function(e) NULL, warning = function(w) NULL)
      if (length(raw)) break
    }
  }
  if (!length(raw)) return(character())

  hits <- regmatches(raw, gregexpr("\\b(\\d{1,3}\\.){3}\\d{1,3}\\b", raw))
  ips <- unique(unlist(hits))
  ips <- ips[vapply(strsplit(ips, ".", fixed = TRUE),
                    function(p) all(as.integer(p) <= 255), logical(1))]
  # Loopback is not reachable from another machine; 169.254.x.x means DHCP
  # failed and is not either. 255.x and 0.x are masks and placeholders.
  ips <- ips[!grepl("^(127\\.|169\\.254\\.|255\\.|0\\.)", ips)]
  ips[!endsWith(ips, ".255")]
}

#' Check this machine is ready to host
#'
#' Reports the addresses workers should dial, confirms the port can actually be
#' bound, and prints the exact line to run on the other machine.
#'
#' @param port Port to test.
#' @param quiet Suppress the report and just return the findings.
#'
#' @return A list of `addresses`, `port_free` and `problems`, invisibly.
#' @export
jobr_doctor <- function(port = 5555, quiet = FALSE) {
  problems <- character()
  note <- function(...) problems <<- c(problems, paste0(...))

  addrs <- jobr_lan_address()
  if (!length(addrs)) {
    note("could not determine a LAN address; find it manually (ipconfig on ",
         "Windows, `ip -4 addr` on Linux, `ifconfig` on macOS)")
  }

  # Bind 0.0.0.0, not a specific address: that is what a host must do to accept
  # connections from other machines, so it is what is worth testing.
  url <- sprintf("tcp://0.0.0.0:%d", port)
  sock <- tryCatch(nanonext::socket("rep", listen = url), error = function(e) e)
  port_free <- !inherits(sock, "error")
  if (port_free) close(sock) else note("port ", port, " could not be bound: ",
                                       conditionMessage(sock))

  for (p in c("nanonext", "digest", "zip")) {
    if (!nzchar(system.file(package = p))) note("required package not installed: ", p)
  }

  if (!quiet) {
    message("jobR preflight")
    message("  listen on : ", url, "   <- note 0.0.0.0, not 127.0.0.1")
    message("  port ", port, "  : ", if (port_free) "free" else "NOT BINDABLE")
    if (length(addrs)) {
      message("  reachable at:")
      for (a in addrs) message("    tcp://", a, ":", port)
      message("")
      message("  on the other machine, after installing jobR:")
      message("    jobR::jobr_join(\"tcp://", addrs[1], ":", port,
              "\", \"<passphrase>\")")
    }
    if (.Platform$OS.type == "windows") {
      message("")
      message("  Windows Firewall blocks inbound connections by default and")
      message("  fails silently -- the worker simply never connects. Allow the")
      message("  port once, from an ADMIN PowerShell:")
      message("    New-NetFirewallRule -DisplayName 'jobR' -Direction Inbound ",
              "-Protocol TCP -LocalPort ", port, " -Action Allow -Profile Private")
      message("  and remove it afterwards with:")
      message("    Remove-NetFirewallRule -DisplayName 'jobR'")
    }
    if (length(problems)) {
      message("")
      message("  problems:")
      for (p in problems) message("    - ", p)
    }
  }

  invisible(list(addresses = addrs, port_free = port_free, problems = problems))
}

#' Check a worker can reach a host
#'
#' Run this on the second machine before `jobr_join()` to separate "the network
#' is blocked" from "the passphrase is wrong".
#'
#' @param url Host URL to test.
#' @param passphrase Optional; if given, enrolment is attempted too.
#' @param timeout_ms How long to wait for a reply.
#' @param quiet Suppress the report.
#'
#' @return A list of `reachable` and `authenticated`, invisibly.
#' @export
jobr_ping <- function(url, passphrase = NULL, timeout_ms = 5000, quiet = FALSE) {
  sock <- tryCatch(nanonext::socket("req", dial = url), error = function(e) e)
  if (inherits(sock, "error")) {
    if (!quiet) message("cannot dial ", url, ": ", conditionMessage(sock))
    return(invisible(list(reachable = FALSE, authenticated = FALSE)))
  }
  on.exit(close(sock), add = TRUE)

  # An empty hello is enough to prove the far end is a jobR host: it replies
  # with a refusal rather than nothing at all.
  probe <- list(op = "hello", passphrase = if (is.null(passphrase)) "" else passphrase)
  sent <- nanonext::send(sock, probe, mode = "serial", block = timeout_ms)
  reply <- if (identical(as.integer(sent), 0L)) {
    nanonext::recv(sock, mode = "serial", block = timeout_ms)
  } else {
    structure(as.integer(sent), class = "errorValue")
  }

  reachable <- !inherits(reply, "errorValue")
  authed <- reachable && isTRUE(reply$ok)

  if (!quiet) {
    if (!reachable) {
      message("no reply from ", url)
      message("  the host may not be running, the address may be wrong, or a")
      message("  firewall on the HOST machine may be dropping the connection")
    } else if (authed) {
      message("connected to '", reply$project, "': ", reply$n_jobs, " jobs in ",
              reply$n_chunks, " chunks -- ready to join")
    } else {
      message("reached the host, but it refused: ", reply$error)
      message("  the network is fine; check the passphrase")
    }
  }
  invisible(list(reachable = reachable, authenticated = authed))
}
