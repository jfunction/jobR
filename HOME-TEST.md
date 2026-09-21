# Testing jobR on two machines at home

A walkthrough for the simplest real deployment: two laptops on the same home
network. No VPN, no port forwarding, no accounts. Your router's NAT is only
between your network and the internet — inside the house the two machines can
reach each other directly, which is all jobR needs.

Budget about 30 minutes the first time, most of it installing packages.

Throughout, **laptop A** hosts and **laptop B** joins.

---

## 1. On laptop A — build and check the package

```r
install.packages(c("nanonext", "digest", "zip"))
```

From the repo directory:

```bash
R CMD build .
R CMD INSTALL jobR_0.2.0.tar.gz
```

Keep `jobR_0.2.0.tar.gz` — you will copy it to laptop B in step 3.

If the install fails with `Permission denied` on a file R just created, that is
antivirus, not the package, and it is intermittent — see
["If the install fails"](#if-the-install-fails-with-permission-denied) in step 3.

Confirm it works locally before involving the network:

```r
library(jobR)
jobr_check_project(system.file("examples/benchmark", package = "jobR"))
#> project looks good: benchmark (1 file(s), entrypoint R/run.R)
```

## 2. On laptop A — preflight

```r
jobR::jobr_doctor(port = 5555)
```

This prints the addresses laptop B should dial, confirms the port is bindable,
and — on Windows — gives you the firewall command. Read its output before
continuing; it is the step that saves the most time.

**Two things go wrong here more than anything else.**

*Listening on loopback.* The URL must be `tcp://0.0.0.0:5555`. `127.0.0.1`
accepts connections only from laptop A itself, and gives no hint that it is
doing so.

*The host firewall.* This may well not bother you. The first time R listens on
a port, Windows usually pops up "Allow R to communicate on these networks?" —
say yes and you are done. A rule may also already exist from earlier R use.

You only need to intervene when there is no prompt *and* laptop B cannot
connect, because a blocked inbound connection fails **silently**: laptop B
simply hangs and times out. If that happens, allow the port from an **admin**
PowerShell on laptop A:

```powershell
New-NetFirewallRule -DisplayName "jobR" -Direction Inbound -Protocol TCP -LocalPort 5555 -Action Allow -Profile Private
```

`-Profile Private` limits this to networks you have marked as private. If your
home network is set to "Public" in Windows, either change it to Private or the
rule will not apply. Remove the rule when you are done:

```powershell
Remove-NetFirewallRule -DisplayName "jobR"
```

On macOS, the firewall will prompt for permission the first time — allow it. On
Linux with `ufw`: `sudo ufw allow from 192.168.0.0/16 to any port 5555`.

## 3. On laptop B — check the R version, then install

```r
R.version.string
```

**If it says R 4.0 or newer, skip to "Install" at the end of this step.** Otherwise read this
section — it is the most common reason a second machine will not join.

### Why an old R is a problem, and what kind of problem

jobR itself requires only **R 3.6**, which is the floor its dependencies set,
not an arbitrary one. Refusing a working machine for no technical reason is
exactly what this package exists to avoid, so the language version is rarely
the real obstacle.

The obstacle is **binaries**. CRAN builds Windows and macOS binaries only for
the current R and the one before it. `nanonext` needs compiling — it bundles
the NNG and mbedTLS C libraries — so on R 3.6 there is no binary to download
and `install.packages("nanonext")` falls back to building from source. On
Windows that means Rtools 3.5 and a C toolchain that has to compile two C
libraries successfully. It sometimes works. It is not what you want standing
between you and a first test.

### First: look for another R already on the machine

Before downloading anything, check. Machines used for R work over several years
often have a few versions lying around, and one may already be new enough:

```r
# Windows: R installs live side by side here
list.files("C:/Program Files/R")
```

This is the path of least resistance, and it is what worked on the machine this
guide was tested against — it turned out to have R 3.6.3 **and** R 4.0.5 with
Rtools40 already installed. Switching to the 4.0.5 was enough: no download, no
admin rights, no compiler wrangling.

Rtools has to match the R you use (Rtools40 goes with R 4.0–4.1, Rtools 3.5
with R 3.6), which is a further reason to prefer an R that already has a working
toolchain beside it.

### Otherwise: install a current R alongside the old one

On Windows, R versions install **side by side** in separate directories. A new
R does not replace or disturb R 3.6.3, and anything that depends on 3.6.3 keeps
working:

1. Download the current R from
   <https://cran.r-project.org/bin/windows/base/>
2. Install it. If you lack admin rights, choose a directory inside your user
   folder — no elevation is needed.
3. Open the **new** R (the Start Menu will list both) and continue below.

If laptop B has RStudio, pick the version under Tools → Global Options → General
→ R version, and restart.

### If you genuinely cannot get a newer R

Then jobR will still work in principle, but you have to get `nanonext` built:

- **Windows**: install [Rtools 3.5](https://cran.r-project.org/bin/windows/Rtools/history.html)
  (the version matching R 3.6, *not* the current Rtools), then
  `install.packages("nanonext", type = "source")`. Expect a long compile and
  be ready for it to fail.
- **Linux**: usually easier. `install.packages("nanonext")` builds from source
  by default anyway; you need a C compiler and `make`, which most distributions
  already have.

Whichever route you take, mixed versions are supported — but read
"Mismatched R versions" below before running a real workload, because there is
one difference that changes results silently rather than failing loudly.

### Install

```r
install.packages(c("nanonext", "digest", "zip"))
install.packages("mirai")   # only needed if you will pass cores > 1
```

**Install `mirai` if you intend to use more than one core on this machine.**
jobR uses it to spread a chunk across the worker's own cores, and it is
Suggested rather than required so that a minimal machine can still contribute.
Without it, `jobr_join(cores = 4)` tells you so at join time and runs one job
at a time instead.

Copy `jobR_0.2.0.tar.gz` across — USB stick, shared folder, `scp`, whatever is
easiest — then:

```r
install.packages("~/Downloads/jobR_0.2.0.tar.gz", repos = NULL, type = "source")
```

Laptop B needs jobR itself, and any packages your *project* uses. It does not
need the project's code: that travels automatically.

### If the install fails with "Permission denied"

On Windows — especially a managed or work laptop — an install can fail like
this, on a file R created a fraction of a second earlier:

```
Error in lazyLoadDBinsertListElement(...) :
  cannot open file '.../00LOCK-jobR/00new/jobR/help/jobR.rdb': Permission denied
ERROR: installing Rd objects failed for package 'jobR'
```

Nothing is wrong with the package. An on-access scanner — Defender, or
corporate endpoint protection — opens newly written files to inspect them, and
for a moment R cannot reopen its own file. It is intermittent: the same command
run three times in a row will typically succeed, fail, then succeed.

**Just try again.** If you would rather not play dice:

```r
# Retry a few times; each attempt is independent of the last.
for (i in 1:5) {
  try(install.packages("jobR_0.2.0.tar.gz", repos = NULL, type = "source"),
      silent = TRUE)
  if (nzchar(system.file(package = "jobR"))) break
  Sys.sleep(2)
}
packageVersion("jobR")
```

The proper fix is an antivirus exclusion for your R library directory
(`.libPaths()[1]`), which on a work machine usually means asking IT. Worth it
if you install packages often; not worth it for one test.

Do **not** reach for `R CMD INSTALL --no-help` to dodge it. That skips building
the help database, which is the step that fails — but it also throws away
`?jobR.dcf` and `?versions`, and those are the two pages you are most likely to
want while setting this up.

This same scanner behaviour is why jobR retries its own ledger writes; see
`?ledger`. The running system already handles it. Only installation does not,
because that happens before jobR is there to defend itself.

## 4. Size the run

On laptop A, decide how much work to do. Count the physical cores you intend to
contribute on each machine:

```r
parallel::detectCores()   # run on both; it reports logical cores
```

```r
jobR::jobr_estimate(n = 240, seconds = 1, cores = c(laptop_a = 4, laptop_b = 4))
#> benchmark estimate
#>   total work    : 240 jobs x 1s = 240 CPU-seconds
#>   one core alone: 240s (4 min)
#>   across 8 cores: ~30s  (perfect scaling; expect a little more)
```

240 jobs at one second each is a good first run: long enough to watch the split
happen, short enough to repeat while you experiment.

## 5. Start the host

```r
library(jobR)

h <- host_new(
  system.file("examples/benchmark", package = "jobR"),
  jobs      = jobr_benchmark_jobs(n = 240, seconds = 1),
  chunksize = 10,
  work_dir  = "~/jobr-benchmark"        # NOT the default tempdir()
)

jobr_serve(h, "tcp://0.0.0.0:5555")
#> jobR host listening on tcp://0.0.0.0:5555
#>   project   : benchmark
#>   jobs      : 240 in 24 chunks
#>   passphrase: canyon-drifting-walnut-embassy
```

Set `work_dir` to a real directory. The default is under `tempdir()`, which R
deletes when it exits — fine for a demo, wrong for anything you want to resume.

Write down the passphrase. This call blocks until the work is finished.

## 6. Join from laptop B

Check the network first, so that a failure tells you *which* thing failed:

```r
jobR::jobr_ping("tcp://192.168.1.5:5555")
#> connected to 'benchmark': 240 jobs in 24 chunks -- ready to join
```

If that reports no reply, it is the firewall or the address — not jobR. If it
reports a refusal, the network is fine and it is the passphrase.

Then:

```r
jobR::jobr_join("tcp://192.168.1.5:5555", "canyon-drifting-walnut-embassy", cores = 4)
```

### Laptop A can work too

Hosting and working are separate roles, and one machine can do both. The host
process itself only hands out chunks and records results — it does no
computation — so laptop A's cores sit idle unless you also join from it.

Open a **separate** R session on laptop A (the hosting session is blocked
inside `jobr_serve()`) and join over loopback:

```r
jobR::jobr_join("tcp://127.0.0.1:5555", "canyon-drifting-walnut-embassy", cores = 4)
```

It is an ordinary worker in every respect: it claims chunks, holds leases, and
shows up separately in the report. You can run several on one machine if you
prefer that to `cores`.

## 7. Read the result

When the host returns:

```r
jobr_benchmark_report(host_results(h))
#>      host jobs cpu_seconds share
#> 1 laptop-b  128       128.4 0.533
#> 2 laptop-a  112       112.1 0.467
```

Compare the wall-clock time against the estimate from step 4. Chunks are handed
out on request, so a faster machine takes more of them without being told to;
the split will not be exact, because the last chunks are lumpy and whoever joins
late gets fewer.

---

## Mismatched R versions

Different machines running different R versions is normal here, and mostly
fine. jobR records what each worker reports and tells you when they differ:

```r
jobR::jobr_join(url, passphrase)
#> joined 'benchmark': 240 jobs in 24 chunks
#> note: this worker runs R 3.6.3; the host runs R 4.5.3
```

One difference is worth real attention, because it changes results rather than
failing. **R 4.0.0 changed `data.frame()` to default `stringsAsFactors = FALSE`;
before that it defaulted to `TRUE`.** So a `run_job()` that builds a data frame
with a character column returns **characters** on a worker running R 4.x and
**factors** on a worker running R 3.6 — same code, same bundle.

That is worse than it sounds for two reasons:

```r
# The combined type depends on which chunk arrives first, and in a distributed
# run that is whichever machine happened to finish first:
class(rbind(char_chunk, factor_chunk)$label)   # "character"
class(rbind(factor_chunk, char_chunk)$label)   # "factor"

# And a factor's as.numeric() gives the level code, not the value:
as.numeric(factor("2024"))                     # 1, not 2024
```

So the same jobset can produce differently-typed results on two runs of the
same work, and a column of numeric-looking strings can silently become 1, 2, 3.

The fix is one argument, and it belongs in every project regardless of which
machines you expect:

```r
run_job <- function(row) {
  data.frame(id = row$id, label = "whatever", stringsAsFactors = FALSE)
}
```

Both shipped examples do this, and `jobr_new_project()` writes it into the stub.
`?versions` has the full explanation.

---

## Things worth trying once it works

**Kill a worker mid-run.** Close laptop B's lid, or Ctrl-C its R session, while
chunks are in flight. Its chunk is not lost: the lease lapses (default five
minutes — pass `lease_seconds = 30` to `host_new()` to watch it happen sooner)
and the work is reissued. The run still completes with all 240 jobs.

**Kill the host.** Stop laptop A's R session mid-run, then start it again with
the same `work_dir` and the same passphrase. It reads the ledger, resumes from
where it stopped, and reissues anything that was in flight. Nothing already
finished is recomputed.

**Watch the ledger.** It is a plain text file, readable while the run is going:

```bash
tail -f ~/jobr-benchmark/ledger.tsv
```

**Change the project and rejoin.** Edit `R/run.R`, restart the host, and rejoin
from laptop B. It notices the content hash changed and re-fetches. Rejoin again
without changing anything and it says `project bundle already current` and
transfers nothing.

**Try your own project.** `jobr_new_project("~/mysim")` writes a commented
manifest and a stub entrypoint; `jobr_check_project("~/mysim")` tells you what
is wrong before anyone else has to find out.

---

## If it does not work

| Symptom | Cause |
|---|---|
| `jobr_ping` reports no reply | Host firewall, or host listening on `127.0.0.1` |
| Worker connects then refuses | Wrong passphrase — case and spacing are ignored, so it is a real mismatch |
| `missing packages the project needs` | Install them on the worker; jobR ships code, not packages |
| Host says `port could not be bound` | Something else is on 5555; pick another port |
| Worker does nothing, host shows no progress | Check they are on the same subnet: both addresses should start the same, e.g. `192.168.1.` |
| `nanonext` will not install on the worker | R older than 4.0 -- see step 3 |
| Install fails: `Permission denied` on `jobR.rdb` | Antivirus holding a just-written file; intermittent, just retry -- see step 3 |
| `cores = N` runs one job at a time anyway | `mirai` not installed on that worker; `install.packages("mirai")` |
| Worker stops: `giving up after N chunks failed in a row` | That machine is misconfigured, not the work -- read the last error it printed |
| Results have factors where you expected strings | A worker on R 3.6 and a missing `stringsAsFactors = FALSE` -- see "Mismatched R versions" |
