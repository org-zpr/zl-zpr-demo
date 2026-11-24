#!/bin/sh
# relay: bring up tun9 with both of the relay's ZPR addresses -- its own
# (node.demo) first, then vs.zpr (fd5a:5052::1), where the visa service
# listens -- start valkey, then idle. The relay `ph zode` and the `vs` process
# are launched by deploy-docker.sh via `docker exec`.
#
# The addresses go on before ph starts, so a restarted ph never takes vs.zpr
# away from a running visa service (ph adds only missing addresses and never
# removes one). Each is a /32: it routes the whole fd5a:5052::/32 ZPR space
# into the TUN, and two addresses with one prefix still give one route.
set -e

mkdir -p /var/run/zpr   # ph control socket lives here

ip tuntap add name tun9 mode tun multi_queue
ip link set tun9 mtu 1400
ip addr add fd5a:5052:90de::10/32 dev tun9
ip addr add fd5a:5052::1/32 dev tun9
ip link set tun9 up

# Loopback only: valkey has no password, and the relay's TUN carries every
# Zode's traffic.
echo "starting valkey on 127.0.0.1:6379"
valkey-server --bind 127.0.0.1 --port 6379 &

exec sleep infinity
