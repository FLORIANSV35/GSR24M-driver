#!/bin/bash
# Installs the spike. Needs administrator rights (run: sudo ./install.sh). Restarts coreaudiod: audio on this Mac cuts for a few seconds.
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
mkdir -p /usr/local/libexec
cp gsr24m-spike-helper /usr/local/libexec/gsr24m-spike-helper
chown root:wheel /usr/local/libexec/gsr24m-spike-helper
cp com.gsr24m.spike.plist /Library/LaunchDaemons/com.gsr24m.spike.plist
chown root:wheel /Library/LaunchDaemons/com.gsr24m.spike.plist
chmod 644 /Library/LaunchDaemons/com.gsr24m.spike.plist
launchctl bootout system/com.gsr24m.spike 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.gsr24m.spike.plist
rm -rf /Library/Audio/Plug-Ins/HAL/GSRSpike.driver
cp -R GSRSpike.driver /Library/Audio/Plug-Ins/HAL/GSRSpike.driver
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/GSRSpike.driver
sleep 1
killall coreaudiod || true
echo "installed. Wait 10 seconds, then read the results:"
echo "  log show --last 3m --info --predicate 'eventMessage CONTAINS \"GSRSPIKE\"' | cut -c1-260"
echo "  cat /tmp/gsr24m-spike-helper.log"
