#!/bin/bash
# Replaces only the devsim binary of a running install and restarts that daemon (audio is not interrupted). Run: sudo ./update-sim.sh
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
cp devsim /usr/local/libexec/gsr24m-devsim
chown root:wheel /usr/local/libexec/gsr24m-devsim
launchctl kickstart -k system/com.gsr24m.devsim
echo "devsim restarted"
