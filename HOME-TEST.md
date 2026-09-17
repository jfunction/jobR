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

*The host firewall.* Windows blocks inbound connections by default and drops
them **silently** — laptop B simply hangs and then times out. Allow the port
once, from an **admin** PowerShell on laptop A:

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

## 3. On laptop B — install

```r
install.packages(c("nanonext", "digest", "zip"))
```

Copy `jobR_0.2.0.tar.gz` across — USB stick, shared folder, `scp`, whatever is
easiest — then:

```r
install.packages("~/Downloads/jobR_0.2.0.tar.gz", repos = NULL, type = "source")
```

Laptop B needs jobR itself, and any packages your *project* uses. It does not
need the project's code: that travels automatically.

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

Start a second worker on laptop A too, in a *separate* R session, so both
machines contribute:

```r
jobR::jobr_join("tcp://127.0.0.1:5555", "canyon-drifting-walnut-embassy", cores = 4)
```

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
