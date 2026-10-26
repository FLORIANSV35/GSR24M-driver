#!/bin/bash
# Installs only the HAL plug-in (not the simulated card side). Use it when gsrd (gsrd/install.sh) is the daemon.
# Restarts coreaudiod: audio on this Mac cuts for a few seconds. Run: sudo ./install-plugin.sh
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/GSR24M.driver
cp -R GSR24M.driver /Library/Audio/Plug-Ins/HAL/GSR24M.driver
chown -R root:wheel /Library/Audio/Plug-Ins/HAL/GSR24M.driver
sleep 1
killall coreaudiod || true
echo "plug-in installed. Wait 10 seconds. Remove with: sudo ./uninstall-plugin.sh"
