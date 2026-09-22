# jobR design

What the package does and why it is built that way, plus the 2022 conception it
grew from and the points where it deliberately departs from it.

This document states the **current** design in the present tense. When
something changes, the statement is edited rather than a correction appended,
so that there is exactly one account of how each thing works. It deliberately
carries no repository map, line counts or file inventories: those are secondary
to the code, go stale silently, and are better read from the source.

---

## The original conception (2022)

Kept because it is the reason several things are shaped the way they are.

**The shape of it.** A host holds a body of work and the code that performs it.
A client downloads the codebase **once** — that single download unlocks the
capacity to take on many tasks. Thereafter the host dishes out tasks in batches
from a queue. If a client stops checking in within some reasonable time — a
walltime, or an expected finish — the host marks it unresponsive and reclaims
the tasks in its queue, putting them back for someone else, ideally at the back
so that if the client does eventually return its work is not wasted.

**The endpoints planned:**

```
/project/new                              /project/list
/project/{projectID}/setParms             /project/{projectID}/download
/project/getParms                         /project/{projectID}/solve/{parmID}
```

**The client API planned:** `hostProject(dir)`, `getProjects()`,
`getJob(projectID)`, `writeResult(projectID, jobResult)`.

**Credentials planned:** an admin id plus issued client ids —
`[idAdmin, idCli1, idCli2, …, idCli{numIds}]` derived from `projectID, numIds`.
The server owner issues tokens to the people allowed to contribute.

---

## How the current design works

### Project bundles

A project is a directory with a `jobR.dcf` manifest. The host zips exactly the
files the manifest lists and serves them on request; a worker downloads once,
verifies, unpacks and caches.

The bundle is **content addressed**. A worker stores the hash alongside the
unpacked project and on every subsequent join transfers nothing unless the
project actually changed, so rejoining after a dropped link costs one small
message rather than a re-download. That matters on a metered or intermittent
connection.

### Chunks and leases

`chunk_plan()` splits the jobs into chunks and `claim_chunk()` hands them out
one at a time on request. A chunk is the unit of dispatch, of leasing and of
result submission.

Work is **leased, not merely sent**. An assignment carries an expiry, and a
chunk whose lease has lapsed becomes claimable by anyone. This is what makes a
closed laptop lid recoverable, and it is the feature the package exists for.

`claim_chunk()` prefers chunks that have **never been attempted** before
reissuing anything whose lease lapsed, so fresh work always starts before
anything is duplicated and a reclaimed chunk goes behind the queue of untried
work.

**Completion is terminal.** A worker presumed dead that reports in late cannot
reopen finished work, and two workers cannot ping-pong a chunk indefinitely.
This is also what makes a duplicate submit harmless, which several other
decisions rely on.

Only the worker currently holding a lease may renew it or hand the chunk back.
Both are guarded the same way, and for the same reason: without the guard, a
worker whose lease lapsed while it was computing could reopen a chunk that now
belongs to somebody else, taking it out from under a worker busy on it.

A worker holds exactly one chunk at a time. See *Deliberate limits*.

### Renewing a lease while work runs

A worker renews the lease on the chunk it is running at a third of the lease
interval, so two renewals can be lost before the host gives the work away. The
host states the lease length when it hands out the chunk, so the two never
disagree, and only the worker actually holding a lease may renew it.

Renewal travels over the socket the worker already holds, **not** a separate UDP
heartbeat. A second port through a home router, Windows Firewall and a corporate
egress policy is strictly more deployment friction, which is the thing this
package exists to avoid; NNG has no UDP transport for request/reply in any case;
and the loss tolerance that usually motivates UDP heartbeats is already provided
by renewing at a third of the lease.

R is single-threaded, so a worker executing user code cannot also talk to the
host. Renewing only between jobs would hold the lease for a chunk of many short
jobs and not for a chunk containing one long one — and the long job is precisely
the one that needs it, since a sensitivity analysis whose single run takes
minutes is a motivating case for this package rather than an edge of it.

The binding constraint is therefore not the single thread but *where the job
runs*. **Jobs run in a mirai daemon even on a single core**, leaving the worker
process free to renew while user code executes elsewhere. Collecting results
with `m[]` would block until the whole chunk finished, so `run_chunk()` polls
`mirai::unresolved()` and renews between polls. Daemons start once per
`jobr_join()` rather than once per chunk, because spawning one takes the better
part of a second: nothing against an hour-long job, a great deal against a chunk
of five short ones.

Three costs, all real:

- **An extra R process**, even for a one-core worker. On a memory-tight machine
  `options(jobR.in_process = TRUE)` runs jobs inline instead, which cannot renew
  during a job and says so.
- **mirai carries more weight than its `Suggests` status implies.** It is needed
  for `cores > 1` and for renewing a lease during a long job. Still not
  Required — a worker that can only manage short jobs is still a worker — and
  `jobr_join()` states what is lost, once, at join time.
- **A hung job is not distinguishable from a slow one.** A job that renews while
  it runs holds its chunk whether or not it is making progress. Letting the
  lease lapse would reclaim it, but that is the same mechanism that makes long
  jobs impossible, so it cannot be the answer. The bound is explicit instead:
  `max_chunk_seconds` stops renewing after a stated budget, and defaults to no
  limit, because only the person who wrote the jobs knows how long they ought to
  take.

A refused renewal carries a reason, because two quite different situations
otherwise look identical to the worker and only the host can tell them apart.
**Finished by somebody else** means every further second is spent on an answer
that already exists, so the worker stops: `mirai::stop_mirai()` cancels the
tasks already dispatched, rather than leaving them to burn the cores of a
machine that was donating them. **Merely reassigned** means the worker now
holding it may itself die, and a completed result can still be offered, so the
worker carries on.

Giving up that way raises a `jobr_abandoned` condition rather than an error.
`max_failures` exists to notice a machine that is broken, and a chunk taken
away by the scheduler says nothing about the machine that was running it.

### Surviving a dropped link

Silence from the host does not mean the host is gone. On an intermittent link it
far more often means a moment's outage, and a worker that stops at the first
missed reply loses the machine along with whatever chunk it was holding.

Retrying alone cannot fix that, because silence would otherwise be genuinely
ambiguous: a host that stopped the instant the last chunk landed would leave the
last worker to ask for work with no reply, and no reply is also what a dead
network looks like. Both ends therefore participate.

- The **host lingers**. After the last chunk it keeps answering until every
  worker that enrolled has been told, in a reply it actually received, that the
  jobset is over. Workers send `bye` when they stop for their own reasons, so it
  normally exits at once; `linger_seconds` caps the wait for a machine that is
  never coming back.
- The **worker retries**. `call()` re-dials and tries again with backoff for
  `reconnect_seconds` before concluding the host is gone. The re-dial matters: a
  timed-out exchange leaves a request outstanding in the req socket's state
  machine, and a partition does not close a TCP connection, it just stops
  delivering.

With the host no longer silent for any innocent reason, silence means the link,
and the worker is entitled to keep trying.

Two calls deliberately do **not** retry: the lease heartbeat and handing a chunk
back after a failure. Both run inside the work, and a heartbeat that waits out a
dead link stalls the very thing the lease protects. If they do not get through
the lease lapses, which is what a lease is for.

The submit is the opposite case and gets the whole budget: the work is already
done. Resubmitting a chunk that lapsed and was reissued costs nothing, because
completion is terminal — and if the budget runs out, the results are kept
rather than discarded. See *Results that cannot be delivered yet*.

A host that has restarted is a special case of silence that is not silent at
all: it answers, and what it says is `not authenticated`, because `host_new()`
begins with no tokens and has forgotten every one it issued. Treating that as
terminal dismissed every worker attached to a host whenever it bounced, which
on a machine meant to run for weeks turns a blip into an outage. The worker
still holds the passphrase, so it enrols again and carries on. A refusal of the
enrolment itself is still terminal: that means the passphrase has changed, or
this is a different host.

### Results that cannot be delivered yet

The host keeps a durable ledger. The worker keeps a spool, for the same reason
and against the opposite risk: it is the machine on the unreliable link, and it
is the one holding work that has already been paid for. A submit that cannot get
through writes its results to disk instead of discarding them, so a moment's
outage no longer costs however long the chunk took to compute.

The spool outlives the R session, and a worker delivers whatever it is holding
**before** claiming anything new — completed work is at risk until the host has
it, whereas work not yet claimed is at risk of nothing.

It does not live in the project cache. That cache is a cache: discardable, and
re-fetchable from the host. A spooled result is the only copy of something that
cannot be recovered, so it lives in the user's data directory rather than in
`tempdir()`, which R removes when the session ends.

Before uploading, the worker **offers**: it names the chunks it is holding and
the host replies with the ones it still wants. A spooled result can be large,
and sending one for a chunk somebody else has already finished spends bandwidth
to achieve nothing — which on a metered link is the difference between the spool
being safe and the spool being cheap. A host that does not know the `offer`
operation refuses it, and the worker falls back to offering everything.

Results cannot wait indefinitely: `spool_max_age` discards them once a host has
plainly not come back. `jobr_spool()` shows what a machine is holding and
`jobr_spool_clear()` throws it away, because nobody will think to look in a
data directory.

### Credentials

A spoken passphrase enrols a worker; the host issues an opaque session token in
exchange. Anyone holding the passphrase may contribute.

Tokens die with the host process, and are not meant to outlive it. The
passphrase is the durable credential; the token is a session handle, and a
worker that finds its handle refused simply presents the passphrase again.

Credentials are human-transferable by design — a passphrase can be read down a
phone line — which was the right instinct in the original and is preserved.

### Host-served package repository

The host already has the packages the project needs, and without this every
worker downloads them again from CRAN over its own connection.

`host_serve_packages()` stocks a CRAN-shaped repository under the host's work
directory: `src/contrib` and `bin/<platform>/contrib/<R series>` trees with
`PACKAGES` indexes written by `tools::write_PACKAGES()`. Workers fetch it over
the same socket they use for work, reassemble it locally, and install with
`repos = "file:///..."`, so R's own dependency resolution and version checking
apply and nothing here reimplements them.

Only files the worker does not already have are transferred, matched by sha256,
so a second visit costs one small message. A path arriving from a worker is
guarded twice: structurally, and against the host's own manifest as a whitelist
rather than a blacklist.

One repository serves several R versions at once, because R reads only the
directory matching its own series. Sources are stocked always and work anywhere
but need a toolchain; binaries need none but must match. CRAN builds binaries
only for the current R and the one before, so a worker on an older R is offered
sources — a limit of CRAN, not of this code.

Stocking is explicit rather than automatic: it reaches out to CRAN and can take
a while, which should not happen as a side effect of starting a host.

---

## Where this departs from the original conception

**HTTP → nanonext.** The original planned a plumber REST API. One nanonext
socket carries everything instead, which drops `plumber` and `httr`, gives a
single TLS story, and makes the worker protocol one function. The cost is that
it cannot be poked with `curl`.

**SQLite → append-only text.** The ledger is the only thing that must survive a
crash, only the host writes it, and a plain file can be read with `cat` over a
bad SSH link. Drops `DBI` and `RSQLite`. A torn final line from a power cut is
tolerated on replay.

**random.org → local CSPRNG.** The original fetched entropy over HTTP, so a host
could not generate its own credential without working internet — backwards for
these deployments. `nanonext::random()` instead.

**Sent/received → leases.** A bare sent/received pair cannot distinguish a
worker that is still busy from one whose laptop closed twenty minutes ago. An
expiry can.

**Issued client ids → one passphrase.** The same idea with one fewer moving
part.

**Many projects per host → one.** The original `/project/list` and
`/project/new` implied a server hosting many projects with clients browsing
them. A host serves exactly one project and one jobset; starting a second host
for a second project costs one R session, which for the target deployment is
cheaper than the multiplexing.

---

## Deliberate limits

**A worker holds one chunk, not a queue of several.** The original had the host
dishing batches into a client's queue. One at a time wastes nothing when a
client vanishes — at most one chunk is in flight — and needs no per-worker
bookkeeping, at the cost of one round trip per chunk. A prefetched queue would
hide that latency, which matters when the round trip is a meaningful fraction of
the work, but risks stranding several chunks on a dead client and requires
per-worker liveness tracking. Worth revisiting if chunks ever become small
relative to network latency.

**Liveness is per-chunk, never per-worker.** `state$workers` records what R
version each worker reported, and is used for diagnostics only. There is no
concept of "that machine is gone, reclaim everything it holds", because a worker
never holds more than one thing.

**No walltime or projected finish.** Nothing estimates when a jobset will
finish. `jobr_estimate()` predicts a *benchmark* run from arithmetic, but the
host does not track throughput. The ledger timestamps every assignment and
completion, so this is a reporting feature rather than a redesign.

**A chunk is abandoned only when it is provably pointless.** A worker stops
when the host tells it the chunk is already finished, and not otherwise. It
keeps going when the chunk was merely reassigned, because the worker holding it
now may die and the result can still be offered; and `max_chunk_seconds` stops
the *renewals* on a chunk that has outstayed its budget without stopping the
work, so the host may reissue it while the original worker runs on. Both are
deliberate: with a spool and an offer behind it, finishing costs one small
message to find out whether anybody still wants the answer.

---

## Bugs the original had, fixed in the rebuild

Recorded because they are easy to reintroduce:

- `chunk_plan` used `floor(n_jobs / chunksize)`, silently dropping the
  remainder, so 1001 jobs at chunksize 25 lost the last job.
- Claiming used `> 1` where it needed `> 0`, so when exactly one unsent chunk
  remained it was skipped and the jobset could never finish.
- The project bundle was downloaded once and never re-checked, so a worker kept
  running stale code after the project changed.

---

## How each claim is verified

Different claims rest on different evidence, and they are not interchangeable.

| Claim | Evidence |
|---|---|
| Ledger accounting, leases, chunk boundaries | Unit and property tests over randomly generated event histories |
| The whole request handler | Unit tests, no sockets involved |
| Multi-process, real sockets, deterministic faults | Integration tests on one machine, run from a checkout or an installed package |
| Multi-machine, multi-R-version, real network | The `docker/` testbed: three R versions, four containers, every job exactly once |
| R 3.6 floor | nanonext compiled from source under R 3.6.3 in a container, with a real socket round-trip |
| Two physical machines over a LAN | One manual run, Windows to Windows |
| A bad link (delay and packet loss) | `docker/docker-compose.netem.yml`: a worker behind `tc netem` carries its share, every job exactly once |
| A lease renewed during a single long job | A unit test counting renewals through one job longer than the interval, and an integration test where one job outlives its lease with a rival worker waiting to claim it. Both are run against in-process execution as well, so they are known to discriminate |
| A link that goes dark mid-run | `docker/docker-compose.partition.yml`: a worker survives a total blackout longer than its lease and finishes the jobset, with the other worker capped so nothing else could have |
| Results surviving a host that vanishes | An integration test kills the host mid-chunk and finds the results on the worker's disk, not in the jobset |
| Delivering results from an earlier session | An integration test spools a result, starts a worker, and finds it delivered before any new chunk is claimed |
| Not uploading what the host already has | An integration test spools a deliberately wrong result for a chunk another worker then completes; the holder discards it unsent, and the answers stay correct |
| Re-enrolling when the host restarts | An integration test restarts the host under a running worker, which finishes the jobset across the restart |
| Abandoning a chunk finished elsewhere | A unit test drives `run_chunk()` with a heartbeat that refuses, and checks it stops promptly rather than running the chunk out |
| Load-proportional distribution | **Not demonstrated.** Containers on one host all run at the same speed |
| Windows R 3.6 | **Not demonstrated.** CRAN ships no binary; Rtools 3.5 would be required |

---

## Open, in rough priority order

1. **Progress and projected finish.** The ledger already has the timestamps.
2. **Prefetched per-client queues**, if round trips ever start to matter.
3. **A worker that restarts itself.** A worker survives a host restart and
   keeps its results across a session, but if its own R session dies it must be
   started again by hand. On an always-on lab machine that is the remaining
   piece of unattended operation.
