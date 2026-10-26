#!/bin/bash
# Removes what install.sh put on the system. Run: sudo ./uninstall.sh. Restarts coreaudiod.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
launchctl bootout system/com.gsr24m.devsim 2>/dev/null
rm -f /Library/LaunchDaemons/com.gsr24m.devsim.plist /usr/local/libexec/gsr24m-devsim
rm -rf /Library/Audio/Plug-Ins/HAL/GSR24M.driver
killall coreaudiod 2>/dev/null
echo "removed"
