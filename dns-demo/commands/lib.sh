#!/usr/bin/env bash
# Shared helpers for the demo-* operator commands. SOURCED, not executed.
#
# One name table for the ZPR `ph` processes in the dns-demo docker env, plus a
# single docker dispatch point (`on` / `on_tty`). Everything else in commands/
# is a thin wrapper over these. Copied from multinode-demo's lib.sh, pruned to
# docker-only dispatch: every process here runs in a local container.
#
# Each container runs one `ph zode`: the relay (which also hosts the visa
# service) and three endpoint Zodes linked to it. Names match the containers.
set -euo pipefail

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "lib.sh is a sourced library; run one of the demo-* commands" >&2
  exit 1
fi

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # dns-demo/
LOGS_DIR="$DEMO_DIR/local-compute/logs"

# The relay's substrate address: its docker-internal static IP
# (docker-compose.yml) and port. Every endpoint Zode's initial link dials it,
# and deploy-docker.sh renders it into the policy's relay node, which is where
# the visa service learns it. The endpoints' substrate addresses come from the
# relay: it reports the source address it sees on each initial link
# (zl-zipline#264). That is the container's own address, because they dial the
# relay's network address, which Docker does not NAT.
RELAY_SUBSTRATE_ADDR="172.30.1.10:5000"
# The relay's certificate CN: the name an endpoint's initial link expects.
RELAY_CN="node.demo"

# zode_cmd KEY ARGS... -- the `ph zode` command line for the Zode whose files
# in /conf/include/ are KEY-noise.{crt,key} (its link certificate and key) and
# KEY-private-key.pem (its RSA auth key), with ARGS appended.
zode_cmd() {
  local key="$1"; shift
  echo "/app/bin/ph zode --ca-file include/auth-ca.crt" \
    "--certificate-file include/$key-noise.crt --private-key-file include/$key-noise.key" \
    "--auth-private-key include/$key-private-key.pem --tun-if tun9 $*"
}

# --- the name table ---------------------------------------------------------
# TARGET  : container name
# SESSION : tmux session holding that ph (also the log basename)
# LOG     : path on THIS host (mounted volume)
# LAUNCH  : the command deploy-docker.sh (via demo-restart-ph) runs
# WD      : cwd for the tmux session
NAMES=(relay web client dns)

declare -A TARGET=(
  [relay]=relay [web]=web [client]=client [dns]=dns
)
declare -A SESSION=(
  [relay]=relay-zode [web]=web-zode [client]=client-zode [dns]=dns-zode
)
declare -A LOG=(
  [relay]="$LOGS_DIR/relay-zode.log"
  [web]="$LOGS_DIR/web-zode.log"
  [client]="$LOGS_DIR/client-zode.log"
  [dns]="$LOGS_DIR/dns-zode.log"
)
# The relay accepts the Zodes in its topology (--relay) and forwards their
# traffic (--forwarding); it lists its own address first and vs.zpr after it,
# as a relay that hosts the visa service must. Each endpoint has an initial
# link to the relay and its node's zpr_address from the policy.
declare -A LAUNCH=(
  [relay]="$(zode_cmd node --relay true --forwarding true --zpr-addr fd5a:5052:90de::10 --zpr-addr fd5a:5052::1)"
  [web]="$(zode_cmd web --initial-link "$RELAY_CN@$RELAY_SUBSTRATE_ADDR" --zpr-addr fd5a:5052:8888::80)"
  [client]="$(zode_cmd alice --initial-link "$RELAY_CN@$RELAY_SUBSTRATE_ADDR" --zpr-addr fd5a:5052:8888::13)"
  [dns]="$(zode_cmd dns --initial-link "$RELAY_CN@$RELAY_SUBSTRATE_ADDR" --zpr-addr fd5a:5052:8888::53)"
)
declare -A WD=(
  [relay]=/conf [web]=/conf [client]=/conf [dns]=/conf
)

# resolve NAME -- sets N_* for the caller, or lists the valid names and exits 2.
resolve() {
  local n="${1:-}"
  if [ -z "$n" ] || [ -z "${TARGET[$n]:-}" ]; then
    echo "error: unknown name: ${n:-<none>}" >&2
    echo "valid names: ${NAMES[*]}" >&2
    exit 2
  fi
  N_NAME="$n"
  N_TARGET="${TARGET[$n]}"; N_SESSION="${SESSION[$n]}"
  N_LOG="${LOG[$n]}";   N_LAUNCH="${LAUNCH[$n]}"; N_WD="${WD[$n]}"
  # The same log as the container sees it: N_LOG is this host's side of the
  # mounted volume, but a tee inside the container writes /logs/<session>.
  N_TLOG="/logs/$N_SESSION.log"
}

# on NAME cmd... / on_tty NAME cmd... -- the docker dispatch point.
# Args after NAME are joined into one command run under a shell in the container.
on()     { _dispatch "" "$@"; }
on_tty() { _dispatch tty "$@"; }

_dispatch() {  # $1=tty|"" $2=NAME $3...=command
  local tty="$1" name="$2"; shift 2
  resolve "$name"
  docker exec ${tty:+-it} "$N_TARGET" bash -lc "$*"
}

# tail_log NAME <tail-args...> -- logs are tee'd to a host-mounted volume,
# so no docker needed at all.
tail_log() {
  local n="$1"; shift
  resolve "$n"
  [ -f "$N_LOG" ] || { echo "error: no log at $N_LOG — has deploy-docker.sh run?" >&2; exit 1; }
  tail "$@" "$N_LOG"
}
