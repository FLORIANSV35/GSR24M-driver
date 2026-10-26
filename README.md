# GSR24M: macOS driver for the Allen & Heath GS-R24 FireWire card

Makes the **Allen & Heath GS-R24** FireWire card (GS-R24M console) work on an **Apple silicon** Mac running **macOS 13 or later**, with no kernel extension: an application, a daemon and a CoreAudio plug-in. Not affiliated with Allen & Heath.

## Install

1. Download `GSR24M-x.y.z.pkg` from the [latest release](../../releases/latest) (the app can also do it: *Info → Check for updates*).
2. Open the .pkg. The installer is not signed with an Apple developer account: if macOS refuses it, right-click the file and choose *Open*.
3. When the installation ends, the Mac's sound stops for a few seconds (CoreAudio restarts).

Installed: `/Applications/GSR24M.app`, the daemon `/usr/local/libexec/gsrd` (LaunchDaemon `com.gsr24m.gsrd`), the plug-in `/Library/Audio/Plug-Ins/HAL/GSR24M.driver`.
Uninstall: `sudo /usr/local/libexec/gsr24m-uninstall.sh` (`--purge` also deletes the channel names kept by the daemon).

## What it does

- CoreAudio device "GS-R24M FireWire": 32 inputs and 32 outputs, 44.1 / 48 / 88.2 / 96 kHz, 24 bit.
- Channel names editable in the application, picked up by Audio MIDI Setup and audio software.
- Sample rate, sync source (Internal / Word Clock) and latency mode set from the application.
- Measured round trip inside the console: 2.2 ms (48 kHz). Output latency seen by software: playback lead (40 to 300 ms depending on the mode) + 3 ms.

## Known limits

- Tested on one card only (GS-R24, DICE firmware 1.0.12.0, A&H 4.2.0) with a MacBook Pro M1 Pro through Thunderbolt to FireWire adapters. No ZED-R16 tested.
- No MIDI yet. No external Word Clock tested (the daemon goes back to the internal clock when there is no signal).
- Software that opens the card while the daemon runs (such as the `dicedump` tool) makes the FireWire bus reset: the sound stops for about 3 s.
- Apple silicon only. The plug-in and the daemon are ad-hoc signed.
- The daemon has no access control: any local process can change the rate and the names.

## Project rules

No firmware is ever written to the card. Only volatile registers are changed (owner, clock, enable and channels of the streams) and put back when streaming stops. The manufacturer's firmware, installers and code are not part of this repository.

## Build from source

Tools: Command Line Tools (Xcode is not needed). `./build_release.sh` builds the daemon, the plug-in and the application, runs the tests and produces `dist/GSR24M-<version>.pkg` and its SHA-256 checksum. Version: the `VERSION` file.

| Folder | Content |
| --- | --- |
| `gsrd/` | daemon (isochronous FireWire engine, shared rings, XPC) |
| `hal/` | AudioServerPlugIn, simulator and test benches |
| `GSRCore/` | Swift package: tested models and the SwiftUI application |
| `dicedump/` | read-only DICE register reader |
| `gsrcap/` | command line test tools (capture, playback, hold, load) |
| `installer/` | installer scripts and texts |
| `re/NOTES.md`, `ARCHITECTURE.md` | measurements, decisions, design |

## License

Apache-2.0 (see `LICENSE`). Part of the knowledge about the DICE protocol comes from the [ASFireWire](https://github.com/mrmidi/ASFireWire) project (Apache-2.0).
