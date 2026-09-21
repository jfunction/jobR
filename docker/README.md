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

## Worth adding next

**Network impairment.** Give a worker `cap_add: [NET_ADMIN]` and shape its link
with `tc netem` — latency, loss, a partition:

```bash
tc qdisc add dev eth0 root netem delay 200ms loss 5%
```

Intermittency is the condition this package is built for, and right now it is
tested by hoping rather than by asserting. That is the highest-value addition
here.

**Killing a container mid-run** (`docker kill worker-floor`) is a more faithful
"machine died" than killing a process, and should leave the run completing via
lease expiry and reissue.
