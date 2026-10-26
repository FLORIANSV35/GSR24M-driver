#!/bin/bash
# Installs gsrd as a LaunchDaemon (system domain, so the HAL plug-in can reach its Mach service). Run: sudo ./install.sh
# Replaces the simulated card side (devsim) if it is installed. The HAL plug-in (hal/install.sh) must already be installed;
# it reconnects by itself, coreaudiod is not restarted. gsrd then owns the real card whenever it is connected.
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
launchctl bootout system/com.gsr24m.devsim 2>/dev/null || true
mkdir -p /usr/local/libexec
cp gsrd /usr/local/libexec/gsrd
chown root:wheel /usr/local/libexec/gsrd
cp com.gsr24m.gsrd.plist /Library/LaunchDaemons/com.gsr24m.gsrd.plist
chown root:wheel /Library/LaunchDaemons/com.gsr24m.gsrd.plist
chmod 644 /Library/LaunchDaemons/com.gsr24m.gsrd.plist
# stop a running gsrd first and wait until launchd has really let go of it (gsrd puts the card back on SIGTERM)
launchctl bootout system/com.gsr24m.gsrd 2>/dev/null || true
for i in $(seq 1 30); do launchctl print system/com.gsr24m.gsrd >/dev/null 2>&1 || break; sleep 0.5; done
sleep 1
for i in 1 2 3 4 5; do
  if launchctl bootstrap system /Library/LaunchDaemons/com.gsr24m.gsrd.plist 2>/dev/null; then break; fi
  echo "bootstrap not ready, retrying ($i)"; sleep 2
done
launchctl print system/com.gsr24m.gsrd >/dev/null 2>&1 && echo "gsrd is loaded" || { echo "gsrd is NOT loaded"; exit 1; }
echo "gsrd started. Log: tail -f /var/log/gsrd.log   Stop: sudo ./uninstall.sh"
