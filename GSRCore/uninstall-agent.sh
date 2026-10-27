#!/bin/zsh
# Stops and removes the test LaunchAgent made by install-agent.sh.
launchctl bootout gui/$(id -u)/com.gsr24m.midiagent 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.gsr24m.midiagent.plist"
echo "gsrmidiagent removed."
