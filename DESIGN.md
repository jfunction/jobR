# jobR: what was intended, what exists

A map of the repository, and an honest account of how the current code relates
to the design it came from. Written so that the 2022 conception is not lost
when the files that carried it are cleaned away.

---

## The repository

```
R/                         1,800 lines. The package.
  ledger.R      274   Durable work record. Append-only TSV, replayed on open.
                      Leases, claiming, chunk boundaries. The core.
  join.R        319   Worker: authenticate, sync bundle, claim, run, submit.
  serve.R       262   Host: state, request handler, socket loop.
  bundle.R      226   Manifests, content hashing, zip transfer, cache staleness.
  project.R     184   Scaffolding (jobr_new_project) and validation.
  doctor.R      162   Preflight: LAN address, port, firewall, reachability.
  benchmark.R   132   A workload whose runtime you can predict.
  enrol.R       132   Passphrases, tokens, constant-time comparison.
  versions.R     97   R version skew, stringsAsFactors, RNG reproducibility.

tests/testthat/          1,500 lines. More test than package, deliberately.
  test-ledger.R     257   Unit + property tests over random event histories.
  test-project.R    319   Scaffolding, examples, multi-core, preflight.
  test-protocol.R   286   The whole request handler, no sockets involved.
  test-integration.R 277  Real processes, real sockets, deterministic faults.
  test-bundle.R     178   Hashing, transfer, verification, caching.
  test-enrol.R       43   Credentials.
  helper-integration.R 129  Process scaffolding and the reasoning behind it.

inst/examples/
  montecarlo/         Worked example. Multi-file, seeded, reproducible.
  benchmark/          Calibrated workload for measuring what distribution buys.

data/passphraseWords.rda  EFF wordlist, for spoken credentials.
man/                      54 generated .Rd files.

README.md           What it is, why, how it differs from crew/mirai.
HOME-TEST.md        Two-laptop walkthrough, with the things that actually break.
DESIGN.md           This file.
```

---

## The original conception (2022)

Recovered from `Todo.xlsx`, from `Documentation.Rmd` (removed in the tidy; still
in git history at `2beb056`), and from the design conversation.

**The shape of it.** A host holds a body of work and the code that performs it.
A client downloads the codebase **once** — that single download unlocks the
capacity to take on many tasks. Thereafter the host dishes out tasks in
batches from a queue. If a client stops checking in within some reasonable
time — a walltime, or an expected finish — the host marks it unresponsive and
reclaims the tasks in its queue, putting them back for someone else, ideally at
the back so that if the client does eventually return its work is not wasted.

**The endpoints planned** (`Todo.xlsx`):

```
/project/new                              /project/list
/project/{projectID}/setParms             /project/{projectID}/download
/project/getParms                         /project/{projectID}/solve/{parmID}
```

**The client API planned:** `hostProject(dir)`, `getProjects()`,
`getJob(projectID)`, `writeResult(projectID, jobResult)`.

**Credentials:** an admin id plus issued client ids —
`[idAdmin, idCli1, idCli2, …, idCli{numIds}]` from `projectID, numIds`. The
server owner issues tokens to the people allowed to contribute.

---

## What landed

### The one-download-then-many-tasks model — landed in full

This is the load-bearing idea and it works as conceived. A project is a
directory with a `jobR.dcf` manifest; the host zips exactly the files the
manifest lists and serves them on request; the worker downloads once, verifies,
unpacks and caches.

It is better than the original in one respect: the bundle is **content
addressed**. The worker stores the hash alongside the unpacked project, and on
every subsequent join transfers *nothing* unless the project actually changed.
Reconnecting after a dropped link costs one small message, not a re-download —
which matters on a metered or intermittent connection.

`bundle.R`, and `test-bundle.R` for the caching and tamper cases.

### Batch dispatch — landed, in a different shape

Jobs are split into chunks by `chunk_plan()`, and `claim_chunk()` hands them
out one at a time on request. A chunk *is* the batch.

The difference from the original: a client holds **one** chunk at a time rather
than being given a queue of several. See "Not built" below for why this is the
current trade-off rather than a settled answer.

`ledger.R`.

### Reclaiming abandoned work — landed, by lease rather than by liveness

Work is leased, not merely sent. An assignment carries an expiry; a chunk whose
lease has lapsed becomes claimable by anyone. This is what makes a closed laptop
lid recoverable, and it is the feature the package exists for.

And the "back of the queue" instinct was right, and is implemented:
`claim_chunk()` prefers chunks that have **never been attempted** before
reissuing anything whose lease lapsed. Fresh work always starts before anything
is duplicated, so a reclaimed chunk genuinely does go behind the queue of
untried work.

Completion is terminal, so a worker presumed dead that reports in late cannot
reopen finished work, and two workers cannot ping-pong a chunk forever.

`ledger.R`, `test-ledger.R`, and the integration test that kills a worker
mid-chunk.

### Credentials — landed, simplified

A spoken passphrase enrols a worker; the host issues an opaque session token in
exchange. Not the per-client id list originally planned, but the same idea with
one fewer moving part: anyone holding the passphrase may contribute, and tokens
die with the host process.

The original instinct that credentials should be human-transferable was right
and is preserved — a passphrase can be read down a phone line. `enrol.R`.

### Checking in — landed

Workers renew the lease on the chunk they are running, at a third of the lease
interval, so two renewals can be lost before the host gives the work away. The
host states the lease length when it hands out a chunk, so the two never
disagree, and only the worker actually holding a lease may renew it.

This is deliberately **not** a separate UDP heartbeat. The worker already holds
a socket to the host and uses it for claim and submit, so a renewal is one more
request on it. A second port — UDP — through a home router, Windows Firewall
and a corporate egress policy is strictly more deployment friction, which is
the thing this package is trying to avoid; NNG has no UDP transport for
request/reply in any case; and the loss tolerance that usually motivates UDP
heartbeats is already provided by renewing at a third of the lease.

The awkward part was that a worker is single-threaded: while computing a chunk
it is inside `run_chunk()` and has no opportunity to speak. The first version
called the `heartbeat` callback between jobs when running serially, and while
polling `mirai::unresolved()` when running across cores. Collecting the
parallel results with `m[]` would have blocked until the whole chunk finished,
leaving no such opportunity.

That left a hole exactly where it hurt most. A chunk of many short jobs kept
its lease; a chunk containing **one long job** did not, because there is no
"between jobs" to beat in. The long job is the one that needs the lease held —
a sensitivity analysis whose single run takes minutes is the motivating case
for this package, not an edge case.

Calling it inherent was wrong. It was inherent only to running the job *in the
worker process*. Jobs now go to a mirai daemon **even on a single core**, so
the worker process never executes user code and is always free to renew. The
polling path that already existed for multiple cores becomes the only path,
and the hole closes. Measured on one four-second job with a half-second
interval: one beat before, eight after.

The costs are real and worth stating:

- **An extra R process**, even for a one-core worker. On a memory-tight
  machine `options(jobR.in_process = TRUE)` runs jobs inline again, with the
  old limitation and a message saying so. The same switch is how the fallback
  path is tested without uninstalling mirai.
- **mirai matters more than it did.** It was Suggested and only needed for
  `cores > 1`; now its absence also costs lease renewal during long jobs.
  Still not Required — a worker that can only manage short jobs is still a
  worker — but `jobr_join()` now says what is lost, once, at join time.
- **A hung job is no longer distinguishable from a slow one.** Previously a
  wedged job stopped beating and the lease lapsed, which reclaimed the chunk;
  that was accidental, and it was also what broke long jobs. The replacement
  is explicit: `max_chunk_seconds` stops renewing after a stated budget. It
  defaults to no limit, because only the person who wrote the jobs knows how
  long they ought to take.

Daemons are started once per `jobr_join()` rather than once per chunk. Spawning
one takes the better part of a second: nothing against an hour-long job, a
great deal against a chunk of five short ones.

### Host-served package repository — landed

Not part of the original design, but it belongs to the same idea: the host
already has the packages, and every worker was downloading them again from
CRAN over its own connection.

`host_serve_packages()` stocks a CRAN-shaped repository under the host's work
directory -- `src/contrib` and `bin/<platform>/contrib/<R series>` trees with
`PACKAGES` indexes written by `tools::write_PACKAGES()`. Workers fetch it over
the same socket they use for work, reassemble it locally, and install with
`repos = "file:///..."`, so R's own dependency resolution and version checking
apply and nothing here reimplements them.

Only files the worker does not already have are transferred, matched by
sha256, so a second visit costs one small message. A path arriving from a
worker is guarded twice: structurally, and against the host's own manifest as
a whitelist rather than a blacklist.

One repository can serve several R versions at once, because R reads only the
directory matching its own series. Sources are stocked always and work
anywhere but need a toolchain; binaries need none but must match. CRAN only
builds binaries for the current R and the one before, so a worker on an older
R is offered sources -- a limit of CRAN, not of this code.

It is deliberately explicit rather than automatic: it reaches out to CRAN and
can take a while, which should not happen as a side effect of starting a host.

### Surviving a link that drops — landed, and tested by breaking one

A worker used to treat the first unanswered request as proof the host had gone
and stop for good. On the links this package is for, that is the wrong default
by a long way, and the containerised blackout measured the cost precisely: a
25-second outage removed a worker 15.6 seconds before its link came back, and
took the finished chunk it was holding with it.

The reason it was wrong is worth stating, because it was not laziness. Silence
genuinely was ambiguous. The host shut down the instant the last chunk landed,
so the last worker to ask for work got no reply -- and no reply is also what a
dead network looks like. No amount of retrying resolves an ambiguity like
that; it only chooses which way to be wrong.

So both ends changed:

- The **host lingers**. After the last chunk it keeps answering until every
  worker that enrolled has been told, in a reply it actually received, that
  the jobset is over. Workers say `bye` when they stop for their own reasons,
  so it normally exits at once; `linger_seconds` caps the wait for a machine
  that is never coming back. Silence now means the link.
- The **worker retries**. `call()` re-dials and tries again with backoff for
  `reconnect_seconds` (60 by default) before concluding the host is gone. The
  re-dial matters: a timed-out exchange leaves a request outstanding in the
  req socket's state machine, and a partition does not close a TCP connection,
  it just stops delivering.

Two calls deliberately do not retry: the lease heartbeat and handing a chunk
back after a failure. Both run inside the work, and a heartbeat that waits out
a dead link stalls the very thing the lease protects. If they do not get
through, the lease lapses -- which is what a lease is for.

The submit is the opposite case, and gets the whole budget: the work is
already done, and giving up throws it away. A duplicate submit is harmless,
because completion is terminal in the ledger.

`docker/docker-compose.partition.yml` is the proof, and it is a real one: the
healthy worker is capped at 20 of 40 chunks, so the other 20 can only be done
by the worker that went dark. It failed before this change and passes after.

---

## What is partially built

### Per-worker identity — recorded, never used for liveness

`state$workers` exists and records what R version each worker reported. It is
not used to decide whether a worker is alive. Liveness is per-chunk, via lease
expiry, never per-worker.

The practical difference: a worker holding one chunk that dies is handled well;
there is no concept of "Laptop B is gone, reclaim *everything* it holds",
because a worker never holds more than one thing.

---

## What is not built

### A per-client queue of several tasks

The original had the host dishing out batches into a client's queue. The
current design gives a client exactly one chunk at a time.

This is a real trade-off, not an oversight:

- **One at a time** wastes nothing when a client vanishes — at most one chunk is
  in flight — and needs no per-worker bookkeeping. It costs one round trip per
  chunk.
- **A prefetched queue** hides latency, which matters on a slow or
  high-latency link where the round trip is a meaningful fraction of the work.
  It risks stranding several chunks on a dead client, and requires exactly the
  per-worker liveness tracking described above.

Worth revisiting if chunks ever become small relative to network latency. Until
then the simpler model is doing the job.

### Walltime and expected finish

Nothing estimates when a jobset will finish, and nothing enforces a limit on
how long a chunk may take. `jobr_estimate()` predicts a *benchmark* run from
arithmetic, but the host does not track throughput or project a completion
time.

The ledger has everything needed to compute this — every assignment and
completion is timestamped — so it is a reporting feature, not a redesign.

### Multiple projects per host

The original `/project/list` and `/project/new` implied a server hosting many
projects, with clients browsing them. A host now serves exactly one project and
one jobset. Starting a second host for a second project costs one R session,
which for the target deployment is cheaper than the multiplexing.

## Where the current design deliberately diverges

**HTTP → nanonext.** The original planned a plumber REST API. The rebuild uses
one nanonext socket for everything. This dropped `plumber` and `httr`, gave a
single TLS story, and made the worker protocol one function. The cost is that
you cannot poke it with `curl`.

**SQLite → append-only text.** The ledger is the only thing that must survive a
crash, only the host writes it, and a plain file can be read with `cat` over a
bad SSH link. Dropped `DBI` and `RSQLite`. A torn final line from a power cut is
tolerated on replay.

**random.org → local CSPRNG.** The original fetched entropy over HTTP, so a
host could not generate its own credential without working internet. Backwards
for these deployments. Now `nanonext::random()`.

**Sent/received → leases.** A bare sent/received pair cannot distinguish a
worker that is still busy from one whose laptop closed twenty minutes ago. An
expiry can.

---

## Bugs the original had, fixed in the rebuild

Recorded because they are easy to reintroduce:

- `chunk_plan` used `floor(n_jobs / chunksize)`, silently dropping the
  remainder. 1001 jobs at chunksize 25 lost the last job.
- Claiming used `> 1` where it needed `> 0`, so when exactly one unsent chunk
  remained it was skipped and the jobset could never finish.
- The project bundle was downloaded once and never re-checked, so a worker kept
  running stale code after the project changed.

---

## Verified where

Different claims rest on different evidence, and they are not interchangeable.

| Claim | Evidence |
|---|---|
| Ledger accounting, leases, chunk boundaries | Unit and property tests over randomly generated event histories |
| The whole request handler | Unit tests, no sockets involved |
| Multi-process, real sockets, deterministic faults | Integration tests on one machine, from a checkout or an installed package |
| Multi-machine, multi-R-version, real network | `docker/` testbed: 3 R versions, 4 containers, 60 jobs, exactly once |
| R 3.6 floor | nanonext 1.10.2 compiled from source under R 3.6.3 in a container, with a real socket round-trip |
| Two physical machines over a LAN | One manual run, Windows to Windows |
| Load-proportional distribution | **Not demonstrated.** Containers on one host all run at the same speed |
| A bad link: 150ms +/- 50ms delay, 5% loss | `docker/docker-compose.netem.yml`: one worker behind `tc netem` took 18 of 40 chunks, 200 jobs exactly once |
| A lease renewed during a single long job | Unit test counting beats through one 4s job: 1 in-process, 8 via a daemon. Integration test where one 12s job outlives a 4s lease with a rival waiting: the chunk is handed out twice in-process and once via a daemon -- run both ways, so the test is known to discriminate |
| A link that goes dark mid-run | `docker-compose.partition.yml`: a worker survives a 25s total blackout and does 11 more chunks afterwards, with the other worker capped so nothing else could have |
| Windows R 3.6 | **Not demonstrated.** CRAN ships no binary; needs Rtools 3.5 |

## Open, in rough priority order

1. **Progress and projected finish.** The ledger already has the timestamps.
2. **Prefetched per-client queues**, if round trips ever start to matter.
3. **Abort a chunk whose lease was lost.** A worker told it no longer holds the
   lease currently finishes the chunk anyway; the submit is a harmless
   duplicate, but the work is wasted. Stopping early is easy serially and
   awkward across cores, where the tasks are already in flight.
