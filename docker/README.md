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
docker compose -f docker/docker-compose.yml up --build --exit-code-from host
```

The host container's exit code **is** the test result, so that one command is
the whole harness. First run builds three images and takes a while; afterwards
the dependency layer is cached.

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
speed and the split comes out even by construction:

```
          host jobs cpu_seconds share
1 728e4b679d2f   20         8.2 0.333
2 ba4ae2e4a5b1   20         8.0 0.333
3 fc2511c593bf   20         8.0 0.333
```

That demonstrates correctness -- every job done exactly once, across three
machines and three R versions -- but **not** load-proportional distribution.
A faster machine taking more chunks is real behaviour, and it needs genuinely
unequal machines to show. The two-laptop run in `HOME-TEST.md` is what
demonstrates that.

## Notes from getting this working

Two things cost a build each, and both are recorded so they are not
rediscovered:

**No apt step, deliberately.** An earlier version installed `libssl-dev` and
`procps`. Neither is needed -- nanonext bundles NNG and mbedTLS, and digest,
zip and mirai need no system libraries -- and the layer broke the oldest image
outright, because `rocker/r-ver:3.6.3` sits on Debian buster, which is
end-of-life and has moved to `archive.debian.org`, so `apt-get update` returns
404 there.

**R 3.6 is verified, not merely declared.** With the apt layer gone, nanonext
1.10.2 compiles from source under R 3.6.3 and completes a real socket
round-trip. The package floor is evidence-based. Note this says nothing about
*Windows* R 3.6, where the obstacle is CRAN not shipping a binary and Rtools
3.5 being required -- see `HOME-TEST.md`.

## Network impairment

Intermittency is the condition this package exists for, and it used to be
tested by hoping. It is now shaped with `tc netem` and asserted.

```bash
docker/run.sh docker/docker-compose.netem.yml
```

Two workers on the same jobset: `worker-steady` on a clean link, and
`worker-flaky` behind 150ms +/- 50ms of delay and 5% packet loss. The host is
told to expect **two** distinct machines in the results, and that is the whole
assertion. If the impaired worker cannot finish its handshake, or quits the
first time something is dropped, the jobset still completes -- the steady
worker would do all of it -- but only one machine appears and the run fails.
The test is about surviving the link, not about finishing.

### How the impairment is applied

A sidecar container (`docker/Dockerfile.netem`, `docker/netem.sh`) shares the
worker's network namespace via `network_mode: "service:worker-flaky"`, holds
`NET_ADMIN`, and attaches the qdisc from outside. That is deliberate: the R
images must stay free of an apt layer, because `rocker/r-ver:3.6.3` sits on
Debian buster and its archive 404s, so `tc` cannot be installed in the worker
image at all. Shaping from a sidecar leaves every R image untouched and lets
any worker be impaired, including the 3.6.3 one.

Knobs, all on the `netem` service: `NETEM_DELAY`, `NETEM_JITTER`, `NETEM_LOSS`,
`NETEM_RATE`, `NETEM_PARTITION_AT`, `NETEM_PARTITION_FOR`.

### The worker will not join a link it cannot confirm is bad

Compose cannot express "start after the qdisc exists", so the worker gates
itself on `JOBR_REQUIRE_RTT_MS`: it pings until a round trip is *observably*
slow, and only then joins. A sentinel file in a shared volume would have done
the job until a stale one survived a run, at which point the worker would have
handshaked over a clean link and the run would still have called itself an
impaired test. Measuring the link cannot go stale.

Observed: the gate opens at a 632ms round trip against a 120ms threshold, and
a clean link measures ~1ms, so the two are not close.

### `--exit-code-from host` had to go

It implies `--abort-on-container-exit`, which tears the run down the moment
**any** container stops -- including a worker that has finished its share, or
one that has dropped out because its link died, which is the exact event this
scenario exists to observe. It aborted a run at 26 of 40 chunks and reported
success, because the host never reached its assertions.

`docker/run.sh` starts the stack detached, streams the logs, and blocks on
`docker compose wait host`, so workers coming and going no longer decide the
result. The host is the only judge.

### `run.sh` tears everything down before it starts, on purpose

A stopped container keeps its filesystem. `docker compose up -d` will restart
the previous run's host with the previous run's ledger still sitting in
`/tmp/jobr-host`, and because that ledger is append-only and replayed on open
-- correct behaviour, and the reason a restarted host does not lose a jobset
-- the new host resumes where the old one stopped and counts its chunks as
done.

It reads as a clean pass. It caught this testbed once: a run reported `all 40
chunks done` while its two workers had between them processed ten. So `run.sh`
does `down -v` first and recreates every container.

### Verified exit paths

Both directions of the harness were checked, because a test harness that can
only report success is not a harness:

```
docker/run.sh docker/docker-compose.netem.yml                                   -> 0
docker/run.sh docker/docker-compose.netem.yml docker/docker-compose.partition.yml -> 1
```

### What the impaired run showed

**Loss over TCP is not message loss.** 5% netem loss on a TCP transport is
absorbed by retransmission: the worker sees latency, not dropped requests. It
carried its share with no protocol-level failure at all -- 19 of 40 chunks in
one run and 18 in another, against the steady worker's 21 and 22 -- so the
only cost of the bad link was the round trip. What actually reaches the
application from a bad link is *delay* and *connection loss*, so those are the
knobs that test anything. This is worth knowing before tuning `NETEM_LOSS`
upward and believing it proves something.

**A 25-second blackout removes a worker permanently.** See
`docker-compose.partition.yml`, which asserts the opposite and therefore
**fails as of this commit**. Measured:

```
07:37:44.5  link goes dark
07:37:53.9  "host vanished before chunk 22 was accepted" -- worker exits
07:38:09.5  link comes back, 15.6 seconds too late for anyone to notice

== FAILED ==
  - jobs not covered exactly once: 145 rows, 145 distinct ids, expected 200
  - 11 of 40 chunks are not done
```

Reproduced on a second run, to the second.

One timed-out request ends the worker's participation for good, and because
that request was a submit, a finished chunk was discarded with it. Nothing
retries and nothing restarts. The fleet is still correct -- the lease lapses,
the chunk is reissued, every job lands exactly once -- but the machine is
gone. On the links this package is built for, that is the difference between
donating a laptop for an afternoon and babysitting an R session.

The fix is a bounded retry in `call()` in `R/join.R`, which currently treats
one timeout as proof the host is gone. That is a protocol change, not a
testbed change, so it is recorded here rather than made here.

## Worth adding next

**Killing a container mid-run** (`docker kill worker-floor`) is a more faithful
"machine died" than killing a process, and should leave the run completing via
lease expiry and reissue.

**Symmetric impairment.** netem shapes egress only, so a request/reply exchange
sees the delay and loss once rather than twice. Making it symmetric needs `ifb`
ingress redirection, which is a kernel module the testbed would then depend on.
