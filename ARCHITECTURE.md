# GSR24M on macOS 15 (M1 Pro): architecture and plan

Goal: run the Allen & Heath GS-R24M FireWire card on this Mac (macOS 15.7.9, Apple silicon) with our own software, where we choose what is displayed. ASFW is a reference, not a dependency (it targets macOS 26 and DriverKit).

What was measured on the real card is in `re/NOTES.md`; this file is the design that follows from it. Last update: 2026-10-26.

## Project rules

- Never modify the card's firmware. No firmware upload code in `gsrd` or the app. The vendor firmware package in `AH DOWNLOAD` is study material only.
- `dicedump` is read-only and stays read-only.
- Runtime registers (OWNER, clock select, enable, isochronous channel and speed, SEQ_START) are written only by `gsrd`, as the vendor driver does; they are volatile and reset when the card is power-cycled. Every register written is put back when streaming stops. After a bus reset the card is assumed dirty and cleaned before use (see below).
- The nickname is read-only in our software unless the owner asks otherwise, because the vendor driver stores it on the device and it probably survives a power cycle.
- The decompiled vendor code in `re/` is proprietary study material. Do not paste it into our source.

## Where we are

Working on the real card through Apple's FireWire user library, no kext, SIP on (tool: `gsrcap/gsrloop.c`, 48 and 96 kHz and the rates in between):
- Capture of 32 channels (both TX streams) at 44.1, 48, 88.2 and 96 kHz; long runs clean.
- Playback of 24 channels (both RX streams) at the same rates; 120 s at 96 kHz with 24 channels held, 22 of 24 tones back at the console master (16 and 17 are not on the master); up to 32 busy processes on 8 cores at normal priority.
- Rate change by writing CLOCK_SELECT only; OWNER by 64-bit compare-swap; bus reset detected and cleaned up (software reset and real cable pull).
- Not done: CoreAudio device, MIDI, clock drift handling, latency measurement, hours-long runs, sleep and wake, ZED-R16 (chained device).

## Why user space

- Apple's FireWire stack is still loaded on macOS 15 (`IOFireWireFamily` 4.8.3). Its user library `IOFireWireLib.plugin` has an arm64e slice, so a normal process can open the device, do async reads and writes, and run isochronous DCL programs. Proven.
- The vendor driver is an x86_64 kernel extension. It cannot load here, and a new kext on Apple silicon needs reduced security. We avoid kexts entirely.
- CoreAudio accepts user-space drivers as AudioServerPlugIns. CoreMIDI accepts virtual endpoints created by any process.

## Components

1. `gsrd` (daemon, C engine + Swift shell). Owns the device. Details below.
2. HAL plug-in (`GSR24M.driver`, AudioServerPlugIn, C). Presents one device with 32 in / 32 out to CoreAudio, backed by shared rings. No FireWire code in it. A crash in a plug-in takes down `coreaudiod`, and the vendor needed years of fixes in this exact area.
3. App (SwiftUI, exists as a UI against recorded dumps and the real card through `dicedump`). Talks to `gsrd` over XPC once it exists. Which channels are shown, channel names (renaming stored in `GSRCore`, to be fed to the plug-in so DAWs show them), meters, clock source, rate, lock state, event log, diagnostics.

## gsrd design

### Split

- C engine (`engine/`, from `gsrloop.c`): everything that touches IOFireWireLib. One thread per job, no Swift in the isochronous path.
- Swift shell: device discovery (IOKit notifications for an A&H unit appearing or leaving), state machine, XPC service, settings, logging. Talks to the engine through a small C API.

### State machine (per card)

`absent` → `probing` (read-only dump, check A&H rules from `GSRCore`) → `idle` (owned, registers clean, not streaming) → `starting` → `running` → `stopping` → `idle`. From any state: bus reset or device removal → `recovering` → `probing` or `absent`.

### Start sequence (the one that works; vendor order)

1. Take OWNER (compare-swap 64: expected `0xFFFF000000000000`, new = full local node id << 48 | notification address; values byte-swapped; library quirk). Keep it until stop. Address space for notifications is a pseudo address space with automatic replies.
2. If the rate changes: write CLOCK_SELECT (rate code in bits 15:8, source kept), wait for STATUS lock at that rate, re-read the stream layout (names and counts were identical at every rate on this card, but the layout is always read, not assumed).
3. Listen to the card's TX stream alone for about 0.6 s: measure the SYT advance per data packet (4095.433 ticks, -138 ppm against 4096, steady to 0.2 ppm) and the phase of its data packets. Streams stopped afterwards, rate left as requested.
4. Build the playback ring: length chosen so a lap holds a whole number of data packets at the measured rate; the data/empty pattern comes from a DDA (3072 ticks of credit per bus cycle, one data packet costs the measured advance).
5. Allocate IRM channels for the capture channel(s) (card is the talker, we are the listener) and the playback channel(s) (we talk, the card listens); the remote-port handlers write ISOCHRONOUS (and SPEED for TX, SEQ_START = 0 for RX).
6. Write ENABLE = 1 once, wait 2 ms, start the send ports, then the receive port(s).
7. Running: read EXTENDED_STATUS every 0.25 s (bits 6 and 7 = receive locks of RX stream 0 and 1; bits for sources; slipped bits in the high half), compare the bus generation.

Packet format: CIP header (SID, DBS, FMT 0x10, FDF = rate code, SYT, DBC at the start of the packet), 8 blocks per data packet up to 48 kHz and 16 at 88.2/96 kHz (32 above, not needed here), DICE raw samples (24 bit sign-extended over the 32 bit slot, no label), MIDI slot 0x80000000. Data/empty cadence and SYT follow the card's own timeline (measured, not the host clock; the host clock failed).

### Stop and rate change

Stop: send ports and receive port stopped, ENABLE = 0, every ISOCHRONOUS = -1, channels released, OWNER released. A rate change is a full stop, the CLOCK_SELECT write, a new start (nothing else is written for the rate, like the vendor driver).

### Bus reset and cable pull

- Detection: the bus generation is compared every 0.25 s; the IOFireWireLib reset handler is installed too (completion called) but did not fire in the tests.
- Reaction: stop streams, release every resource at once (channels, ports, address spaces, the card's registers only if it answers), fail-fast register access (2 tries of 20 ms), wait for the card for a few seconds.
- After the card is back, assume its registers are dirty: the first thing is a clean-up pass (all ISOCHRONOUS to -1, ENABLE 0, clock as requested), then OWNER again. `gsrloop --cleanup --go` is that pass. A new IOFireWireDevice node appears; when the whole Thunderbolt adapter is replugged a different port may be needed (stale controller node).
- The plug-in keeps answering CoreAudio during a reset (silence out, zeros in) so a DAW does not hang.

### Threads, priorities, depths

- Isochronous thread: the run loop that serves the DCL callbacks and the generation check; real-time (time-constrained) priority in `gsrd`. At normal priority the tool held up to a load of 4 times the core count and failed when a scheduling gap exceeded the playback ring (126 ms against 80 ms).
- Callbacks every 8 slots (1 ms), not per packet: with one callback per packet (24,000 per second) the main thread stalled and the card lost lock.
- Playback is generated `--lead-ms` ahead of the DMA (default 80 ms; was 40 ms in the tool). A scheduling stall longer than the lead means stale data is sent, so the lead is the real latency/safety trade; the safety offset reported to CoreAudio is lead + 3 ms. Presets to expose to the user: Low 40 ms, Normal 80 ms, Safe 200 ms, like the vendor's modes.
- Capture ring: 640 packets minimum (a 20 ms ring lost data once).
- Lead (presentation time minus send time, in ticks) is a per-rate constant: 12800 up to 48 kHz; 4500 at 88.2 and 96 kHz (window measured at 96 kHz: 1000 to 9000 works, 12800 and above does not lock).

### Shared memory and clock anchors (gsrd to plug-in)

- Two ring buffers (input 32 channels, output 32 channels), 32 bit float or 24 in 32, interleaved by frame; a header with: sample rate, channel count, ring size in frames, write and read positions (atomic), a generation counter changed on every restart, and a clock anchor.
- Clock anchor: the card is the clock master. The plug-in's device clock is the card's frame counter. `gsrd` maps frames to host time (`mach_absolute_time`) from packet arrival with a small filter (a delay-locked loop), and publishes (frame count, host time, rate error in ppm) regularly. CoreAudio then sees a device that runs at its own rate (+138 ppm against the Mac was measured); no resampling is needed. Playback is consumed at the card's pace by the DDA already.
- The AudioServerPlugIn runs sandboxed in `Core Audio Driver Service` (user `_coreaudiod`). Proven by the spike (`spike/`, results in `re/NOTES.md`): `xpc_shmem` over a Mach service declared in `AudioServerPlugIn_MachServices` works and is live; POSIX shared memory and a read-only mmap of a file under `/Library/Application Support` work too (fallbacks). The service must be a LaunchDaemon (system domain) for the plug-in to see it, so `gsrd` runs as a daemon and needs an administrator install step. Timers and sleeps in these processes are coalesced (3x late in the test): the producer is a real-time thread driven by FireWire callbacks and the plug-in never sleeps in the IO path.

### XPC interface for the app

State (found, owner, rate, lock, receive locks, sources, names), events (bus reset, lock lost, overrun count), commands (set rate, set clock source, start/stop streaming for diagnostics, buffer preset, clean-up), counters (CIP errors, DBC jumps, callback gap maximum, ring fill). Channel renaming stays in `GSRCore` (app side); the plug-in reads the names from a file in Application Support or from `gsrd`.

### MIDI

Not studied on the wire yet. Known: stream 0 carries three MIDI ports multiplexed in the 17th slot of every block (stream 1 none). Vendor notes: drops at 88.2 kHz and above when a lot is sent, so output must be paced. CoreMIDI virtual ports created by `gsrd`. Later milestone.

## What we reuse and from where

| Need | Source |
| --- | --- |
| DICE register layout and report format | `dicedump`, `GSRCore` (parser, tested), ASFW fixtures in `documentation/fixtures/DICE/` |
| Start, stop, rate-change, bus reset sequences | measured on the real card, `gsrcap/gsrloop.c` and `re/NOTES.md` |
| AM824 / CIP packing, DBC and SYT handling | ASFW `ASFWDriver/Audio/Wire/` as reference (Apache-2.0), vendor notes for the details |
| Pitfalls | release notes list in `re/NOTES.md` |

## Milestones

M0 Probe the card. Done.
M1 Control only (state, rate, clock source) from the app through `gsrd`. Next: needs the XPC shell.
M2 Capture. Done in the tool (`gsrcap`, `gsrloop`); to move into the engine.
M3 Playback. Done in the tool at 44.1 to 96 kHz; to move into the engine.
M3b Robustness in the tool: bus reset, cable pull, load. Done; presets and real-time priority to add in the engine.
M4 Ring hand-over spike: done. HAL plug-in with clock anchors: done against a stand-in (`hal/`): 32 in / 32 out, sample accurate through CoreAudio at 44.1/48/88.2/96 kHz and IO buffers 64 to 1024, rate change from the client, reconnection after a daemon restart. `gsrd/gsrd.c` (engine) is connected and runs as a LaunchDaemon: real card through CoreAudio, 44.1/48/88.2/96 kHz, round trip 2.2 ms (48 kHz).
M5 MIDI ports, event log, parameter locking, custom layout editor in the app, channel names to the plug-in.
M6 Long runs (hours), sleep and wake, rate switching under a DAW, cable pull under a DAW, round-trip latency measurement, ZED-R16 chain.

## Main risks

- The ring hand-over to a sandboxed plug-in: proven by the spike (three methods work). Remaining: a real device in the plug-in, IO timing under load.
- Timing under load: ring depth is a parameter; real-time priority to be verified in a daemon.
- Host controller behaviour behind Apple's Thunderbolt adapters: a stuck controller node after an adapter unplug needed a different port. Record OHCI vendor and revision in every report.
- Start-up reliability was the issue at 96 kHz until the vendor start order was copied; keep a start-up test (many starts at every rate) in the regression set.
- Signing: the HAL plug-in and `gsrd` need at least ad-hoc signatures on Apple silicon, and the plug-in installs under `/Library/Audio/Plug-Ins/HAL` (administrator rights, so the user runs the install step).
- Build tools: Command Line Tools 16.4 work. Full Xcode is not installed; not needed for these components.

## Test set to keep (all exist as commands)

`gsrloop --go --upto 24 -r RATE` at 44.1, 48, 88.2, 96 kHz (22 of 24 tones with the current console routing); 120 s hold at 96 kHz; `loadrun.sh` at 16 and 32 busy loops; `--busreset-at 6`; real cable pull; 10 consecutive starts at 96 kHz.
