#!/usr/bin/env bash
# Run a testbed scenario and exit with the host's verdict.
#
#   docker/run.sh docker/docker-compose.netem.yml
#   docker/run.sh docker/docker-compose.netem.yml docker/docker-compose.partition.yml
#
# `up --exit-code-from host` was the whole harness until the impaired scenario
# arrived, and it cannot be any more. That flag implies
# --abort-on-container-exit, which tears the run down the moment ANY container
# stops -- including a worker that has legitimately finished, or one that has
# dropped out because its link died, which is the very thing the impaired
# scenario exists to observe. It aborted a run at 26 of 40 chunks and reported
# success, because the host never reached its assertions at all.
#
# So: start detached, stream the logs for a human, and block on the host alone.
set -uo pipefail

cd "$(dirname "$0")/.."

files=()
for f in "$@"; do files+=(-f "$f"); done
if [ ${#files[@]} -eq 0 ]; then files=(-f docker/docker-compose.netem.yml); fi

# Deliberately does NOT tear the stack down. A failed run is the one you want
# to look at, and `down -v` would delete the ledger and the container logs
# that explain it. The next run starts with `down -v` anyway, so nothing
# accumulates; CI tears down in an `if: always()` step.
cleanup() {
  if [ -n "${logs_pid:-}" ]; then kill "$logs_pid" 2>/dev/null; fi
}
trap cleanup EXIT

# Start from nothing, every time. A stopped container keeps its filesystem, so
# `up -d` will happily restart the previous run's host with the previous run's
# ledger still in /tmp/jobr-host -- and because the ledger is append-only and
# replayed on open, that host resumes where the old one left off and counts
# its chunks as done. It looks exactly like a pass. It caught me once: a run
# reported "all 40 chunks done" while its two workers between them had
# processed ten.
docker compose "${files[@]}" down -v >/dev/null 2>&1
docker compose "${files[@]}" up --build -d --force-recreate --renew-anon-volumes || exit 1

docker compose "${files[@]}" logs -f &
logs_pid=$!

# `wait` blocks on this service alone and returns its exit code, so workers
# coming and going no longer decide the result. The host is the only judge.
docker compose "${files[@]}" wait host
code=$?

sleep 1
echo "=== host exited with ${code} ==="
exit "$code"
