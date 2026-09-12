# jobR

Run a batch of independent jobs across whatever machines you already have.

No cloud account. No scheduler. No paid service. No mandatory VPN. Two machines
on a LAN is a complete, supported deployment.

```r
# on the machine holding the work
h <- jobR::host_new("~/myproject", jobs = my_params, chunksize = 25)
jobR::jobr_serve(h, "tcp://0.0.0.0:5555")
#> jobR host listening on tcp://0.0.0.0:5555
#>   jobs      : 1000 in 40 chunks
#>   passphrase: canyon-drifting-walnut-embassy
```

```r
# on every other machine, including your colleague's, in another country
jobR::jobr_join("tcp://192.168.1.5:5555", "canyon-drifting-walnut-embassy")
```

That is the whole interface. The worker authenticates, discovers what the
project needs, fetches the code only if its cached copy is out of date, refuses
to start if it is missing a package, and then pulls chunks until the work runs
out.

## Why this exists

The R ecosystem solved distributed compute well, but it solved it for people
with institutional infrastructure. `crew` has launcher plugins for SLURM, SGE,
LSF, PBS and AWS Batch. It has none for "four laptops and a switch". That gap is
structural rather than accidental: in [crew discussion #191][d191] the
maintainer agrees the demand is obvious and explains he cannot build it, because
his own workplace restricts SSH and Docker enough that he cannot develop against
it. People with SLURM allocations do not write software for people without them.

So jobR targets the case that ecosystem leaves out:

- **A LAN is a first-class deployment.** No overlay network required, nothing to
  sign up for. Networking across the internet is a documented deployment choice
  (port forwarding, [Headscale][hs], a thin VPS, Tailscale, an SSH tunnel) and
  never a dependency.
- **Bandwidth is the scarce resource, not CPU.** Bundles are content-addressed,
  so a returning worker transfers nothing when the project has not changed.
- **Intermittency is normal.** Power cuts, closed lids, dropped links. Work is
  leased, not merely sent, so anything abandoned is reissued automatically.
- **Credentials are speakable.** A passphrase you can read down a phone line
  beats a certificate you have to transfer somehow first.

## How it fits with mirai

jobR does not reimplement parallel computing, and you should not use it where
`mirai` or `crew` already fit. The split is:

- **`mirai` moves work between cores.** Each jobR worker uses it locally, via
  `jobr_join(cores = 4)`, to use its own machine fully.
- **jobR moves work between machines**, and adds the operator envelope that
  `mirai` deliberately does not have: enrolment, code integrity, a durable
  ledger, and requeue-on-disconnect.

If your machines are already a SLURM cluster, use `crew`. If your host session
will reliably stay alive and everyone already has the packages, plain `mirai` is
simpler and faster. jobR earns its place when workers are unreliable and the
people running them should not have to be told what to install.

## Setting up a project

A project is a directory with a `jobR.dcf` manifest:

```
Project: mysim
Entrypoint: R/run.R
Files: R/run.R, R/helpers.R, data/lookup.csv
Lockfile: renv.lock
```

The entrypoint must define `run_job(row)`, taking one row of your jobs data
frame and returning whatever you want back:

```r
run_job <- function(row) {
  data.frame(id = row$id, estimate = simulate(row$n, row$seed))
}
```

The manifest is declarative on purpose. A worker has to discover what a project
needs *before* running any of that project's code, so the list of files and the
lockfile cannot live inside an R script that must be sourced to be read.

## Security, stated plainly

The passphrase authenticates workers to the host over an encrypted channel.
`host_credentials()` provides TLS for confidentiality and lets a worker confirm
it is talking to the host it expects.

**Workers are not authenticated by certificate.** The original design called for
mutual TLS, and `nanonext::tls_config()` exposes an `auth` argument that looks
like it should provide it. On nanonext 1.6.1 a listener configured with
`auth = TRUE` rejected every client tested, including ones presenting a
certificate from the CA that listener itself held. So client-certificate
authentication is not available through the public API today, and the passphrase
carries that weight instead.

The practical consequence: anyone who obtains the passphrase can contribute work
and read the jobs they are handed. That is fine among colleagues. It is not a
model for accepting compute from strangers. On a hostile network, put jobR
behind something that does device-level identity properly.

## Networking

| Situation | What you need | Cost |
|---|---|---|
| Same LAN | Nothing. `tcp://192.168.1.5:5555` | Free |
| One side routable | Port forward + dynamic DNS | Free |
| Neither routable | [Headscale][hs] (self-hosted), a thin VPS, an SSH reverse tunnel, or Tailscale | Free to a few dollars a month |

jobR does not know or care which of these you use. It takes a URL.

## Tests

```bash
Rscript -e 'testthat::test_dir("tests/testthat")'          # unit tests only
JOBR_INTEGRATION=1 NOT_CRAN=true Rscript -e 'testthat::test_dir("tests/testthat")'
```

Integration tests run a real host and real workers as separate OS processes over
real sockets. See [`tests/testthat/helper-integration.R`](tests/testthat/helper-integration.R)
for the reasoning; the short version is that distributed-systems tests are only
worth having if they are deterministic, so faults are injected at points the job
itself signals rather than on a timer, time is compressed instead of waited on,
and the ledger is checked against invariants that must hold however the
processes happened to interleave.

[d191]: https://github.com/wlandau/crew/discussions/191
[hs]: https://github.com/juanfont/headscale
