# jobR 0.2.0

First substantial release. The package was rebuilt from the 2022 prototype onto
nanonext, and this entry describes what it does rather than what changed, since
nothing was released before it.

## What it does

* A **host** holds a set of jobs and the project that performs them, and serves
  both over a single nanonext socket. A **worker** joins with a spoken
  passphrase, fetches the project once, and pulls chunks until the work is done.
* Work is **leased rather than sent**. A chunk whose lease lapses becomes
  claimable by anyone, so a closed lid or a power cut costs at most one chunk.
  Completion is terminal, so a worker presumed dead that reports in late cannot
  reopen finished work.
* The project bundle is **content addressed**. A returning worker transfers
  nothing unless the project actually changed.
* A worker **refuses to start** if it is missing a package the project declares,
  rather than accepting work and failing every chunk.

## Working over unreliable networks

* Leases are renewed while a chunk runs, including during a **single job longer
  than the lease**: jobs run in a mirai daemon even on one core, so the worker
  process stays free to talk to the host. `max_chunk_seconds` bounds this for a
  job that has hung rather than merely taken a long time.
* A worker **reconnects** rather than treating one unanswered request as proof
  the host has gone, retrying with backoff for `reconnect_seconds`, and
  **enrols again** if the host restarted and has forgotten the tokens it issued.
* The host **stays up briefly** after the last chunk so that workers learn the
  jobset finished instead of inferring it from silence.
* Results that cannot be delivered are **kept on disk** rather than discarded,
  survive the R session ending, and are handed over before the worker claims
  anything new. `jobr_spool()` shows what a machine is holding;
  `jobr_spool_clear()` discards it, and `spool_max_age` does so on its own once
  a host has plainly not come back.
* A returning worker **asks before uploading**, so a result for a chunk somebody
  else has already finished costs one small message rather than the whole
  transfer.
* A worker **stops** a chunk the host reports as already finished, instead of
  computing an answer that exists.

## Getting work onto other machines

* `host_serve_packages()` stocks a CRAN-shaped repository the host serves over
  the same socket, so workers short of a package fetch it from the host rather
  than each downloading it from CRAN.
* `jobr_doctor()` and `jobr_ping()` diagnose the two things that actually go
  wrong: binding to `127.0.0.1`, and a host firewall dropping connections
  silently.
* `jobr_new_project()` scaffolds a project; `jobr_check_project()` validates one
  before anyone else has to find out.
* `jobr_estimate()` and the bundled benchmark give a runtime you can predict, so
  a real speedup can be told from a fast machine.

## Known limits

* Workers are authenticated by passphrase only. Mutual TLS is not reachable
  through nanonext's API; see `?security`.
* A worker survives the host restarting, but not its own R session ending: it
  keeps its results, and must be started again by hand.
* A worker holds one chunk at a time, not a prefetched queue.
* Nothing projects a finish time. A chunk is stopped only when the host reports
  it already finished elsewhere; a chunk that merely lost its lease, or outstayed
  `max_chunk_seconds`, runs to the end.
* R 3.6 is the floor. On Windows that requires Rtools 3.5, since CRAN ships no
  binary for it.
