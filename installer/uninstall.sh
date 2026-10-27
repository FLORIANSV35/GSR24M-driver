#!/bin/sh
# Removes GSR24M from this Mac. Run: sudo /usr/local/libexec/gsr24m-uninstall.sh [--purge]
# --purge also deletes the channel names kept by the daemon. The names stored by the app in your own Library are never touched.
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
CUID=$(stat -f %u /dev/console)
[ -n "$CUID" ] && [ "$CUID" != "0" ] && launchctl bootout gui/$CUID/com.gsr24m.midiagent 2>/dev/null
launchctl bootout system/com.gsr24m.gsrd 2>/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do launchctl print system/com.gsr24m.gsrd >/dev/null 2>&1 || break; sleep 1; done
rm -f /Library/LaunchDaemons/com.gsr24m.gsrd.plist /usr/local/libexec/gsrd /Library/LaunchAgents/com.gsr24m.midiagent.plist /usr/local/libexec/gsrmidiagent
rm -rf /Library/Audio/Plug-Ins/HAL/GSR24M.driver /Applications/GSR24M.app
[ "$1" = "--purge" ] && rm -rf "/Library/Application Support/GSR24M"
pkgutil --forget com.gsr24m.pkg >/dev/null 2>&1
killall coreaudiod 2>/dev/null
rm -f /usr/local/libexec/gsr24m-uninstall.sh
echo "GSR24M removed."
