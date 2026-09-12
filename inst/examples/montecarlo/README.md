# Worked example: Monte Carlo estimation of pi

From the host machine:

```r
library(jobR)

jobs <- data.frame(id = 1:1000, n = 1e6, seed = 1:1000)
h <- host_new(system.file("examples/montecarlo", package = "jobR"),
              jobs = jobs, chunksize = 25)
jobr_serve(h, "tcp://0.0.0.0:5555")
```

Note the passphrase it prints. On every other machine:

```r
jobR::jobr_join("tcp://<host address>:5555", "<passphrase>", cores = 4)
```

When it finishes, back on the host:

```r
results <- do.call(rbind, lapply(host_results(h), function(x) do.call(rbind, x)))
mean(results$estimate)
```

Stop any worker whenever you like and start it again later; its chunk is
reissued and nothing is lost. Kill the host and restart it against the same
`work_dir` and it resumes from the ledger.
