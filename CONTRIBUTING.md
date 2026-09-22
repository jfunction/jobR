# Contributing to jobR

Contributions are welcome, and so are bug reports from anyone who tried this on
real machines and found it wanting — those are the most valuable thing this
project can receive right now.

## The most useful thing you can report

jobR has been run on a great many containers and on very few real machines. If
you try it across two physical computers, especially across the internet or on a
slow or intermittent link, **please open an issue saying what happened** — even
if it worked. Particularly useful:

- what the two machines were, and what R version each had
- how they reached each other (same LAN, port forward, Tailscale, a tunnel)
- where the instructions in `HOME-TEST.md` were wrong, unclear, or assumed
  something you did not have
- anything that failed silently rather than telling you why

Reports from restricted, low-bandwidth or older setups are more useful than
reports from well-resourced ones, because those are the setups the package
exists for and the ones it is least likely to have been tested against.

## Running the tests

```bash
# unit, property and protocol tests -- fast, no network
Rscript -e 'testthat::test_dir("tests/testthat")'

# plus integration tests: real processes, real sockets, deterministic faults
JOBR_INTEGRATION=1 NOT_CRAN=true Rscript -e 'testthat::test_dir("tests/testthat")'
```

The containerised testbed needs Docker, and runs several R versions against each
other over a real network:

```bash
docker/run.sh docker/docker-compose.yml                    # version matrix
docker/run.sh docker/docker-compose.netem.yml              # a bad link
docker/run.sh docker/docker-compose.netem.yml \
              docker/docker-compose.partition.yml          # a link that dies
```

See `docker/README.md` for what each scenario asserts and why it is built that
way.

## What this project values in a change

- **A test that would have failed before it.** For anything touching the ledger,
  leasing or the protocol, this is not optional: those are the parts where a bug
  silently corrupts results rather than raising an error.
- **Tests that are known to discriminate.** Where practical, run a new test
  against the unfixed behaviour too and confirm it fails. A distributed-systems
  test that passes either way is worse than none, because it looks like evidence.
- **Determinism over timing.** Faults are injected at points the job itself
  signals through the filesystem, and time is compressed rather than waited on.
  See `tests/testthat/helper-integration.R`.
- **Honesty about evidence.** `DESIGN.md` distinguishes what is verified, how,
  and what is not demonstrated at all. Please keep that table accurate rather
  than optimistic; moving a claim into the "not demonstrated" column is a
  perfectly good contribution.
- **No new hard dependencies** without a clear argument. The target deployment is
  a machine that may be old, metered, offline much of the time, or administered
  by somebody else. A dependency on a paid service, or on a network the user
  does not control, is a change of what the package is for.

## Documentation conventions

`DESIGN.md` states the current design in the present tense. When something
changes, edit the statement rather than appending a correction, so that there is
exactly one account of how each thing works. It deliberately holds no line
counts, file inventories or figures from particular runs, because those go stale
silently.

Comments explain why the code is as it is. They are not a development log.

## Before opening a pull request

```bash
Rscript -e 'roxygen2::roxygenise(".")'
Rscript -e 'rcmdcheck::rcmdcheck(args = c("--no-manual", "--as-cran"))'
```

`R CMD check` currently reports four NOTEs, none of them actionable: an
unverifiable system time, temporary files left by `callr`, a `NULL` file the
toolchain writes into the check directory, and one deliberate assignment to a
mirai daemon's global environment, which static analysis cannot tell from an
assignment in the user's session.

## Code of conduct

Participants are expected to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).
