# Containerised testbed

A multi-node jobR run with a real network between the nodes and a **different R
version on each**, so the things a single machine cannot test get tested:

- work actually crossing a network between separate machines
- a mixed-version fleet, which is the normal case for this package
- Linux workers, when most development here happens on Windows
- R 3.6 — the package floor, and the version most likely to fail silently,
  because `data.frame()` defaulted to `stringsAsFactors = TRUE` before R 4.0

```
host            R 4.4.1   serves the jobset, asserts the result, sets the exit code
worker-current  R 4.4.1   2 cores
worker-oldish   R 4.0.5   1 core
worker-floor    R 3.6.3   1 core
```

## Running it

```bash
docker/run.sh docker/docker-compose.yml
```

The host container's exit code **is** the test result, so that one command is
the whole harness. First run builds three images and takes a while; afterwards
the dependency layer is cached.

`run.sh` rather than `up --exit-code-from host`, for a reason worth knowing
before reaching for the shorter command: see
[Why `run.sh` rather than `docker compose up`](#why-runsh-rather-than-docker-compose-up)
below.

Tear down with `docker compose -f docker/docker-compose.yml down -v`.

## What it asserts

In `assertions.R`, deliberately separate from `host.R` and free of any
container or network concern, so it can be tested on a machine that cannot run
Docker at all — `tests/testthat/test-testbed.R` does exactly that:

- every job present **exactly once**, so chunking, retries and reissues did not
  change the answer
- work landed on **more than one machine**. Without this the testbed would pass
  with every worker silently failing to connect and the host doing all of it,
  which is the precise failure a multi-node test exists to catch
- the `host` column came back as character, not factor — the R 3.6 trap
- the ledger agrees every chunk is done

## Tuning

Environment variables on the `host` service: `JOBR_JOBS`, `JOBR_CHUNKSIZE`,
`JOBR_SECONDS` (CPU per job), `JOBR_LEASE`, `JOBR_EXPECT_HOSTS`,
`JOBR_DEADLINE`. On workers: `JOBR_CORES`, `JOBR_URL`.

To change the version matrix, edit the `R_VERSION` build arg per service. Any
`rocker/r-ver` tag works; the floor is 3.6.

## What a single-machine run does and does not prove

All four containers share one host's CPUs, so every worker runs at the same
speed. How the work divides between them is therefore an artefact of timing
rather than of capability, and the shares move from run to run: the host waits
at the end to tell each worker the jobset is over, so the workers stop at
slightly different moments. An even three-way split looks more impressive and
means no more than a lopsided one.

What either shape demonstrates is correctness: every job done exactly once,
across three machines and three R versions. Neither demonstrates
load-proportional distribution. A faster machine taking more chunks is real
behaviour, but showing it needs genuinely unequal machines -- the two-laptop
run in `HOME-TEST.md` is what does that.

## Notes on the images

**No apt step, deliberately.** Nothing here needs one: nanonext bundles NNG and
mbedTLS, and digest, zip and mirai need no system libraries. Adding one also
breaks the oldest image outright, because `rocker/r-ver:3.6.3` sits on Debian
buster, which is end-of-life and has moved to `archive.debian.org`, so
`apt-get update` returns 404 there.

**R 3.6 is verified, not merely declared.** nanonext 1.10.2 compiles from
source under R 3.6.3 and completes a real socket round-trip, so the package
floor rests on evidence rather than on a `Depends` field. This says nothing
about *Windows* R 3.6, where the obstacle is CRAN shipping no binary and Rtools
3.5 being required -- see `HOME-TEST.md`.

## Network impairment

Intermittency is the condition this package exists for, so it is shaped with
`tc netem` and asserted rather than assumed.

```bash
docker/run.sh docker/docker-compose.netem.yml
```

Two workers on the same jobset: `worker-steady` on a clean link, and
`worker-flaky` behind 150ms +/- 50ms of delay and 5% packet loss. The host is
told to expect **two** distinct machines in the results, and that is the whole
assertion. A worker that cannot finish its handshake, or that quits the first
time something is dropped, leaves the jobset to be completed by the steady
worker alone -- at which point only one machine appears and the run fails. The
test is about surviving the link, not about finishing.

For a worker whose link disappears entirely, overlay
`docker-compose.partition.yml`.

### How the impairment is applied

A sidecar container (`Dockerfile.netem`, `netem.sh`) shares the worker's
network namespace via `network_mode: "service:worker-flaky"`, holds
`NET_ADMIN`, and attaches the qdisc from outside. The R images must stay free
of an apt layer, so `tc` cannot be installed in them at all; shaping from a
sidecar leaves every R image untouched and lets any worker be impaired,
including the 3.6.3 one.

netem shapes **egress only**, so a request/reply exchange sees the delay and
the loss once rather than twice.

Knobs, all on the `netem` service: `NETEM_DELAY`, `NETEM_JITTER`, `NETEM_LOSS`,
`NETEM_RATE`, `NETEM_PARTITION_AT`, `NETEM_PARTITION_FOR`.

### The worker gates itself on a measurably bad link

Compose cannot express "start after the qdisc exists", so the worker pings
until a round trip is observably slow and only then joins
(`JOBR_REQUIRE_RTT_MS`). A sentinel file in a shared volume would do the same
job until a stale one survived a run, after which the worker would handshake
over a clean link while the run still called itself an impaired test.
Measuring the link cannot go stale.

The margin is wide: the gate opens at around 600ms against a 120ms threshold,
and a clean link measures about 1ms.

### Why `run.sh` rather than `docker compose up`

`--exit-code-from host` implies `--abort-on-container-exit`, which tears the
run down as soon as **any** container stops. That is fatal to the assertions
here, for three separate reasons:

- a worker finishes its share and exits while the host is still collecting;
- a worker drops out because its link died, which is the exact event the
  impaired scenarios exist to observe;
- the host deliberately outlives its workers, staying up at the end to tell
  each one the jobset is over.

In each case compose kills the host before it reaches a single assertion and
reports success anyway. A run that checks nothing and exits 0 is worse than
one that fails, so `run.sh` starts the stack detached, streams the logs, and
blocks on `docker compose wait host`. The host is the only judge.

`run.sh` also tears the stack down *before* starting, not after. A stopped
container keeps its filesystem, so `up -d` would restart the previous run's
host with the previous run's ledger still in `/tmp/jobr-host`. That ledger is
append-only and replayed on open -- correct behaviour, and the reason a
restarted host does not lose a jobset -- so the new host resumes where the old
one stopped and counts its chunks as done. The result is indistinguishable
from a clean pass. Not tearing down afterwards is equally deliberate: a failed
run is the one worth inspecting, and its ledger and logs explain it.

### Exit paths

Both directions are exercised, because a harness that can only report success
is not a harness. Against code without the reconnect logic the blackout
scenario returns 1; against the current code it returns 0. The bad-link
scenario returns 0 either way, which is why the blackout scenario exists
separately.

### What the impairment demonstrates

**Loss over TCP is not message loss.** 5% netem loss on a TCP transport is
absorbed by retransmission: the application sees latency, not dropped requests.
The impaired worker carries very nearly its full share, with no protocol-level
failure at all, so the only real cost of the bad link is the round trip. What
reaches the application from a bad link is *delay* and *connection loss*, and
those are the knobs that test anything. Worth knowing before turning
`NETEM_LOSS` up and believing the result proves something.

**A total blackout is survivable, and the partition scenario is what proves
it.** Without a bounded reconnect on the worker side, a single timed-out
request ends that worker's participation permanently, and because the request
is usually a `submit`, a finished chunk is discarded with it. The fleet stays
correct -- the lease lapses, the chunk is reissued, every job lands exactly
once -- but the machine is lost roughly ten seconds into the outage and never
returns, even though the link comes back fifteen seconds later.

The scenario asserts the opposite, with the healthy worker capped at 20 of the
40 chunks so the remainder can only come from the worker that went dark:

```
== netem: partition starts ==
  lost contact with the host (no reply: 5 | Timed out); retrying for up to 60s
worker done: 20 chunks                 <- the steady worker reaches its cap
== netem: partition ends ==
  back in touch with the host          <- and picks up chunk 32
== OK == all 200 jobs, all 40 chunks done
```

`DESIGN.md` describes the mechanism. In short: the worker retries a silent
host instead of concluding it has gone, and the host stops being silent for
the one reason that was previously indistinguishable from a dead link, by
staying up after the last chunk to tell every worker the jobset is over.

## Worth adding next

**Killing a container mid-run** (`docker kill worker-floor`) is a more faithful
"machine died" than killing a process, and should leave the run completing via
lease expiry and reissue.

**Symmetric impairment.** netem shapes egress only. Making it symmetric needs
`ifb` ingress redirection, which is a kernel module the testbed would then
depend on.
