#!/usr/bin/env bash
# Run a testbed scenario and exit with the host's verdict.
#
#   docker/run.sh docker/docker-compose.yml
#   docker/run.sh docker/docker-compose.netem.yml
#   docker/run.sh docker/docker-compose.netem.yml docker/docker-compose.partition.yml
#
# Why not `docker compose up --exit-code-from host`: that flag implies
# --abort-on-container-exit, which tears the run down as soon as ANY container
# stops. Workers stop before the host does -- one that has finished its share,
# one whose link has died, or simply the host waiting at the end to tell each
# worker the jobset is over. Compose then kills the host before it reaches its
# assertions and still reports success. A run that checks nothing and exits 0
# is worse than one that fails.
#
# So: start detached, stream the logs, and block on the host alone.
set -uo pipefail

cd "$(dirname "$0")/.."

files=()
for f in "$@"; do files+=(-f "$f"); done
if [ ${#files[@]} -eq 0 ]; then files=(-f docker/docker-compose.netem.yml); fi

# No teardown on exit: a failed run is the one worth inspecting, and `down -v`
# would delete the ledger and container logs that explain it. The next run
# starts by tearing down, so nothing accumulates, and CI tears down in an
# `if: always()` step.
cleanup() {
  if [ -n "${logs_pid:-}" ]; then kill "$logs_pid" 2>/dev/null; fi
}
trap cleanup EXIT

# Start from nothing, every time. A stopped container keeps its filesystem, so
# `up -d` restarts the previous run's host with the previous run's ledger still
# in /tmp/jobr-host. The ledger is append-only and replayed on open, so that
# host resumes where the old one stopped and counts its chunks as done -- which
# is correct behaviour for a restarted host, and indistinguishable from a clean
# pass for a test run.
docker compose "${files[@]}" down -v >/dev/null 2>&1
docker compose "${files[@]}" up --build -d --force-recreate --renew-anon-volumes || exit 1

docker compose "${files[@]}" logs -f &
logs_pid=$!

# `wait` blocks on this service alone and returns its exit code, so workers
# coming and going do not decide the result. The host is the only judge.
docker compose "${files[@]}" wait host
code=$?

sleep 1
echo "=== host exited with ${code} ==="
exit "$code"
