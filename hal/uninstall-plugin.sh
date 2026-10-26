#!/bin/bash
# Removes only the HAL plug-in. Restarts coreaudiod. Run: sudo ./uninstall-plugin.sh
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/GSR24M.driver
killall coreaudiod 2>/dev/null
echo "plug-in removed"
