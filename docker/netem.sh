#!/bin/sh
# Shape the link of the container whose network namespace this one shares.
#
# This runs as a sidecar rather than inside the worker image on purpose. The
# worker images must stay free of an apt layer -- rocker/r-ver:3.6.3 is built
# on Debian buster, which is end-of-life and whose archive 404s -- so `tc`
# cannot be installed there at all. Sharing the namespace from a small Alpine
# container keeps every R image untouched and lets any worker be impaired,
# including the 3.6.3 one.
#
# Scope: netem shapes EGRESS only. The worker's requests are
# delayed and dropped; the host's replies arrive clean. A request/reply
# exchange therefore sees the full delay once and the full loss once, which is
# the behaviour that matters here. It is not a symmetric bad link; making it
# one needs ifb ingress redirection, and that is a kernel module this testbed
# should not assume.
set -e

IFACE=${NETEM_IFACE:-eth0}
DELAY=${NETEM_DELAY:-150ms}
JITTER=${NETEM_JITTER:-50ms}
LOSS=${NETEM_LOSS:-5%}
RATE=${NETEM_RATE:-}
PARTITION_AT=${NETEM_PARTITION_AT:-0}
PARTITION_FOR=${NETEM_PARTITION_FOR:-0}

# Built with `if`, not `[ ... ] && ...`. Under `set -e` an AND-OR list whose
# test fails takes the whole script down in some shells, so an empty NETEM_RATE
# would kill the sidecar before it shaped anything -- and the worker would then
# sit at its gate until the run timed out, blaming the host.
spec="delay ${DELAY}"
if [ -n "$JITTER" ]; then spec="${spec} ${JITTER}"; fi
if [ -n "$LOSS" ]; then spec="${spec} loss ${LOSS}"; fi
if [ -n "$RATE" ]; then spec="${spec} rate ${RATE}"; fi

echo "== netem =="
echo "  iface    : ${IFACE}"
echo "  shaping  : ${spec}"

# A leftover qdisc from a previous run in the same namespace would make `add`
# fail, and a sidecar that exits leaves the worker unimpaired while the test
# still claims it was.
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root netem ${spec}
tc qdisc show dev "$IFACE"

# No sentinel is written. The worker gates itself on an observably slow round
# trip (JOBR_REQUIRE_RTT_MS in worker.R), which cannot go stale the way a file
# in a shared volume can, and which fails loudly if this sidecar never ran.

if [ "$PARTITION_FOR" -gt 0 ] 2>/dev/null; then
  echo "  partition: 100% loss at +${PARTITION_AT}s for ${PARTITION_FOR}s"
  sleep "$PARTITION_AT"
  echo "== netem: partition starts =="
  tc qdisc change dev "$IFACE" root netem loss 100%
  sleep "$PARTITION_FOR"
  echo "== netem: partition ends, back to ${spec} =="
  tc qdisc change dev "$IFACE" root netem ${spec}
fi

# Stay alive while there is anything to shape. If the worker exits -- which in
# the partition scenario it does, and too early, which is the point -- its
# network namespace goes with it, the `tc qdisc change` above fails, and
# `set -e` ends this container too. That is the right outcome: a sidecar
# shaping a namespace that no longer exists has nothing to do.
while true; do sleep 3600; done
