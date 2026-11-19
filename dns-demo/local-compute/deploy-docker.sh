#!/usr/bin/env bash
# Configure + run ZPR in the local docker env. Copied from multinode-demo's
# deploy-docker.sh, pruned to local-only: the relay's address is compose's
# static IP, so this script only renders the policy's @@...@@ token,
# generates vs_keys.toml, compiles the policy, brings the containers up, then
# launches the ZPR processes in order via `docker exec`.
#
#   ./deploy-docker.sh
#
# Every ZPR process is a `ph zode` (zl-zipline#235): the relay (node.demo),
# with the visa service on its own TUN beside it, and the web, client and dns
# endpoint Zodes, each with an initial link to the relay. Their command lines
# live in commands/lib.sh's name table, shared with the demo-* commands.
#
# Re-runnable: re-renders/recompiles every run, kills old tmux sessions first.
# Builds the zpr-dns-demo image itself, so `make` (to populate ../bin) is the
# only prerequisite.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # local-compute/
# shellcheck source=../commands/lib.sh
source "$SCRIPT_DIR/../commands/lib.sh"   # DEMO_DIR, LOGS_DIR, RELAY_SUBSTRATE_ADDR
CMDS="$DEMO_DIR/commands"
BIN_DIR="$DEMO_DIR/bin"
CONF_TMPL="$DEMO_DIR/zpr-conf/confs"
INC_DIR="$DEMO_DIR/zpr-conf/include"
ADMIN="$DEMO_DIR/zpr-conf/admin"
COMPOSE=(docker compose -f "$DEMO_DIR/docker-compose.yml")

CONF_ROOT="$SCRIPT_DIR/conf"        # per-container /conf mounts

# How long the relay gets to register with the visa service, in seconds.
REGISTER_SECONDS=30

echo "relay substrate=$RELAY_SUBSTRATE_ADDR"

# --- render: sub the token, fail loud on any leftover @@...@@ ---
render() {  # $1=template path  $2=output path
  sed -e "s#@@RELAY_SUBSTRATE_ADDR@@#${RELAY_SUBSTRATE_ADDR}#g" \
      "$1" > "$2"
  if grep -n '@@[A-Z0-9_]*@@' "$2"; then
    echo "ERROR: unresolved template token(s) above in $(basename "$2")" >&2
    exit 1
  fi
}

# --- Step 1: assemble per-container /conf dirs (whole include/ + per-role files) ---
# Re-runnable: take any previous stack down first (a bind mount pins the dir
# inode, so files written after an rm -rf of a mounted dir would be invisible
# inside a still-running container).
"${COMPOSE[@]}" down --remove-orphans 2>/dev/null || true
rm -rf "$CONF_ROOT"
mkdir -p "$LOGS_DIR"
for c in "${NAMES[@]}"; do
  mkdir -p "$CONF_ROOT/$c"
  cp -r "$INC_DIR" "$CONF_ROOT/$c/include"
done

cp "$CONF_TMPL/Corefile" "$CONF_ROOT/dns/Corefile"
cp "$SCRIPT_DIR/vs.toml" "$CONF_ROOT/relay/vs.toml"
cp "$ADMIN/attrfile.json" "$CONF_ROOT/relay/attrfile.json"   # policy attributes, read by vs
cp "$ADMIN/machines.json" "$CONF_ROOT/relay/machines.json"   # machine hostnames (zipline#55), read by vs

# --- Step 2: vs_keys.toml + client.key (operator key, used by commands/demo-vs-admin) ---
"$BIN_DIR/vsapikey" create --init readwrite client "$CONF_ROOT/relay/vs_keys.toml" > "$SCRIPT_DIR/client.key"
echo "client key written to $SCRIPT_DIR/client.key"

# Second key for the resolver: least privilege — `resolve` only (GET
# /admin/services*), appended to the same keys file, delivered to the dns
# container's /conf as a root-only file. The key string never lands in the
# Corefile or the image.
"$BIN_DIR/vsapikey" create resolve dns "$CONF_ROOT/relay/vs_keys.toml" > "$CONF_ROOT/dns/vs-resolve.key"
chmod 0600 "$CONF_ROOT/dns/vs-resolve.key"
echo "resolve key written to $CONF_ROOT/dns/vs-resolve.key"

# --- Step 3: compile policy on host (needs ../include keys the .zplc references) ---
render "$ADMIN/dns-demo.zplc.template" "$ADMIN/dns-demo.zplc"
( cd "$ADMIN" && "$BIN_DIR/zplc" --config dns-demo.zplc dns-demo.zpl )
mv "$ADMIN/dns-demo.bin2" "$CONF_ROOT/relay/dns-demo.bin2"

# --- Step 4: build the image, then bring up infra (entrypoints set up tun9 / valkey / nginx) ---
# Always build: docker's layer cache makes this a no-op unless the Dockerfile or
# bin/ changed, and bin/ is COPY'd in, so a rebuilt binary needs a rebuilt image.
docker build -t zpr-dns-demo "$DEMO_DIR"
"${COMPOSE[@]}" up -d
sleep 2

# --- Step 5: launch ZPR processes, each in a detached tmux, tee'd to /logs ---
# The Zodes go through demo-restart-ph, so a later restart runs exactly the
# command deploy ran. The visa service is not a Zode; it gets the same
# treatment here.
launch_vs() {
  docker exec relay tmux kill-session -t vs 2>/dev/null || true
  docker exec relay tmux new-session -d -s vs -c /conf \
    "/app/bin/vs --clear-state dns-demo.bin2 2>&1 | tee /logs/vs.log"
  sleep 1
  docker exec relay tmux has-session -t vs 2>/dev/null \
    && echo "[relay] vs running in tmux" \
    || { echo "ERROR: vs exited immediately in relay — see $LOGS_DIR/vs.log" >&2; exit 1; }
}

# The relay first, then the visa service on the relay's vs.zpr address (the
# netns harness's order: launch_relay, then launch_zode_vs). The relay keeps
# trying the visa service until it answers; wait for its registration before
# any endpoint Zode dials in, since the relay hands each joiner its bootstrap
# visas.
"$CMDS/demo-restart-ph" relay
launch_vs
registered=""
for _ in $(seq 1 "$REGISTER_SECONDS"); do
  if grep -q "registered VSS" "$LOGS_DIR/relay-zode.log" 2>/dev/null; then
    registered=1; break
  fi
  sleep 1
done
[ -n "$registered" ] \
  && echo "[relay] registered with the visa service" \
  || { echo "ERROR: the relay did not register with the visa service within ${REGISTER_SECONDS}s — see $LOGS_DIR/relay-zode.log and $LOGS_DIR/vs.log" >&2; exit 1; }

docker exec web curl -fsS http://localhost:80 >/dev/null \
  && echo "[web] nginx serving :80" \
  || { echo "ERROR: nginx not serving in web" >&2; exit 1; }
"$CMDS/demo-restart-ph" web
"$CMDS/demo-restart-ph" client
# The resolver's Zode, at zpr-dns's address. CoreDNS itself is the dns
# container's entrypoint, already running.
"$CMDS/demo-restart-ph" dns

cat <<EOF

Done. Local ZPR DNS demo env is up.
  Logs:   tail -f $LOGS_DIR/*.log
  Attach: docker exec -it <relay|web|client|dns> tmux attach -t <session>   (Ctrl-b d to detach)
  Teardown: ${COMPOSE[*]} down
EOF
