#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || { echo "Run this script as root." >&2; exit 1; }
command -v ip >/dev/null
if ip netns list | grep -q '^vanken-test\b' || ip link show vkn-host >/dev/null 2>&1; then
  echo "The Vanken test network already exists; run netns-teardown.sh first." >&2
  exit 1
fi

cleanup() {
  ip link delete vkn-host >/dev/null 2>&1 || true
  ip netns delete vanken-test >/dev/null 2>&1 || true
}
trap cleanup EXIT
ip netns add vanken-test
ip link add vkn-host type veth peer name vkn-ns
ip link set vkn-ns netns vanken-test
ip address add 192.0.2.1/24 dev vkn-host
ip link set vkn-host up
ip -n vanken-test address add 192.0.2.2/24 dev vkn-ns
ip -n vanken-test link set vkn-ns up
ip -n vanken-test link set lo up
trap - EXIT
