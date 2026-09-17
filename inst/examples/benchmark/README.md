# Benchmark workload

A workload with a runtime you can predict, for checking that distribution is
actually working and measuring what it buys you.

Each job burns a fixed number of CPU seconds, so the total work is exactly
`n jobs x seconds`. Every result records the machine and process that did it.

## Sizing the run

```r
jobR::jobr_estimate(n = 240, seconds = 1, cores = c(laptop_a = 4, laptop_b = 8))
#> benchmark estimate
#>   total work    : 240 jobs x 1s = 240 CPU-seconds
#>   one core alone: 240s (4 min)
#>   across 12 cores: ~20s  (perfect scaling; expect a little more)
```

Pick numbers that make the run long enough to watch but short enough to repeat:
240 jobs at 1 second is a good starting point.

## Running it

Host:

```r
library(jobR)
h <- host_new(system.file("examples/benchmark", package = "jobR"),
              jobs = jobr_benchmark_jobs(n = 240, seconds = 1),
              chunksize = 10,
              work_dir = "~/jobr-benchmark")
jobr_serve(h, "tcp://0.0.0.0:5555")
```

Every other machine:

```r
jobR::jobr_join("tcp://<host LAN address>:5555", "<passphrase>", cores = 4)
```

## Reading the result

```r
jobr_benchmark_report(host_results(h))
#>      host jobs cpu_seconds share
#> 1 laptop-b  156       156.4 0.650
#> 2 laptop-a   84        84.2 0.350
```

If the second machine contributed nothing, it never joined -- check
`jobr_doctor()` on the host and `jobr_ping()` on the worker.

## What to expect

Chunks are handed out one at a time on request, so a machine twice as fast
takes roughly twice as many, with no configuration. The split will not be exact:
the last chunks are lumpy, and a machine that joins late gets less. With
`chunksize = 10` and 24 chunks, expect the shares to be within about 10% of the
core ratio.
