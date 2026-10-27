#!/bin/zsh
# For testing without the installer: builds the MIDI agent and runs it as a LaunchAgent of the current user (no sudo).
# Needs the new gsrd (sudo gsrd/install.sh) to receive MIDI from the card.   Stop it: ./uninstall-agent.sh
set -e
cd "$(dirname "$0")"
swift build -c release --product GSRMidiAgent
BIN=$PWD/.build/release/GSRMidiAgent
codesign --force --sign - "$BIN"
PLIST=$HOME/Library/LaunchAgents/com.gsr24m.midiagent.plist
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#/usr/local/libexec/gsrmidiagent#$BIN#" ../installer/com.gsr24m.midiagent.plist > "$PLIST"
launchctl bootout gui/$(id -u)/com.gsr24m.midiagent 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "gsrmidiagent running as $(id -un). Log: /tmp/gsr24m-midiagent.log"
