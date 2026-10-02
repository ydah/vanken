#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || { echo "Run this script as root." >&2; exit 1; }
ip link delete vkn-host >/dev/null 2>&1 || true
ip netns delete vanken-test >/dev/null 2>&1 || true
