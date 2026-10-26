#!/bin/bash
# Removes everything install.sh put on the system (run: sudo ./uninstall.sh). Restarts coreaudiod.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
launchctl bootout system/com.gsr24m.spike 2>/dev/null
rm -f /Library/LaunchDaemons/com.gsr24m.spike.plist /usr/local/libexec/gsr24m-spike-helper
rm -rf /Library/Audio/Plug-Ins/HAL/GSRSpike.driver "/Library/Application Support/GSR24M"
rm -f /var/tmp/gsr24m-spike 2>/dev/null
killall coreaudiod 2>/dev/null
echo "removed"
