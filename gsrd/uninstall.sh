#!/bin/bash
# Stops and removes gsrd (it puts the card back to idle, releases OWNER and restores the clock when it gets SIGTERM). Run: sudo ./uninstall.sh
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
launchctl bootout system/com.gsr24m.gsrd 2>/dev/null
sleep 2
rm -f /Library/LaunchDaemons/com.gsr24m.gsrd.plist /usr/local/libexec/gsrd
echo "removed (the HAL plug-in stays: hal/uninstall.sh removes it)"
