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

---

## What is partially built

### Checking in — the host half exists, the worker half does not

**This is the significant gap, and it is a live defect.**

The design called for clients to check in, and for silence to mean
unresponsive. The ledger has a `renew` event. `handle_request()` implements the
`renew` operation. `test-ledger.R` and `test-protocol.R` both cover it.

`jobr_join()` never calls it.

So a worker has no heartbeat. With the default `lease_seconds = 300`, any chunk
that takes longer than five minutes has its lease expire **while the worker is
still computing it**. The chunk is handed to someone else and done twice. The
ledger handles the duplicate correctly — completion is terminal, one result
wins — so nothing is corrupted, but the work is wasted and the report is
confusing.

It has not bitten yet only because every workload run so far has had chunks
measured in seconds. It will bite the first time a real job takes minutes.

The fix is small: renew on a timer while a chunk runs, and let the host treat a
missed renewal rather than a wall-clock expiry as the signal.

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

### Host-served package repository

Not part of the original design, but it belongs here: a worker must install the
project's R packages itself, from CRAN, over its own connection. The host
already has those packages. On a metered link, four workers each pulling from
CRAN is four times the traffic it needs to be.

---

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

## Open, in rough priority order

1. **Worker heartbeat.** Renew a lease while a chunk runs. The only item here
   that is a defect rather than an absence.
2. **Host-served package repo.** One download instead of one per worker.
3. **Progress and projected finish.** The ledger already has the timestamps.
4. **Prefetched per-client queues**, if round trips ever start to matter.
