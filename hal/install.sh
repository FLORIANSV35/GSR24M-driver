#!/bin/bash
# Installs the HAL plug-in and the development stand-in for gsrd (devsim, NOT the card). Run: sudo ./install.sh
# Restarts coreaudiod: audio on this Mac cuts for a few seconds. A device "GS-R24M FireWire" appears; it is simulated.
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
mkdir -p /usr/local/libexec
cp devsim /usr/local/libexec/gsr24m-devsim
chown root:wheel /usr/local/libexec/gsr24m-devsim
cp com.gsr24m.devsim.plist /Library/LaunchDaemons/com.gsr24m.devsim.plist
chown root:wheel /Library/LaunchDaemons/com.gsr24m.devsim.plist
chmod 644 /Library/LaunchDaemons/com.gsr24m.devsim.plist
launchctl bootout system/com.gsr24m.devsim 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.gsr24m.devsim.plist
rm -rf /Library/Audio/Plug-Ins/HAL/GSR24M.driver
cp -R GSR24M.driver /Library/Audio/Plug-Ins/HAL/GSR24M.driver
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/GSR24M.driver
sleep 1
killall coreaudiod || true
echo "installed. Wait 10 seconds. Check: system_profiler SPAudioDataType | grep -A6 GS-R24M ; tail /tmp/gsr24m-devsim.log"
