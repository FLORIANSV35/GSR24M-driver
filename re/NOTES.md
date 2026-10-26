# Notes on AllenAndHeathFW.kext 4.3.1 (47542), from Ghidra 12.1.4 decompilation

Study notes only. `AllenAndHeathFW.decompiled.c` is proprietary code kept locally for reference; do not copy it into the ASFW fork (Apache-2.0).

## Findings

- It is the stock TCAT/DICE driver ("tcat::dice" namespace, copyright TC Applied Technologies) with A&H branding. No A&H-specific register writes were found in the functions read.
- Device recognition (`AllenAndHeathFWAudio::start`, decompiled.c ~line 196-248): it reads the GUID and accepts the device when
  - `(guid & 0xFF00000000) == 0x0400000000` (TCAT category 0x04, standard DICE);
  - product = `(guid >> 22) & 0x3FF`: 0 = "ZED R 16", 1 = "GS R 24"; anything else is "unsupported device".
  It does not test the vendor bits of the GUID. This matches the TCAT GUID layout used in dicedump (vendor 24 bits, category 8 bits, product 10 bits, serial 22 bits), so a GS-R24 should report category 0x04, product 0x001.
- Ownership (`GetOwnership`): standard DICE. Reads GLOBAL OWNER, registers a notification address range, then compare-swap 64 on OWNER (expected 0xFFFF000000000000) with (node << 48 | notification address).
- Rate / sync / master changes (`SetNewSamplingRate`, `SetNewClockSyncSource`, `SetNewMaster`): each checks the requested value against the capability bitmask, stores it, notifies clients, then calls `RequestStreamingRestart`. So the sequence is stop streams, change clock, restart streams.
- Streaming restart log string: `RestartStreaming (sr %d, clksrc %d, opmode %d)`.
- User client methods exposed to the control panel: GetConfigInfo, SetClock, SetSync, GetCurrentClockParam, AsyncRead/AsyncWrite, GetNotificationQuadlets. These are what the A&H Control Panel uses; ASFW would not provide them.

## Streaming path (read)

- `ReportChannelAndSpeedToHardware`: per stream, reads the block size from the TX/RX section header, then writes
  - TX: ISOCHRONOUS = channel, then SPEED = speed code;
  - RX: ISOCHRONOUS = channel, then SEQ_START = 0.
  Same layout as the ASFW DICE reports.
- `StartStreams` order: init SYT interval from the sample rate; pre-fill every playback packet (`FillFirewireBuffers`); write 1 to a per-device register (almost certainly GLOBAL ENABLE, offset not cross-checked); `IOSleep(2)`; start the isoch contexts (playback group first, then capture group, inferred from field offsets).
- `StopStreaming` order: stop playback contexts, stop capture contexts, `IOSleep(1)`, write to the device (disable), then release ports and buffers.
- Format and rate changes are always a full stop and restart (`RequestStreamingRestart`).
- Timing is in 24.576 MHz ticks (3072 per FireWire cycle, 24,576,000 per second). `adjustOutputPhase` aligns output to input and the driver resyncs when the offset difference exceeds about 1 cycle (0xC00) or about 2.5 cycles (0x1DC4).
- MIDI (`writeMIDIQuadlet`): AM824 quadlet, label 0x81 plus the byte (0x80 when empty), paced from a 1024-slot timestamped ring to respect 31.25 kbaud.

## Packet and buffer parameters (read)

- SYT interval (samples per packet, max): 8 at 32/44.1/48 kHz, 16 at 88.2/96 kHz, 32 at 176.4/192 kHz. Nominal samples per cycle: 6 / 12 / 24 for 44.1-48 / 88.2-96 / 176.4-192 kHz.
- SYT difference: 0x300 at 32 kHz, 0x22D at 44.1, 0x200 at 48, 0x116 at 88.2, 0x100 at 96 (512 x 48000 / rate).
- Ring size in packets: 160 up to 48 kHz, 80 up to 96 kHz, 40 above (always about 20 ms).
- Data block size (DBS) = PCM channels + 1 quadlet when the stream has MIDI ports (MIDI slots clamped to 8).
- CIP header is standard IEC 61883-6 AM824: SID = local node id, DBS in byte 1, FMT = 0x10 (header byte 0x90), FDF from the sample rate, SYT 0xFFFF when no timestamp.
- Above 96 kHz the driver can run a split-wire mode (DBS x2, rate / 2 in FDF) when the device advertises it. Not relevant for the GS-R24 (96 kHz max over FireWire).
- Bus side: channel and bandwidth are allocated through the bus object; payload per packet = SYT interval x DBS x 4 bytes plus 0x14 bytes of overhead.

## Comparison with ASFW (read in the fork)

ASFW already has a generic DICE path (`DiceIdentity.hpp`, `AudioDeviceResolver.cpp`): any unit whose unit directory has version 0x000001 and whose GUID follows [OUI:24][category:8][product:10][serial:22], with product = the unit's model id and category 0x04, is accepted as "Generic DICE Audio" without a catalog row. The vendor driver's own acceptance rule (category 0x04, product 1) fits that layout. So the GS-R24M is likely already picked up by the generic path; to be confirmed on hardware.

## Not yet read

`GetBusChannel` details, `PrepareSendDCLs` / `PrepareRecvDCLs`, receive-side CIP parsing (`ReadFirewireBuffers`), the MIDI plugin and daemon path. Most of the remaining ~10,000 lines are IOKit boilerplate (metaclasses, logging, user client plumbing).

## Subtleties from the vendor release notes (3.3 to 4.3.1) and Control Panel guide

These are bugs the vendor fixed over about ten years. Each one is a case our own implementation has to handle.

- Bus reset: streaming must resume by itself after a 1394 bus reset, or channels go missing (4.1.1). Quitting the control panel must not cause a bus reset (3.3.3, case 399).
- Isochronous bandwidth allocation was reworked three times (3.5.4, 4.1.3). Ignore devices that are not on the same bus as the master (3.5.1).
- Channel count can change with the sample rate. Republish the device once, not twice (3.5.0, case 665). A device must never appear with 0 channels (3.5.0 case 643, 3.5.6 case 905): re-read the stream registers after the rate is settled, then publish.
- Clock source: the OS can restore an old clock source value at startup (4.1.0), and switching devices could leave it stuck on Internal (4.1.4). Always read back CLOCK_SELECT and STATUS rather than trust the last value we wrote.
- Sample rate while audio clients are active is locked in the vendor panel ("parameter locking"). A rate change is a full stop and restart of the streams.
- A device that is detached must disappear immediately from the list (3.5.6).
- MIDI: rates of 88.2 kHz and above drop MIDI when a lot is sent (3.4.2); the second MIDI port on a stream did not work at 176/192 kHz (3.3.1). Not relevant above 96 kHz, but MIDI output must be paced.
- Nickname: stored on the device (NICK_NAME, 64 bytes); the vendor driver had corruption bugs when it was shortened (3.5.0). Write the full 64 bytes, zero padded.
- Async reads and writes (firmware upload) could fail on newer Macs (4.1.2). Retry with a short delay.
- Host controller matters: with an LSI FW643 OHCI at revision 0x06, audio was distorted when a FireWire hard drive shared the bus (4.1.0, case 889). Apple's Thunderbolt to FireWire adapter is a different path, but record the OHCI vendor and revision in every report. The vendor panel has an "OHCI checker" for this.
- Operation modes (renamed in 4.0.0): Low Latency, Normal, Safe Level 1, Safe Level 2. In the driver they only change the isochronous buffer depth (`UpdateIsochBufferParams` picks parameters per mode; 160 / 80 / 40 packets per ring depending on rate).
- The vendor Control Panel UI hides the rate selector or sync-source selector when there is only one choice (`hideRatesIfSingle`, `hideSyncsIfSingle` in cpl.defs), shows a clock icon on the clock master, a padlock when locked, and keeps a log of the last 40 device events (lock lost, lock regained) reachable with shift-click.

## Capture path (`ReadFirewireBuffers`)

- A received packet is accepted only if: format/FDF gives a known rate, the source node id matches the device, and the data block size matches what the stream registers announced (PCM channels plus one MIDI slot if the stream has MIDI). Anything else is dropped.
- Audio samples are AM824 quadlets: label byte then a 24-bit big-endian sample. The driver drops the label and left-justifies the 24 bits into a 32-bit integer (`swap(x) << 8`).
- MIDI slots are read from the extra quadlet at the end of each data block, one quadlet per audio frame, and the slot used rotates with the data block count.
- Continuity: the data block count (DBC) in the CIP header is checked on the master stream. A discontinuity is counted and all playback groups are flagged to resynchronise.
- Timing: the SYT of each packet feeds a 512-entry history of timestamp differences. The measured sample rate comes from the running sum. The driver waits for 512 valid timestamps before it declares the stream synchronised. Packets with SYT 0xFFFF (no info) are skipped for timing.
- Capture is the timing master: the position of playback is derived from the capture timestamps (`extendTstamp`, `tstampToOffsets`, `adjustOutputPhase`), in 24.576 MHz ticks.

## Control Panel and MIDI plug-in (read)

- The Control Panel is a JUCE application (about 13,000 decompiled functions, nearly all JUCE and STL) on top of TCAT's "PAL" layer. It talks to the kext through a user client for clock, sync, operation mode and nickname, and uses IOFireWireLib directly (class `fwlib`) for firmware upload.
- `fwlib` details worth copying as behaviour:
  - `Open()` is retried every 1 ms while it returns exclusive access (another client has the device).
  - Reads go to `0xFFFF:E0000000 | offset` in chunks of at most 0x200 (512) bytes, with the current bus generation; a short read is treated as a timeout error.
  - Errors are typed: device access failed, device operation timeout, firmware CRC failure, firmware timeout.
- The firmware loader checks the vendor id, product id and version inside the .bin before upload and warns when the file is older than the running firmware.
- Window and user-facing messages worth keeping in our UI: device locked / unlocked, device state normal / changed, measured sampling rate, operation mode (Lowest Latency, Normal, Safe levels), clock master, nickname, "could not change sample rate / sync source / operation mode", "Driver not found", "Driver version mismatch", "No devices found", OHCI controller info with a support verdict.
- Preferences are saved to a settings file; the panel warns when it cannot write it.
- MIDI plug-in (`AllenAndHeathFWMIDIDriver.plugin`, i386 and x86_64, CoreMIDI legacy driver): connects to the kext user client, checks the driver version, asks for MIDI info (port count), enables driver notifications, and creates endpoints named "Allen and Heath Firewire Port N". Input goes through a MIDI byte parser into packet lists; output is paced per port. It cannot load on Apple silicon; we create virtual CoreMIDI ports instead.
- Console MIDI maps (Default, DAW, Bome DAW) are graphical tables; their text does not extract. To be rendered to images and read.

## Firmware GS_R24_V4.2.0.39752 (analysis only, never uploaded)

Loaded in Ghidra as a raw ARM little-endian image (ARM:LE:32:v5t) at base 0x30000; the reset vector at file offset 0 jumps through a table at 0x20 to 0x30040. 917 functions found. Study material only: `GSR24_firmware_4.2.0.decompiled.c`.

- Built on eCos (RTOS) with RedBoot for flash handling; build date Nov 13 2014. Banner: "Allen & Heath Ltd GS R-24", with a "Board is configured to mode: N" line, board serial, app version. A leftover string "DICE JR EVM 18/18" shows it derives from TCAT's evaluation board code.
- Threads seen: app, meter ("myMeterThread"), MIDI, link layer (lhl*), AVS stream (avs*), clock (dice*/dal), DICE register driver ("DiceDriver, illegal write command! at OffSet = ..." is logged when a write hits a read-only register).
- Operating modes, each with its own channel-name list (so channel counts and names depend on the mode, read them from the stream registers, never hardcode):
  - "GSR-24 32/32 FW": 32 channels named CH1 to CH32 (each name also carries a stereo pair label such as CH1/CH1/2);
  - "GSR-24 24/24 FW 8/8 ADAT": CH1 to CH24 plus ADAT1 to ADAT8;
  - "GSR-24 32/32 ADAT 44.1 INT / EXT" and "48 INT / EXT" (ADAT modes with internal or external clock);
  - extra lists name the aux or group channels (CH17 to CH24 alternate with ADAT1/2 to ADAT7/8) and "MAIN L/R".
- Clock source names in the device: AES12, AES34, AES56, AES78, AES_ANY, ADAT, ADAT_AUX, Word Clock, four Unused, Internal (13 entries, same order as the DICE register list).
- Clock state machine (dal): DISABLED, SETUP_SRC, WAIT_SRC_LOCK, WAIT_RATE_STABLE, CHECK_RATE, LOCKING, ILLEGAL_RATE, RATE_IS_FLAKY, LOCKED. Useful as the set of states for our lock display.
- It has two isochronous receive and two transmit stream ports (ARX1, ARX2, ATX1, ATX2), matching the two TX and two RX stream blocks in the DICE registers.
- Receive-side checks that can fail when the host sends a bad stream, and that we should avoid triggering: CIP_FAIL (header wrong), DBC_FAIL (data block count not continuous), CFG_FAIL (stream configuration mismatch, for example block size), SYT_OVERFLOW / SYT_UNDERFLOW, LONG_PKT, PKT_ABORT, MISSED_SYNC, and on transmit FRAME_AGEOUT and BOUNDARY_ERR. The device also reports SLIP and STREAM_LOCK / UNLOCK on its audio outputs.
- Link layer: logs "check cable topology for loops" on bus reset and "node is root, reenabled cyclemaster" when it becomes root. It contains IRM code (channel and bandwidth allocation, compare-swap) so it can allocate resources itself; the vendor host driver allocates bandwidth and channels from the host side.

## Stream layout per mode, from the firmware tables (analysis of GS_R24_V4.2.0.39752)

The firmware keeps a table of board modes at about 0x60a00-0x61400 (image base 0x30000). Each mode has a name, the clock source names (13), and for each of three groups (likely the rate ranges) a list of TX streams and a list of RX streams. Each stream record is {flags, pointer to a list of channel names}; every list of names holds 16 names.

- Mode "GSR-24 32/32 FW": 2 streams per direction. Stream 0 names: CH1 to CH16. Stream 1 names: CH17 to CH24 then ADAT1/2, ADAT1/2, ADAT3/4, ADAT3/4, ADAT5/6, ADAT5/6, ADAT7/8, ADAT7/8. So 16 + 16 per direction. The three groups are identical here, so no change of channel count between rate ranges is visible in this mode.
- The name strings are "<mono label>/<stereo pair label>", for example "CH1/CH1/2", "CH2/CH1/2", "CH3/CH3/4". The card will report these through the NAMES registers.
- Stream 0 carries a flag 0x310 and stream 1 carries 0x10. The low byte 0x10 matches 16 channels; the 0x300 part is probably the MIDI port count (stream 0 only), not confirmed.
- Mode "GSR-24 24/24 FW 8/8 ADAT" and the ADAT 44.1 / 48 INT / EXT modes use one stream per direction whose names are ADAT1 to ADAT16. How the 24 FireWire channels are arranged in these modes is not resolved from the tables alone.
- Which mode a given card is in is decided at run time ("Board is configured to mode: N"), so the real layout must be read from the registers (`dicedump`).
- Unresolved: what the numbers 5, 6, 7, 9 next to each group are (likely port or stream identifiers), and the meaning of the values 0x1830 and 0x1080001e that follow the tables.

## Real card, first read (2026-10-25, M0 done)

`dicedump` read the connected GS-R24 on this Mac (macOS 15.7.9, Apple silicon, Apple Thunderbolt to FireWire chain, IOFireWireLib, read-only). Saved as `GSRCore/Tests/GSRCoreTests/Fixtures/gsr24m-real.txt`.

- GUID 0x0004C40400400345: OUI 0x0004C4, category 0x04, product 1, serial 837. Vendor_ID 0x0004C4, Model_ID 1, Unit_Spec_ID 0x4C4, Unit_SW_Version 1. The Mac names the vendor "A_H" and the model "Allen_and_Heath_GS_R_24". Link speed S400.
- DICE register version 1.0.12.0. Section tables: global 380 B, tx 568 B, rx 1128 B, ext_sync 16 B. No extension (EAP) space.
- State when read: internal clock, 48 kHz, locked, streaming off, no owner, nickname "GS R-24".
- Clock capabilities: rates 44100, 48000, 88200, 96000. Sources actually offered: Word Clock and Internal (no ADAT in this configuration).
- Streams: 2 TX and 2 RX, 16 PCM channels each, S400. MIDI ports: 3 on stream 0, none on stream 1, in both directions. Names match the firmware table for mode "32/32 FW": stream 0 CH1 to CH16, stream 1 CH17 upward. This confirms that 0x300 in the firmware stream record is the MIDI port count.
- Text registers (nickname, channel names, clock source names) come back with the bytes reversed inside each quadlet; they must be byte-swapped before use.
- Config ROM: 32 quadlets readable. Bus info block (4 quadlets), root directory: vendor_id 0x0004C4, model_id 1, node capabilities 0x0087C0, text descriptors "A_H" and "Allen_and_Heath_GS_R_24", unit directory with spec 0x0004C4, version 1, model 1. The header's crc_length covers only the bus info block, so the ROM must be read until the device stops answering.
- ASFW's generic DICE rule (unit directory version 1, GUID layout with product = model id, category 0x04) is satisfied by this card.

## M2 capture on the real card (2026-10-25): works

`gsrcap/gsrcap.c`, run with `--go`, on macOS 15.7.9, Apple silicon, through IOFireWireLib in user space (no kext, SIP on).

- Sequence that worked: IRM-allocated isochronous channel (552-byte packets, S400) through an `IsochChannel` with the card as a remote talker port and a NuDCL receive ring as the local listener (160 packets); remote-port handlers write TX stream 0 ISOCHRONOUS (channel) and SPEED, wait 2 ms, then GLOBAL ENABLE = 1; stop writes ENABLE = 0 and ISOCHRONOUS = -1, then the channel is released. No OWNER was taken and the card did not need it.
- 5 s result: 39,995 packets (30,000 data of 552 bytes, 9,995 empty of 8 bytes: blocking mode, 3 data packets out of 4 cycles), 240,000 frames (exactly 48,000 per second), 0 CIP errors, 0 DBS mismatches, 0 DBC discontinuities. The card was back to ENABLE 0, ISOCHRONOUS -1, no owner afterwards.
- Stream 0 has DBS 17: 16 PCM channels plus one MIDI slot (3 MIDI ports are multiplexed in it). Payload 8 x 17 x 4 + 8 = 552 bytes at 48 kHz.
- Quirks found: `ReadQuadlet` returns bytes in a different order from block `Read`; use block reads and writes of 4 bytes with big-endian bytes. The isochronous header comes as a little-endian quadlet (byte 0 = tcode and sy, byte 1 = tag and channel, bytes 2 and 3 = data length). Payload bytes are in wire order.
- Level check: all 16 channels were at about -94 dBFS (noise floor, nothing audible on the console channels at the time).
- Not yet done: stream 1 (CH17 and up), playback to the card, 88.2 and 96 kHz, bus reset recovery, long runs, CoreAudio.

## M2 follow-up: both streams, 88.2 and 96 kHz (2026-10-25)

`gsrcap -s <stream> -r <rate>`. The rate is changed by writing CLOCK_SELECT (rate code in bits 8-15, source in bits 0-7, source kept as internal), then waiting for STATUS to show locked at that rate code; the original value is written back at the end and the lock is checked again.

- Stream 1 (card channels 17 to 32) works like stream 0: 16 PCM channels, no MIDI slot, DBS 16, 520-byte packets at 48 kHz.
- 88.2 kHz: SYT interval 16, 1032-byte packets (stream 1) and 1096-byte packets (stream 0, DBS 17); 27,562 data and 12,433 empty packets in 5 s. 96 kHz: 30,000 data and 9,996 empty packets in 5 s. The channel count per stream stays 16 at these rates. 0 CIP errors, 0 DBC discontinuities, frame counts within a packet of rate x 5 s, 0 register retries.
- Packet buffers must be at least 1100 bytes; 1024 rejected every data packet at 88.2 and 96 kHz.
- A tone on card channels 16 and 17 appears at 1001 to 1002 Hz, about -27 dBFS rms, at 48, 88.2 and 96 kHz, in the right stream positions (16 is the last of stream 0, 17 the first of stream 1).
- Channels 31 and 32 are the console's master L/R return (user), so they follow the master routing.
- At 88.2 and 96 kHz the channels without signal show a very low frequency component at about -57 to -78 dBFS rms (strongest bin near 5 Hz, all energy under 2 kHz, mean offset only about -77 dBFS), where the same channels at 48 kHz are at about -107 dBFS. Counters are clean and the tone channels are clean, so it does not look like a capture fault. Cause not established; converter behaviour at double speed is a guess.
- In the shell (zsh) an unquoted "$R" holding "-r 96000" is not split into two words; use an array or write the option inline.

## Long captures, both streams at once (gsrlong, 2026-10-25)

`gsrcap/gsrlong.c`: both TX streams (card channels 1 to 32) through two IsochChannels in one process; both channels are allocated before the first Start so ENABLE is written once every stream is configured. Tone of about 1 kHz on card channels 16 and 17 throughout.

- 48 kHz, 120 s, ring 160 packets (20 ms): first run lost packets once, at 9.341 s, in both streams at the same moment (24 then 8 data packets, about 5 ms of audio, a click on channel 17). Two further identical runs: no loss.
- 96 kHz, 120 s, ring 160: clean (0 CIP errors, 0 DBC discontinuities after start-up, no lock loss, tone level steady within 0.01 dB).
- 48 kHz, 120 s, ring 640 (80 ms) and a high-QoS main thread: clean.
- Cause of the single loss: the host side. Gaps between packet callbacks of 8 to 19 ms occur several times per run, always at the same instant in both streams (the process is not scheduled for a while). A gap longer than the ring (20 ms with 160 packets) overruns it. Raising the thread QoS did not remove the gaps; a deeper ring absorbs them. For the real driver: ring of at least 400 to 640 packets or a real-time thread, to be settled by measurement under load.
- Start-up: during the first few ms the card sends packets whose block counter then restarts from 0 (once, around packet 30). Not a loss. Ignore the first 0.25 s when counting discontinuities.
- Clock: frames received against Mac time over 120 s gave +138 ppm at 48 kHz and +140 ppm at 96 kHz. The measurement uses callback timestamps and is only good to a few ppm over minutes; treat it as indicative. It means the card's clock and the Mac's are not locked, as expected, and the audio plug-in will need to absorb about 0.14 samples per ms of drift (about 6.6 samples per second at 48 kHz).

## M3 playback: first attempts (2026-10-25), not yet confirmed

Tools: `gsrcap/gsrplay.c` (playback only) and `gsrcap/gsrloop.c` (playback plus capture, `-s` playback stream, `-C` capture stream, `--sweep` one tone per channel, level capped at -20 dBFS).

- Host transmit works at the Mac level: one IsochChannel with a NuDCL send ring of 640 packets (80 ms) refilled from the send callbacks, DMA started at a chosen cycle (current + 1600), remote-port handlers write RX stream ISOCHRONOUS (channel) and SEQ_START 0, wait 2 ms, ENABLE 1. About 8000 packets per second leave, longest callback gap 10 to 17 ms, no library error, card restored to ENABLE 0 and ISOCHRONOUS -1 afterwards.
- Packet format used: CIP header (SID = local node, DBS = PCM + 1 MIDI slot, DBC at start of packet, FMT 0x10, FDF = rate code, SYT), blocking cadence 3 data packets of 8 frames (16 at 96 kHz) in every 4 cycles, empty packet = 8 bytes with SYT 0xFFFF and the rate FDF, data SYT = send time + 0x2E00 + 2048 ticks advancing 4096 per data packet.
- From the ASFW sources: DICE devices get raw 24-bit PCM sign-extended over the whole 32-bit slot with no AM824 label (negative samples start with 0xFF), MIDI/non-audio slots 0x80000000, silence 0, no-data packets keep the rate FDF with SYT 0xFFFF, DBC is the count at the start of the packet. ASFW's blocking transfer delay is 12800 ticks at 48 and 96 kHz, and in duplex it follows the device's own cadence ("RX sequence replay") once the device clock is recovered from the received stream; before that it sends no-data packets to bootstrap the stream. My first version used label 0x40 and a free-running cadence; the second uses the raw encoding. Neither has been shown to make the card play yet.
- The console does not loop the host's playback back: card channels 1 to 24 are the console's channel outputs (what enters console channel N leaves on card channel N), and channels 31 and 32 are the master L/R return. A loopback test therefore needs the console to route the FireWire return somewhere, for example to the master, which then appears on card channels 31 and 32 (TX stream 1).
- Open question: whether the card accepts the stream. The card exposes no receive status register. Candidates if it does not: SYT phase (follow the card's own TX SYT instead of host cycle time), cadence phase (replay the card's data/no-data pattern), a no-data bootstrap phase before data.

## M3: the card reacts to the host streams (2026-10-25)

`gsrloop` now polls GLOBAL STATUS and EXTENDED_STATUS every 0.25 s while it runs, plays to one or two RX streams (`--upto N` sends channel g at 250 Hz x g to channels 1..N, using both RX streams above 16), and captures one TX stream (`-C`). `--noplay` captures only.

- EXTENDED_STATUS (global + 0x58) is 0x00000000 when only the card's TX stream is running. With one host playback stream it reads 0x00000040, with two host playback streams 0x000000C0, stable, with no slip bits. So the card's receive side notices exactly the streams we send. Bit 6 and bit 7 are named "tdif" and "wc" by the generic source list, but on this firmware they most probably are the receive-lock flags of RX streams 0 and 1 (the firmware's own list names indices 8 to 11 "Unused"). Likely, not proven.
- With 24 tones sent (channels 1 to 24, -36 dBFS each, two RX streams) nothing was found on card channels 17 to 32 (TX stream 1, where the master L/R return sits on 31 and 32). The console routing of the FireWire returns to the master was not confirmed, so this does not say whether the audio is played.
- Still open: confirm audio at the console outputs (needs the console set to monitor the FireWire returns), then decide whether the SYT phase and cadence need to follow the card's own TX stream as ASFW does.
- zsh pitfall: `for mode in "--upto 24"; do ... $mode` passes one argument, not two. Use separate words or an array.

## M3 result: playback to the card works, all 24 channels (2026-10-25)

`gsrloop --go --upto 24 -C 1 -l -36 -t 6`: channel N (1 to 24) sent at 250 Hz x N, -36 dBFS each, through both RX streams; the console (FireWire returns routed to the master) returned them on card channels 31 and 32 (TX stream 1). All 24 tones found on both channels, one frequency per source channel, levels -38 to -40 dBFS (about -2 to -4 dB through the console master). Channel mapping is correct for both RX streams (1 to 16 on stream 0, 17 to 24 on stream 1).

What made it work: the playback SYT timeline is aligned to the card's own SYT grid. The tool listens to the card for 0.45 s, measures the card's SYT advance (4095.435 ticks per data packet, -138 ppm against 4096) and the phase of its latest data packet, picks the first presentation time at or after (send cycle start + 12800 ticks) on that grid, and advances it at the measured rate. With a host-clock timeline (send time + fixed delay, 4096 ticks per packet) the card's receive lock flags came and went from run to run and nothing was heard.

Limits seen in the same run (not solved):
- Lock flags (EXTENDED_STATUS bits 6 and 7, most likely RX stream 0 and 1 lock) did not stay up: 0x40 at 0.25 s, 0xC0 at 0.76 s, 0x80 at 4.3 s, 0x00 at 8.1 s. Per-0.25 s level series show the tone of stream 0 steady for about 4.5 s and the tone of stream 1 starting about 1.25 s later and lasting about 5 s, instead of 6 s each. So the card played each stream for a few seconds only.
- Likely causes: (1) the host sends exactly 6000 data packets per second while the card's clock is about 140 ppm away, so its buffer drifts (about 6.6 samples per second) until it slips; ASFW replays the card's data/no-data cadence for this reason; (2) the two RX streams were not started in the same instant; (3) the DMA seems to have started before the requested cycle (tone present from the start of the capture), so the ring was rewritten while running.
- Next: follow the card's cadence (send a data packet when the card does, or insert an extra data packet at the measured rate), start playback only after the ring is final (check the semantics of the cycle start event or start by hand), start both streams together, then re-measure how long the lock holds.

## M3 sustained playback works (2026-10-25)

`gsrloop --go --upto 24 -C 1 -l -36 -t 20`: 24 tones on the two RX streams, 20 s. Every tone arrives on card channels 31 and 32 at a steady -39/-40 dBFS from the first 0.25 s to the end, no dropout; EXTENDED_STATUS stays 0x000000C0 (both receive locks) for the whole run; capture counters clean; longest send callback gap 23 ms.

What it took (each point was needed):
1. DICE raw sample format: 24-bit sign-extended over the 32-bit slot, no AM824 label (from ASFW).
2. Presentation times (SYT) on the card's own grid: listen to the card alone for 0.6 s and measure how fast its SYT advances (4095.4346 ticks per data packet, -138 ppm against 4096, reproducible to 1e-7), then send SYT = reference + n x that rate.
3. Send cadence that follows the card's rate: the host data/empty pattern comes from a DDA that adds 3072 ticks of credit per cycle and spends 4095.43 per data packet. The ring length is chosen (6000 to 12000 cycles, multiples of 8) so a lap holds a whole number of data packets (9656 cycles, 7243 data packets, 6000.83 per second). A fixed 3-in-4 pattern (6000 per second) lets the card's buffer run dry after about 4 s: the lead of the data over the presentation time shrinks by about 3400 ticks per second.
4. Real send times: the DMA start event passed to CreateLocalIsochPort is not honoured here (first packet leaves 11 to 30 ms after Start()). Each batch's last slot has a time stamp (SetDCLTimeStampPtr plus AppendDCLUpdateList on itself, flags (1<<1)|(1<<2) = dynamic and update-before-callback; the values come from IOFWDCL.h and are not in the SDK headers; the stamp is a cycle time: seconds(7) cycle(13) offset(12), +4096 per slot). Packets are generated 320 slots (40 ms) ahead from those stamps; the first 320 slots carry data with SYT 0xFFFF.
5. Callbacks and stamps only every 8th slot (1 ms). With a callback and stamp on every slot (24,000 callbacks per second) the main thread stalled for 30 to 200 ms and the card lost lock.
6. Both streams use the same data packet number to place their SYT (`gN0`); counting separately per stream let the second stream lose lock after about 5 s.

Not yet done: runs of minutes, 96 kHz playback, load (CPU busy) and bus-reset tests, lower latency (the generate-ahead is 40 ms plus the card's own delay), measuring round-trip latency.

## M3 long run results: 48 kHz holds, 96 kHz not solved (2026-10-25)

`gsrloop` now also changes the card rate (`-r`, restored at the end), sets the SYT lead (`--lead`), forces the FDF byte (`--fdf`), prints the announced channel names (`--names`) and runs a streaming level monitor (0.5 s blocks, an integer number of cycles of every tone 250 Hz x N, no raw storage) so long runs can be checked without keeping the audio.

- 48 kHz, 120 s, 24 channels played and captured at once: all 48 tone/channel pairs (24 tones on card channels 31 and 32) present for the whole run, no dropout block, median -38.4 dBFS, minimum -40.0 dBFS; capture counters clean (0 CIP errors, 0 DBC discontinuities); longest send callback gap 23.5 ms; the card's lock flags 0xC0 except one 0.25 s blink at 92 s. This is the reference result.
- The card's SYT advance is rock steady: 4095.4343 to 4095.4346 ticks per data packet in 5 s windows over 60 s, at 48 kHz and at 96 kHz (variation under 0.2 ppm). No warm-up after a rate change.
- 96 kHz, lead 12800 ticks (the 48 kHz setting): receive locks flap every 0.5 s for the first minute; tones missing or full of dropouts. Not usable.
- 96 kHz lead sweep (8 s runs): lead 6000 and 9000 ticks give a stable lock (0xC0) from 0.25 s; 12800 flaps; 17000 and 21000 never lock; 26000 locks partly. So the accepted lead window is lower at 96 kHz than the 12800 that works at 48 kHz.
- With a stable lock at 96 kHz the audio plays at DOUBLE FREQUENCY: a 1000 Hz tone on playback channel 1 or 2 comes back at 2000 Hz at the same level as at 48 kHz (-32 dBFS); in the 24-tone sweep tones sent at 250 x N Hz come back at 500 x N Hz, which is why only the even numbered tones 2 to 24 (from channels 1 to 12) fall on the monitored frequencies. All channels play; none is missing.
- The card announces the same layout at 96 kHz as at 48 kHz (TX and RX stream 0: 16 audio + 3 MIDI, stream 1: 16 audio, same names), so the registers do not explain it.
- FDF byte test at 96 kHz: 0x02 (48 kHz) gives no lock; 0x03 and 0x04 both lock and both give the doubled frequency. The receiver checks FDF against its rate but the FDF is not what doubles the speed.
- Open: why the 96 kHz stream plays twice as fast (the supply is exactly 96,000 frames per second, so it cannot be consumed at 192 kHz without starving). Ideas not yet tried: the card might pair two consecutive blocks per sample at 96 kHz (so only half of the 16 blocks per packet count), a different packet size or SYT interval for the receive side at 96 kHz, or a mode of the A&H firmware tied to the console setup. ASFW has no special handling for this on DICE.

## 96 kHz playback: what the vendor driver says, and more tests (2026-10-25)

Vendor kext (AllenAndHeathFW 4.3.1), transmit side, read again for 96 kHz:
- Frames per data packet = `SamplingRateToSamplesPerFrameMax` = SYT interval = 8 at 32/44.1/48 kHz, 16 at 88.2/96 kHz, 32 at 176.4/192 kHz. The "nominal" helper (6, 12, 24) is never called for transmit.
- FDF = `SampleRateToFDF`: 32 kHz 0, 44.1 kHz 1, 48 kHz 2, 88.2 kHz 3, 96 kHz 4, 176.4 kHz 5, 192 kHz 6. Same as ours.
- Split-wire mode (DBS x2, FDF of rate/2) only above 96 kHz and only if the device advertises it. Nothing special between 48 and 96 kHz.
- Rate dependent buffer parameters (`UpdateIsochBufferParams`): packets per group 160 up to 48 kHz, 80 up to 96 kHz, 40 above; a timing offset (`+0x17d54c`, `+0x17d550`) grows by 2 from 88.2 kHz and by 4 from 176.4 kHz. Units not determined. This is the only rate dependent timing found, and it points to a larger offset, while our test found a smaller SYT lead (6000 to 9000 ticks) works at 96 kHz.

Tests run after reading it (96 kHz, stable lock with lead 9000):
- 8 blocks per data packet instead of 16 (tone computed at 48 kHz or at 96 kHz): the card does not lock at all. The receiver requires 16 blocks at 96 kHz, so an 8-block / sample-multiplexed receive format is ruled out.
- FDF 2 gives no lock; FDF 3 and 4 lock and give the same doubled frequency.
- The card reports the same names and counts at 96 kHz as at 48 kHz (`--names`).

Still unexplained: with the correct packets the tone returns at twice its frequency at full level. Supplying exactly 96,000 frames per second cannot be consumed at 192 kHz, so the doubling may come from the card's receive-to-DAC path or from the console return path at 96 kHz rather than from the stream. A way to separate the two: play 1 kHz at 96 kHz with the vendor driver on the old Intel Mac and measure the frequency on the same return. If it also doubles, it is the card or console at 96 kHz; if not, the stream differs from what the vendor driver sends.

## 96 kHz playback: further tests (2026-10-25), cause still open

All with the card at 96 kHz, one 1000 Hz tone, level -30 dBFS, the console returning the master on card channels 31 and 32; returned frequency measured in the 96 kHz capture timeline.
- Playback channels 1, 2, 5, 13, 17, 20 and 24 all come back at 2000 Hz at the same level as the 48 kHz reference (-32.4 dBFS). The doubling is general, not tied to a channel or to a stream.
- 16 blocks per packet, FDF 4, tone phase per block 2 pi f / 96000: returns at 2f. Lock stable only for leads of about 6000 to 9000 ticks.
- 8 blocks per packet, FDF 4: never locks, at any lead from 3000 to 21000.
- 8 blocks per packet, FDF 2, tone phase per block 2 pi f / 48000: locks stably at every lead from 6000 to 17000 (much more tolerant), and returns at 2f: the card plays one block per output sample at 96 kHz, i.e. twice the supplied block rate.
- 32 blocks per packet, FDF 4: no lock, at any lead.
- So at 96 kHz the card consumes twice as many blocks per second as are supplied, in both formats it accepts (16 blocks at FDF 4, 8 blocks at FDF 2). The mapping is linear, so a tone computed at half the frequency comes back correct, but that would be a workaround, not a fix.
- Vendor driver: transmit side identical in geometry (16 frames, FDF 4 at 96 kHz); the only register written to change rate is CLOCK_SELECT (rate code << 8 | source), as ours. Nothing found there that explains it.
- 44.1 kHz and 88.2 kHz with the same code: lock bit present at some leads but no tone found at the probed frequency. Not investigated further.
- Best next test: the vendor driver on the old Intel Mac playing 1 kHz at 96 kHz, to see whether the card or the console doubles it by itself.

## 96 kHz: full read of the vendor transmit path, ownership, lead scan (2026-10-25)

Vendor transmit path read end to end (AllenAndHeathFW 4.3.1):
- `PrepareSendDCLs`: per bus cycle two DCLs are built, a full data packet (SYT interval x DBS x 4 + 8 bytes) and an 8-byte empty one, both flagged 6 (dynamic + update). The data/empty choice is made per cycle by retargeting branches in the send-group callback. Not rate dependent.
- `FillFirewireBuffers` writes only the CIP header and the MIDI slots. Header bytes: SID, DBS, 0, DBC (count at the start of the packet, plus the frames of the packet after each data packet); 0x90, FDF, SYT (byte-swapped). Same as ours.
- Audio samples are written by `clipOutputSamples` with `Float32ToSwapInt24_In_32` (24 bits sign-extended in the 32-bit slot, byte-swapped to wire order), one frame per block at stride DBS. The multiplexed layout (consecutive frames in alternate slots) is used only when the stream's split-wire flag is set, which is only for rates above 96 kHz.
- Clock change: the only register written is CLOCK_SELECT = (rate index << 8) | source (master) or | 8 (slave).

Tests after that, all at 96 kHz, 1000 Hz on playback channel 1, tone returned on card channel 31:
- Lead (presentation time minus send time) scanned from 0 to 47,104 ticks in steps of 2,048 (whole 16-cycle window): whenever the card plays, the tone comes back at 2000 Hz; no lead gives 1000 Hz. Playing windows: about 2,048 to 12,288, 20,480, 24,576 and 47,104.
- Owner taken before the rate change like the vendor driver (compare-swap 64 on OWNER with local node id 0xFFC1 and the address of a pseudo address space that auto-replies; library quirk: 64-bit lock values must be byte-swapped): no change, still 2000 Hz. Owner released at the end. At 48 kHz with owner: correct, 1000 Hz.
- Conclusion so far: every item that can be compared with the vendor transmit path matches. Remaining candidates are on the card or console side at 96 kHz, or in something the vendor driver does that this read did not show (per-cycle branch selection, output phase alignment against the capture stream).
- Reference test prepared for the old Intel Mac with the vendor driver: `oldmac-test/` (tone files at 96 and 48 kHz, `measure_freq.py`, README with the steps).

## 96 kHz: firmware read, part 1 (2026-10-26)

Honest scope so far: kernel driver read = transmit path, restart, ownership, sample conversion, capture; firmware = strings, mode tables, and now the stream-port configuration code below; control panel = strings only. Not yet read: most firmware functions (ARX to audio-output setup after a rate change), `GetBusChannel`, notification handling, most of the user client, the control panel.

Firmware (no symbols; offsets in GS_R24_firmware_4.2.0.decompiled.c):
- Two AVS stream ports, 0x34-byte records. Field +0x26 holds the sample-rate code of the port. The wrappers at 0x4c1a0 and 0x4c1b0 set it from the DICE rate code, mapping codes 5 and 6 (176.4 and 192 kHz) to 3 and 4 (split-wire halves), others unchanged: 96 kHz is code 4.
- The port control register gets a "speed class" from that code: 0 up to 48 kHz (code <= 2), 1 for codes 3 and 4 (88.2 and 96 kHz), 2 above. So at 96 kHz the stream hardware is in its double-speed class.
- ARX configuration word (0x474f4): low byte = the rate code, next bits = source node id. ARX therefore checks the incoming FDF against the class. Matches the lock behaviour seen: 16 blocks with FDF 3 or 4 lock, 16 blocks with FDF 2 do not, 8 blocks with FDF 2 lock, 8 blocks with FDF 4 do not.
- The SYT offset helper (0x468d0) turns a frame count into ticks using the base rate of the family only (code 0: 32 kHz, codes 1, 3, 5: 44.1 kHz, anything else: 48 kHz), so for 96 kHz it counts with 48,000.
- Console side nothing yet; the channel-count and mode tables are the same at 96 kHz as at 48 kHz.

More 96 kHz tests (card at 96 kHz, lead 9000, one tone, returned frequency in the 96 kHz capture timeline):
- Slots are independent and additive: tones of 250 Hz (slot 0) and 500 Hz (slot 1) in the 8-block FDF 2 geometry come back as 500 Hz and 1000 Hz, each alone gives the same result.
- Sample-multiplexed layout (slot 2k and 2k+1 carrying samples 2n and 2n+1 of one channel) in all four accepted geometries: comes back at 4000 Hz and 6 dB louder, which a linear independent-slot model does not explain (slot 0 content is identical to the plain test, which gave 2000 Hz). Not understood.
- Ownership taken like the vendor driver: no change. Lead scan 0 to 47,104: no lead gives 1000 Hz.

## 96 kHz: firmware read, part 2 (2026-10-26) — rate change, board setup, ARX/ATX, routing

Read in full this round: DAL init/teardown (0x4b988, 0x4baa8), DAL clock state machine (0x4ce90, 0x4cda4, 0x4cbb0, 0x4cc9c), DAL setters (0x4d3f4..0x4d4f4), router config (0x4c528) and route entry (0x4bc7c), diceClock (0x49100..0x49454), InS port setup (0x4a8d8..0x4abd0), AVS ATX/ARX register setup (0x46ab4..0x46cd4, 0x473d0..0x47e48), DICE stream start (0x4e050), stream table init (0x4e560), board descriptor table (0x60a24..0x60d20), board setup callbacks (0x310b8, 0x31174, 0x31230, 0x3130c, 0x31468). Scripts: `showfw.py` (print decompiled functions by address) and `armdis.py` (capstone ARM disassembly of the raw image, base 0x30000), both in the scratchpad.

Rate change path (CLOCK_SELECT write -> FUN_000307fc):
- Looks up the rate row, takes its class (row +0x14: 0 = up to 48 kHz, 2 = 88.2/96 kHz, 3 = 176.4/192 kHz). Only if the class differs from the current one does it call FUN_00030734(class): DAL re-init with that class as "mode", board descriptor stream tables of that class, board setup callback (+0x1c of the descriptor) and router setup. Then it applies the clock source/rate through the DAL (FUN_0004bc0c).
- Rate rows (image at 0x5d3b0, 28 bytes, row base is 8 bytes before the first printed field): rate Hz at +8, PLL words at +0xc and +0x10, class at +0x14, rate code bytes at +0x18/+0x19/+0x1a. 48 kHz and 96 kHz rows have the SAME PLL words (0x400 and 1); 44.1 and 88.2 kHz share another pair (0x272f and 9). So the PLL/divider setup is identical at 48 and 96 kHz; only the class differs.
- Class goes to bits 5:4 of the clock block register +4 (0, 1, 2 for classes 0, 2, 3). That is the only clock-side difference between 48 and 96 kHz.

Board descriptor for "GSR-24 32/32 FW" (0x60afc): three stream tables (low 0x60a54, mid 0x60a9c, high 0x60ae4), then 0x1830, 0x1830, 0x1080001e, 0x5ba88, then three callbacks: 0x312ec (class setup switch: class 2 -> 0x31174, class 3 -> 0x31230, else 0x310b8), 0x3130c (InS ports setup, ignores the class), 0x31468 (a register write 0x90/0x290/0xc90 to 0xc3000000 depending on a second argument 2/3, i.e. a rate dependent value for the ADAT/other block).
- Stream tables for low and mid class are identical: stream 0 = 3 MIDI + 16 audio named CH1.., stream 1 = 16 audio. The high class differs only by two small codes (7 and 9 instead of 5 and 6).
- Router setup for low class (0x310b8) and mid class (0x31174) is byte for byte the same: routes 0x13<->0x33, 0x813<->0x833, 0x17<->0x2f, 0x817<->0x82f (route entry = size code bits 1:0, block bits 5:2, slot offset bits 13:8; blocks 4 and 5 = the two 16 slot InS audio ports to the console, blocks 0xB and 0xC = the two ARX/ATX stream groups). The same 16 + 16 slots are connected at 48 and 96 kHz. Only the high class (176.4/192 kHz) halves the lanes.
- Conclusion: the firmware does NOT reconfigure the receive routing or the InS ports differently between 48 and 96 kHz. At 96 kHz the chip runs the same configuration with the double speed class and rate code 4.

AVS ports:
- ATX control register (0x46b18): DBS in bits 4+, class bits 0x1000000 (rate code <= 2), 0x1100000 (3, 4), 0x1200000 (> 4). ARX has no class bits in its control register (0x474b0: channel, bits 7:6 from +0x28, constant 0x210000); the ARX config word (0x474f4) is: low byte = rate code (OR a flag byte), bits 13:8 source node, 0x4000 flag, 0x80000000 flag, DBS in bits 21+. So on the receive side the rate code in the low byte is the only rate information the ARX gets (it validates the incoming FDF against it).
- ARX offset word (0x47574): 4 slot-map words (ARX slot -> audio slot, one byte per slot, set by FUN_00047b6c with first audio slot + 1 + index) and a presentation offset (frames + hundredths of a frame, converted to 24.576 MHz ticks with the BASE rate of the family: 48000 for code 4). So the receive presentation offset is computed as if 96 kHz were 48 kHz: one frame counts 512 ticks instead of 256. This explains why the accepted lead window is lower at 96 kHz.
- Stream start (0x4e050): for each RX stream: stop port, write the slot map, number of channels, MIDI, rate code (FUN_00047c60, with the code reduced by 2 only for codes above 4), isochronous channel, then start. Nothing else rate dependent.

What this means for the doubling:
- Everything read so far is consistent with a plain double class; no firmware path found that doubles the ARX drain rate. The measurements (8 blocks at FDF 2 and 16 blocks at FDF 4 both give 2f; the multiplexed layout gives 4f) say the card drains blocks at twice the supplied rate, but a rate-class mismatch inside the ARX would only be visible in code I have not read: the hardware itself (registers 0xcf... and the AVS block) is not in the image, so its behaviour cannot be read from the firmware.
- Not read yet: diceHPLL (0x495a4..0x497a4), diceAES, avsFmt.c (0x5a820..0x5b010), the rest of dalClkCtrl, ATX stream start (0x46d28..), kext GetBusChannel / notification / user client, control panel logic.
- Next discriminating test remains the vendor driver on the old Mac (oldmac-test/). Test setup stays as the user left it: console oscillator 1000 Hz on card channels 16 and 17.

## 96 kHz: reading part 3 (2026-10-26) — PLL, formatters, ATX start, vendor StartStreams / notifications

Firmware:
- PLL/HPLL (0x495a4): the DAL writes only two divider values (row words 0x400 and 1 for 48 and 96 kHz, 0x272f and 9 for 44.1 and 88.2) plus the class bits. No rate specific code beyond that.
- avsFmt.c (0x5a7bc..0x5b25c): per-port formatter registers (slot byte order/label fields, per-slot enables, mute). Only the transmit formatter is programmed at stream start (mode 5: label 0x40 on each of the 16 slots, from FUN_0005b010 called by the ATX start). The receive formatter modes (0, 1, 3) are never called from the stream start path, so the ARX formatter keeps its reset state at every rate.
- ATX start (0x46d28): offset word (FUN_00046b9c, same 48 kHz base conversion as the ARX), DBS/MIDI flags, class bits, enable. Nothing else rate dependent.
- A rate class dependent register write exists in the board callback 0x31468: register 0xc3000000 gets 0x90 (classes 0, 1), 0x290 (class 2) or 0xc90 (class 3). Called from the DAL clock event handler (0x30910, event 8) with the new class. Most likely the clock/frame format of the link to the console. It is set by the card by itself, not by the host. Meaning of the bits unknown.

Vendor kext:
- `SampleRateToSYTDifference` = ticks per frame: 0x200 (512) at 48 kHz, 0x100 (256) at 96 kHz, 0x22d at 44.1, 0x116 at 88.2/176.4. The SYT step per data packet is interval x difference = 4096 ticks at 48 and 96 kHz (StartStreams stores it at +0x17f7c8). Same as ours.
- `StartStreams` order: fill every send buffer, write ENABLE = 1 to the card (async write), sleep 2 ms, then start the send ports, then the receive ports. Ours starts the register sequence first and the DMA after; not shown to matter at 48 kHz.
- `ReportChannelAndSpeedToHardware`: RX stream (host to card): ISOCHRONOUS = channel and SEQ_START = 0; TX stream (card to host): ISOCHRONOUS = channel and SPEED. Identical to ours.
- Notifications: bit 0x10 of the card's notification triggers a read of the status word; if it shows lock at the current rate the send groups get a "resync allowed" flag set. No register write, no stream reconfiguration.

Summary of the whole read so far (kext transmit/start/notify, firmware clock/DAL/router/AVS/formatters/board tables): nothing found that makes the card drain receive blocks twice as fast at 96 kHz, and nothing in the vendor driver that we do differently on the wire. The cause is either in hardware behaviour the firmware only configures (ARX at double class), or on the console/card link at 96 kHz.

Discriminating tests that do not need the old Mac (to run only when the user decides):
1. Continuity of the doubled tone: capture the returned tone raw for a few seconds and look at the envelope. Gaps (about half the time silent) = the ARX is starved because it drains twice as fast; continuous = the card really receives twice the samples we think we send (framing issue).
2. Same at 88.2 kHz with a lead scan (44.1/88.2 never locked the same way).
Reference test with the vendor driver (oldmac-test/) stays the decisive one.

## 96 kHz SOLVED on the playback side: the "doubling" was the console's digital return (2026-10-26)

New reference: the console's analog master goes into input 1 of a MiniFuse 2 (USB, recorded with ffmpeg avfoundation `-i ":8"`, 4 channels, labelled 96 kHz) and the MiniFuse channels 3 and 4 carry a steady reference tone that the user left at 1000 Hz. The MiniFuse timeline is not trustworthy in absolute terms (the same tone reads 1085 Hz in one recording and 915 Hz in another, ffmpeg resampling), so the frequency of the played tone (channel 1) is always compared with the reference tone (channel 3) in the same recording. Scripts in the scratchpad: `mfrun.sh RATE LEAD CHANNEL`, `mfan.py` (per block frequency and level), `mftones.py` (24 tone check).

Results (tone 1000 Hz, -30 dBFS, playback through the card, analog master recorded):
- 48 kHz control: played tone / reference = 1.00 (1083 against 1084 Hz), level -37 dB, steady.
- 96 kHz, lead 3000 and 6000: same tone, same ratio 1.00, same level (-37 dB), steady for the whole run. Lead 9000 flaps (level -43 dB, lock bit toggling), lead 12800 gives nothing.
- 96 kHz, playback channel 20 (second RX stream), lead 4500: ratio 910/913, level -37 dB.
- 88.2 kHz, lead 4500: ratio 912/917, level -37 dB. 44.1 kHz, lead 6000 and 12800: ratio 915/920 and 922/926, level -37 dB.
- 24 tone sweep (250 Hz x N, -36 dBFS, both RX streams): the analog spectrum at 96 kHz has the same level pattern per tone as at 48 kHz (within a few dB).
So playback to the card works at 44.1, 88.2 and 96 kHz with the right frequency. The earlier "returns at 2000 Hz" was measured on card channels 31/32 (the console's digital master return, "2 Track 1 out"). At 96 kHz that digital return comes back at twice the frequency while the analog master of the same console is right, and the oscillator on channels 16 and 17 is also right. So it is a property of the console's 2-track digital output at 96 kHz (or its mapping on 31/32), not of our stream. The firmware read found nothing in the card either. The old-Mac reference test is no longer needed for this.

Settings that matter: SYT lead (presentation time minus send time) 12800 ticks up to 48 kHz, 3000 to 6000 ticks (4500 used) at 88.2 and 96 kHz. This fits the firmware: the receive offset is counted with the 48 kHz base at 96 kHz. `gsrloop` now defaults to 4500 for -r 88200 and above.

Measurement rule from now on: use the analog master on the MiniFuse (compare with its reference channel) as ground truth for what the card plays; use the card's own TX capture only for the card's inputs (channels 1 to 30), not for the master return on 31/32 at 88.2/96 kHz.
Open: why the digital master return doubles at 96 kHz (console), 0.25 s lock flapping at lead 9000, only a 1 channel test of 88.2 and 44.1 so far.

Correction to the paragraph above (same day): the MiniFuse timeline is fine. The 910 / 1090 Hz readings come from the recorder: in the ffmpeg avfoundation capture both the played tone (channel 1) and the reference (channel 3) show a centre line at 1000 Hz (996 to 1006 Hz) with two sidebands of about the same height at about 910 and 1095 Hz (modulation at roughly 92 Hz from the capture path), and the peak picker of `mfan.py` sometimes took a sideband. `mfpk.py` shows the three strongest lines per block. Played tone and reference have the same line structure in every block, so the conclusion stands: the card plays 1000 Hz at 44.1, 88.2 and 96 kHz, and the analog master carries 1000 Hz at 96 kHz. The "time scale" numbers in the notes above (1085 / 915) are artefacts of that and should be ignored; only the played-versus-reference comparison counts.

## CORRECTION (2026-10-26, evening): the 96 kHz "doubling" was a bug in gsrloop, not the console, not the card

The two previous sections ("SOLVED ... console's digital return") drew the wrong conclusion. Found by looking at the status words during a run: the poll lines showed STATUS 0x00000201 (nominal rate code 2 = 48 kHz) while the tool believed it was at 96 kHz, and the card's own TX data packets carried 8 blocks, not 16, whenever playback was on.

Cause: `gsrloop` measures the card's SYT timeline in a first pass (capture only, 0.6 s). That pass ended with `restoreCard()`, which also puts the original clock (48 kHz) back; the main pass never wrote the requested rate again. So every playback run with `-r` above 48 kHz since the measurement pass was introduced streamed 96 kHz format packets (16 blocks, FDF 4) to a card running at 48 kHz, and decoded the card's 48 kHz capture as if it were 96 kHz. A 48 kHz capture read at a 96 kHz timeline gives exactly the "2x frequency" (and the oscillator on 16/17 doubled too, only while playing; capture-only runs were right, which is why the earlier M2 results at 96 kHz stand). The lead window, the FDF tests and the 8 versus 16 blocks tests of that period were all measured against a 48 kHz receiver and mean nothing for 96 kHz. The MiniFuse analog recordings of today ran in the same state and prove nothing about 96 kHz either.

Fix: the measurement pass now stops the streams without restoring the clock (`gKeepClock`). With it, the poll shows STATUS 0x00000401 during the run and the capture has 16 blocks per data packet.

Re-measured at the real 96 kHz (return of the console master on card channels 31 and 32, tone 1000 Hz, -30 dBFS, playback channel 1, one RX stream):
- the tone returns at 1000 Hz, -32.4 dBFS, same level as at 48 kHz, no dropout; the oscillator on 16/17 stays at 1002 Hz;
- lead (presentation time minus send time) 1000 to 9000 ticks all play (1500 had one short dropout); 12800, 17000 and 21000 do not lock. 4500 is used as default for 88.2 kHz and above; 12800 is the 48 kHz value;
- 44.1 kHz and 88.2 kHz: tone present, -32.4 dBFS, no dropouts;
- two RX streams (24 tones): 24 of 24 at leads 3000 and 8000, 22 to 24 at 2000, 4500 (3 runs: 24, 15, 23), 5500 (22, 24, 24), 6000 and 8000 (22, 22). Lock bits 0xC0 when it works; in the failing runs only the first stream (0x40) locked. So 96 kHz works but the second stream is not yet reliable at the start. At 48 kHz it was clean over 120 s.
- MiniFuse: the played tone and the reference tone have the same line structure again at 96 kHz (this time really at 96 kHz).

Consequences:
- The user's use case works: a computer source mixed in the console and the master recorded on card channels 31/32 at 96 kHz returns the right frequency and level.
- The question about the console or the card doubling at 96 kHz is closed; the firmware read of parts 1 to 3 stays valid as documentation but explained nothing, because nothing was wrong.
- Open: start-up reliability of the second RX stream at 88.2/96 kHz (stream 1 sometimes never locks, other times loses the first fraction of a second); a long run at 96 kHz; the lead behaviour to be understood (window 1000 to 9000 at 96 kHz against about 12800 at 48 kHz, probably the 48 kHz base conversion of the receive offset).
- Lesson for the tools: after any cleanup step, check the nominal rate field of STATUS during the run and the blocks per data packet, not only the rate the tool asked for. `gsrloop` now prints the STATUS poll lines, whose rate field must match the request.

## Vendor start order and OWNER by default (2026-10-26)

`gsrloop` now does what the vendor `StartStreams` does: take OWNER first (compare-swap, as the vendor driver; released at the end; `--noowner` to skip), set channels/speeds on every stream, write ENABLE = 1 once, wait 2 ms, start the send ports, then the receive (capture) port. The port start handlers no longer write ENABLE in this mode. The old order (capture first, ENABLE from the start handler) is kept as `--ourorder`.

Results at the real 96 kHz (STATUS 0x401 throughout), 24 tones on both RX streams, console master return on card channels 31/32:
- 16 of 16 runs of 5 s: both receive locks (EXTENDED_STATUS 0xC0) from the first poll at 0.25 s; every tone found. Tones 16 and 17 are missing in most runs because channels 16 and 17 of the console currently carry the oscillator (in 2 of 10 runs they were found). Before the change, the same test lost the second stream or part of the tones in about 3 runs out of 10.
- 120 s run: lock bits never changed from 0xC0, STATUS stayed 0x401, 0 dropout blocks, 0 CIP errors, 0 DBC discontinuities, 980,016 packets captured, 1,960,008 packets sent on two streams, longest send callback gap 35.5 ms, card SYT advance steady at 4095.4331 ticks.
- 48 kHz with the new order: both locks from 0.25 s, 22 of 24 tones (16 and 17 are the oscillator), clean.
Not separated: which of the two changes (order or OWNER) made the difference; both are on by default now. Not yet done: 88.2 kHz with 24 tones, 44.1 kHz with 24 tones, a run of 5 minutes or more, load and bus reset tests.

Correction (same day): tones 16 and 17 are missing on card channels 31/32 because console channels 16 and 17 are not assigned to the master (confirmed by the user, nothing was changed on the console). It is not the oscillator and not the driver: tones sent alone on playback channels 15 and 18 return at -32.5 dBFS, 16 and 17 never (48 kHz). In 2 of 10 sweeps at 96 kHz they were listed as found; unexplained, probably the detector (4000 and 4250 Hz among 22 other tones), not checked. So the expected result of a 24 tone sweep with this console setup is 22 of 24.

## 24 channels at 88.2 and 44.1 kHz, two more 120 s holds at 96 kHz (2026-10-26)

Vendor start order and OWNER on (defaults). Console master return on card channels 31/32; channels 16 and 17 are not assigned to the master, so 22 of 24 is the full result.
- 88.2 kHz (STATUS 0x301 during the run), 3 runs of 8 s: 22, 24, 22 tones, both receive locks 0xC0 from 0.25 s, 44 of 48 tone/channel pairs without any dropout in each.
- 44.1 kHz (STATUS 0x101), 3 runs of 8 s: 22, 22, 22 tones, locks 0xC0, same.
- 96 kHz, 120 s, 24 channels, second long run: STATUS 0x401, 0 CIP errors, 0 DBC discontinuities, 981,112 packets, 0 dropout blocks in the 0.5 s level monitor (44 of 48 pairs; 16/17 not on the master). But the lock flags dropped to 0 for one poll (at most 0.25 s) twice, at 27.9 s and 36.0 s, then came back to 0xC0 by themselves. The first long run (same settings) had no such blink. Longest send callback gap 29.6 ms. Not explained; the level monitor (0.5 s blocks, 3 dB threshold) did not see an audible effect, but a shorter gap would not show there.

## CPU load test at 96 kHz (2026-10-26)

`loadrun.sh N SECONDS RATE`: N busy-loop processes (normal priority) while `gsrloop` plays and captures 24 channels at 96 kHz for 60 s. The Mac has 8 logical cores (6 performance, 2 efficiency) and was already busy (load average about 6, the Green-GO Control app at about 100% of a core). `gsrloop` runs at normal priority, ring 640 slots = 80 ms. The busy loops were stopped by PID after each run; none left.
- 16 busy loops (2 per core): locks 0xC0 all the time, 0 dropout blocks, longest send callback gap 20.9 ms, capture clean.
- 32 busy loops (load average about 90): same, 0 dropout blocks, longest gap 67.3 ms (ring 80 ms), locks stayed.
- 64 busy loops (load average over 100): longest gap 126 ms, more than the 80 ms ring; the receive locks dropped nine times for one poll or less (also one case with only one stream locked), 190 dropout blocks of 0.5 s, 26 of 48 pairs without dropout. Capture counters stayed clean (the capture ring was not overrun, only the playback fed late).
Reading: up to a load 4 times the core count the user space tool holds at 96 kHz; the failure comes when a scheduling gap exceeds the playback ring (80 ms). The daemon should run its isochronous thread at real-time priority and use a ring deeper than 80 ms (160 ms), at the price of latency; to be decided with the buffer size offered to CoreAudio.

## Cable unplug test (2026-10-26): the tool does not survive a bus reset, and the Mac keeps a stale device

Run: `gsrloop --go --upto 24 -t 50 -C 1 -r 96000`, cable unplugged at about 22 s (voice cue) and plugged back at about 34 s.
- Up to the unplug: normal (locks 0xC0, 20.5 s of every tone, 0 errors). After it, the tool never noticed the bus reset; it did not stop at 50 s and was interrupted by hand at 147 s (SIGINT, then it exited). Its cleanup could not write the card: "rate restored: NOT LOCKED", ENABLE read as 99, 2020 register retries.
- Afterwards the Mac no longer enumerated the card for user space: `dicedump` and `gsrloop` report "no device found". The IO registry kept `IOFireWireDevice@4c40400400345` marked `inactive, busy 2` (326 s and counting) with a child `IOFireWireUserClient` created by pid 40633 (the dead gsrloop), `inactive, busy 1`. A fresh node for the same GUID was not created, even after the console was power cycled. So the user client of the killed process was not released by the kernel while the bus reset was in flight (pending isochronous resources or commands), and it blocks the device. Nothing was written to the card after the unplug except the failed cleanup.
- What to do for the daemon: handle the bus reset callbacks of IOFireWireLib (generation change), stop the isochronous channels and release every resource (channels, pseudo address spaces, local ports) from the bus reset handler, not from the normal shutdown path; do not rely on process exit. Never leave a blocking wait in the main run loop after a failed command.
- Recovery tried/to try: replug the FireWire cable (no effect), power cycle the console (no effect); next: unplug and replug the Thunderbolt to FireWire adapter at the Mac (removes the whole controller node), else restart the Mac.

Recovery (same day): replugging the FireWire cable and power cycling the console did not help. The Thunderbolt to FireWire adapter was not detected at all (system_profiler: "No device connected" on all three ports) until it was plugged in again properly; then a new `AppleFWOHCI` / `IOFireWireDevice` node appeared (active) and `dicedump` read the card again. The stale inactive nodes stay in the registry (busy for over 10 minutes) but do not matter. Card state after all this, read only: no owner, ENABLE 0, CLOCK_SELECT internal 48 kHz, locked, nickname unchanged. Nothing needed restoring. The unplug in the test was therefore at least partly at the Thunderbolt adapter level (the whole OHCI controller went away), not only the FireWire cable; a plain FireWire cable pull (controller stays) is still to be tested separately.
Detail from the user: the adapter was plugged back into a different Thunderbolt port, and that is what made the card appear again. The previous port stayed unusable for the stuck controller node; a different port gets a new controller node.

## gsrloop: bus reset handling, and a correction about OWNER (2026-10-26)

Bus reset: the tool now notes the bus generation when the streams start and compares it every 0.25 s (the IOFireWireLib bus reset handler is also installed, with ClientCommandIsComplete, but it was not called in a forced reset, so the generation check is what triggers). On a change: it prints "BUS RESET detected ...", stops the channels, releases them, then waits up to about 3 s for the card to answer (fail-fast register access: 2 tries of 20 ms after a reset instead of 10 of 50 ms); if it answers it restores ENABLE, channels, clock and owner; if not it writes nothing and says so. Exit code 4. Test without touching the cable: `--busreset-at S` asks the bus for a reset S seconds after the start (BusReset()). Result at 96 kHz: reset at 6 s, detected within 0.25 s, clean stop, card restored (ENABLE 0, 48 kHz internal, no owner, locked), exit 4, no stale node in the registry. In the real cable pull test the old tool needed 147 s (2020 register retries) and left the Mac with a stuck controller node.
Not yet tested: the real cable pull with the new tool (FireWire cable only, adapter left in place).

Correction: the earlier note "OWNER on by default" was only half true. The measurement pass released OWNER (restoreCard) and the main pass ran without it, so the 16 good runs and the 120 s run of that note ran WITHOUT owner: the start order alone gave the improvement. Fixed now (the owner is kept through the measurement pass and released at the end). With the owner really held: 10 runs of 24 tones at 96 kHz, both locks 0xC0 each time, 22 of 24 each time (16 and 17 are not on the master). So owner does no harm; whether it helps is not shown.

## Real cable pull with the new bus reset handling (2026-10-26)

Run: 96 kHz, 24 channels, FireWire cable pulled on the console side at about 24 s (voice cue), plugged back at 38 s, Thunderbolt adapter left in place.
- The tool detected the bus reset at 24.33 s, stopped the streams, found the card unreachable and wrote nothing ("card does not answer after the bus reset"), exit code 4, and was finished by the time the cable was plugged back (the old tool needed 147 s). No stale node: the Mac re-enumerated the card by itself (a new active IOFireWireDevice appeared within seconds; the old stale node from the first test is still listed, inactive).
- State of the card after the replug (read only with dicedump): no owner, ENABLE 0 (the card stopped streaming by itself), but what the aborted run had written was still there: CLOCK_SELECT at 96 kHz, TX stream 1 ISOCHRONOUS 0, RX streams 1 and 2 ISOCHRONOUS 1 and 2. These are volatile registers this tool wrote, not restored because the card was unreachable at the time.
- Put back with the new `gsrloop --cleanup --go` (writes only: ISOCHRONOUS = -1 on all four streams, ENABLE = 0 if set, rate 48 kHz). Afterwards: all four streams -1, 48 kHz internal, locked, no owner. A normal 96 kHz run works again (tone returned at -32.4 dBFS, 3 of 3 runs). One earlier run right after the recovery reported a bus reset by itself (bus still settling after the replug); the detection worked as intended.
- For the daemon: after a bus reset the device registers must be assumed dirty: when the card comes back, read and clean the stream ISOCHRONOUS values and the clock before starting, and take OWNER again.

## Spike: sharing memory with a sandboxed AudioServerPlugIn (2026-10-26)

`spike/` (helper standing in for gsrd, plug-in without a device, scripts; ad-hoc signed, installed by the user with `sudo ./install.sh`). Result in the unified log (tag GSRSPIKE): the plug-in is loaded and hosted by `Core Audio Driver (GSRSpike.driver)` (`com.apple.audio.Core-Audio-Driver-Service.helper`, uid 202, the `_coreaudiod` user). From inside that sandbox all three ways of reading the helper's memory worked, live (the counter moved while it watched):
- A. XPC over the Mach service declared in the plug-in's `AudioServerPlugIn_MachServices`, reply carrying an `xpc_shmem` object, mapped 1 MiB, live.
- B. POSIX shared memory `/gsr24m-spike`, read-only, live.
- C. A file `/Library/Application Support/GSR24M/ring.bin` mapped read-only, live.
The helper ran as a LaunchDaemon (system domain), which is required for the Mach service to be visible to `coreaudiod`; it logged the client connection and the request.
Observation to keep: in this test the helper's 1 ms dispatch timer ran at about 3 ms per tick and a 50 ms sleep in the plug-in took about 150 ms of host time. Dispatch timers and sleeps in these processes are coalesced; the real ring producer must be a real-time thread driven by the FireWire callbacks, and the plug-in must never sleep or wait in the IO path.
Consequence for the design: the ring hand-over works with plain shared memory; XPC `xpc_shmem` stays the first choice (explicit, tied to the Mach service), POSIX shm or a file are working fallbacks.

## HAL plug-in with a device, tested against a stand-in for gsrd (2026-10-26)

`hal/`: `gsr_ring.h` (shared memory layout: header, input ring, output ring, clock anchor with a seqlock, channel names, latency fields, rate request), `plugin.c` (`GSR24M.driver`, AudioServerPlugIn: one device with 32 in / 32 out float32, rates 44.1/48/88.2/96 kHz, stream and device properties, channel names per element from the ring header, zero time stamps from the anchor, `ReadInput` and `WriteMix` straight from and to the rings, free-running clock and silence when gsrd is absent), `devsim.c` (stand-in for the card side, test code only: simulated card clock +138 ppm, tone per input channel, check of the output ring), `harness.c` (plays CoreAudio against the plug-in without installing), scripts `build.sh`, `install.sh`, `uninstall.sh`, `update-sim.sh`.
- Offline harness (no install): all checks pass: properties, names from the header, device clock 96013.248 frames/s against 96013.248 expected, input tones 200.0 and 1750.0 Hz, output tones 440 and 880 Hz seen by the card side without late frames, rate change through SetPropertyData (48 kHz accepted, 12345 refused, plug-in follows the card).
- Installed in coreaudiod (user ran `sudo ./install.sh`): the device "GS-R24M FireWire" shows up with 32 inputs, 32 outputs, transport FireWire, 48 kHz; the plug-in got the ring over XPC from the LaunchDaemon. First recording through CoreAudio (ffmpeg avfoundation): 32 channels, level right on all (-23.1 dB for 0.1 amplitude), but the plug-in counted about 1200 missing input frames per second: the simulated card clock was a plain daemon thread, timers about 3 ms late, more than the 192 frame safety offset. Fixed in the stand-in by making its clock thread real-time (the real gsrd is driven by FireWire callbacks and will run its thread at real-time priority).
- Found by restarting the daemon: the plug-in kept the dead daemon's ring and delivered silence. Fixed: the plug-in drops the ring when the anchor has not moved for 2 s and asks again (old mapping left in place; IO running count handed to the new daemon).

Native CoreAudio test of the installed device (`hal/cadevtest.c`, IOProc on the device like a DAW; the stand-in writes channel k = 0.1 sin(2 pi (200 + 50 k) S / rate) with S = sample time, so every input frame can be checked exactly):
- 48 kHz, buffer 256: 264,512 input frames compared over 32 channels, 0 frames with an error above 0.002 (worst error 0.00000), 0 sample time jumps between callbacks, output side without jumps.
- Same result (all PASS, 0 errors, 0 jumps) after changing the rate from the client through SetPropertyData to 96000 (buffer 256), 88200 (buffer 64), 44100 (buffer 1024) and back to 48000 (buffer 512); the stand-in restarts at each new rate and the plug-in follows. Seen by the card side: 440.0 and 880.0 Hz on output channels 1 and 32.
- Earlier recordings with ffmpeg avfoundation showed frequency errors of a few Hz and phase breaks; the native test shows none, so those came from the recorder (same as the MiniFuse recordings), not from the plug-in.
- Side effect: the new device became the Mac's default output device. It was put back to the MiniFuse 2 with `cadevtest --set-default-output "MiniFuse 2"`. The plug-in reports CanBeDefaultDevice = 1; to be decided for the product (a normal interface does so).
- At each start of IO the stand-in counts about 700 output frames as late: the "card" starts playing before the first block from the client exists. The real gsrd should wait for the first block of the client (outWritten above the play point) before it feeds audio.

## gsrd: the real engine behind the shared rings (2026-10-26)

`gsrd/gsrd.c` (engine derived from gsrloop, `build.sh`, `install.sh`, `uninstall.sh`, LaunchDaemon plist) and `gsrd/ringcheck.c` (test client for the ring file). Modes: `gsrd --file PATH` (ring in a file, no daemon, for tests) and `gsrd --xpc` (LaunchDaemon, Mach service `com.gsr24m.gsrd`). It opens the card, refuses to touch it if another host owns it, cleans left-over stream registers, takes OWNER, then runs sessions: set rate, read layout and channel names (name before the first '/'), measure the card's presentation time advance with the capture stream alone (0.6 s), build the playback ring, allocate the four channels, ENABLE once, 2 ms, send ports then receive ports (vendor order), run with a real-time main thread, a bus generation check, a rate request check (the plug-in writes `requestedRate`) and a 1 s EXTENDED_STATUS log. On rate change or bus reset the session is torn down and rebuilt; on exit the card is put back (idle, clock restored, OWNER released).
First run on the real card (file mode, 48 kHz, ringcheck as the client):
- Card found, presentation advance 4095.432 ticks per data packet (-138.7 ppm), both receive locks (0xC0), capture packets 150,177 / 150,171 with 0 CIP errors and 0 DBC jumps, longest send callback gap 2.2 ms, card put back (clock 0x20c, OWNER released).
- Input ring: console oscillator on card channels 16 and 17 read as 1000 Hz, -33/-32 dBFS.
- Output ring: a 440 Hz tone written the way the plug-in does (120 ms ahead of the capture clock) came back from the console master on card channels 31 and 32 at 441 Hz, -25.4 dBFS, 0 late output frames, 0 late input frames.
- Output alignment from the bus cycle time (GetCycleTimeAndUpTime against the DMA time stamp of the first presented packet, DLL anchor for the capture axis): playback block p plays at capture sample time p + 28 frames (0.58 ms), as expected from the 12800 tick presentation lead. Finding: the DMA time stamp carries only 3 bits of bus seconds (the cycle time register has 7); the comparison is done modulo 8 s.
- Stream alignment: using the presentation time (SYT) difference of the two TX streams to line them up gave lags between channels 16 and 17 that moved with the computed offset (-5, -11, +12 frames); with both streams written from their own frame 0 the lag was -3, -2, -2 frames in three runs, i.e. stable. The two TX streams start on the same card frame; the SYT based offset was wrong and is now off by default (`GSR_ALIGN_SYT=1` to try it). The remaining -2 frames between the two oscillator channels may be the console, not the card.

## 24 bit presentation, and the anchor freshness bug (2026-10-26)

- The card is 24 bit. The CoreAudio device now presents a 24 bit signed integer, packed (3 bytes x 32 channels = 96 bytes per frame) as the PHYSICAL format of both streams, and Float32 as the virtual format clients get; the HAL converts between the two (the plug-in does not claim ConvertInput/ConvertMix). `ReadInput` and `WriteMix` therefore work in the native 24 bit format: float ring to int24 with scale 2^23 and clipping, int24 to float, and the engine converts the output ring to the wire with the same scale 2^23 (clamped), so a 24 bit value goes through the whole chain unchanged. Float32 would have carried 24 bits without loss anyway; this is about what the device announces in Audio MIDI Setup and about a clean integer path.
- Found on the real card through CoreAudio: the sample times given to a client alternated between two time lines (28 jumps in 8 s): the gsrd one, and the plug-in's free-running fallback. Cause: the anchor host time can be slightly ahead of the plug-in's `mach_absolute_time()`, and the unsigned age test called that anchor stale. Fixed with a signed age.
- Measured on the real card with the first (buggy) plug-in: loopback output channel 1 to input channel 31 (noise burst, cross-correlation): 111 frames = 2.31 ms (correlation 0.73, degraded by the jumps); to be measured again. Output alignment estimate from gsrd varied from +28 to -2 frames between two sessions: to be tightened (calibrate later, or average).

## End to end on the real card through CoreAudio (2026-10-26)

LaunchDaemon `gsrd` (system domain, Mach service `com.gsr24m.gsrd`) + HAL plug-in `GSR24M.driver` + `hal/cadevtest` (IOProc on the device like a DAW). The card is clocked by its own internal clock, the console oscillator is on card channels 16 and 17, the FireWire returns of the console go to the master (card channels 31 and 32).
- Found: the HAL keeps the device properties it read before gsrd was there (safety offset out 256 instead of 2064 at 48 kHz). The plug-in now announces latency, safety offsets, channel names and rate (PropertiesChanged) when the ring appears and on a rate change. Before that, all output arrived late and was dropped.
- With that: rate 96 kHz (set by CoreAudio), IO buffer 256, safety in/out 384/4128 frames: 0 sample time jumps on input and output, input channels 16 and 17 read as exactly 1000.0 Hz (-32.9/-32.1 dBFS), output 440 Hz on channel 1 returns on channels 31 and 32 at 440.0 Hz.
- Round trip (noise burst on output channel 1, cross-correlation with input channels 31/32, all in the device sample time): 106 frames = 2.21 ms at 48 kHz, 172 frames = 1.79 ms at 96 kHz. The correlation peak is 0.73 with 0.57 on the neighbouring lag, i.e. a fractional delay of about half a frame (about 105.6 frames at 48 kHz); a pure delay of white noise looks like that. So the sample time axis the app sees is consistent with the card: what is written at output sample time S is heard at S and comes back about 2.2 ms later through the console.
- The user-visible latency is therefore dominated by the playback safety offset: lead + 3 ms. The earlier 207 ms gap between send callbacks in a long idle session (above the 40 ms lead, which means the card was fed stale data from the previous lap) led to a configurable lead: `gsrd --lead-ms N` (default 80 ms, 10 to 400); the safety offset reported to CoreAudio follows (lead + 3 ms). `gsrd` now logs statistics every 30 s (packets, CIP errors, DBC jumps, longest gap, late frames).
- Output alignment estimate from the bus cycle time varied from -6 to +28 frames over sessions (0.1 to 0.6 ms): not critical, to be tightened.

150 s hold through CoreAudio (lead 80 ms, 48 kHz, buffer 256) before the next fix: input side clean: 20,000 callbacks, 0 sample time jumps, channels 16/17 at 1000.0 Hz, gsrd statistics every 30 s: 0 CIP errors, 0 DBC jumps, longest send callback gap 2.3 ms for the whole run (900k packets), input late 0. Output side: every output frame late (48,000 per second): CoreAudio still used the safety offset read before the daemon restart (2064 frames = the old 43 ms) while the daemon now reads the output 83 ms ahead; `PropertiesChanged` for the safety offset does not make the HAL re-read it (the header said 3984, CoreAudio kept 2064). Fix: the plug-in now asks for a device configuration change (`RequestDeviceConfigurationChange`, action "refresh") when the ring appears or when latency or safety values in the header change; the HAL then re-reads all properties (this is what already worked for rate changes: 4128 at 96 kHz). The configuration change stops and restarts the IO of the clients once.

Correction (same day): the "clients 2" seen in the gsrd statistics during the 60 s hold was not a leaking counter. Apple Music was playing at the same time, and the GS-R24M device had become the Mac's default output again after the plug-in was reinstalled, so there really were two IO clients (the test tool and Apple Music). The ioClients counting was right. The change in gsrd that decides whether a client is active from recent writes to the output ring (last 250 ms) instead of from the counter stays as hardening (a client that dies without StopIO cannot make old audio replay), but the leak diagnosis was wrong.

## Music through the whole chain (2026-10-26)

Apple Music (default output = the GS-R24M device, 48 kHz) -> HAL plug-in -> output ring -> gsrd -> card -> console -> master -> card channels 31/32 -> gsrd -> input ring -> plug-in -> `cadevtest --rec` (records, plays nothing). 90 s: 16,875 callbacks, 0 sample time jumps on input and output; the level of the music at the master followed the volume the user was raising (-42 to -17 dBFS rms over the first 30 s); no run of 24 or more exact zeros on channels 31 and 32 (longest run: 1 frame), so no dropout of the kind a late block would produce (the engine writes silence for a late block). gsrd statistics for the same period: 0 CIP errors, 0 DBC jumps, longest send callback gap 2.3 to 2.6 ms, output late frames constant at 672 (the start only), input late 0, one client. A late or stale block that is not silence (a repeated block) could not be detected this way; the user listens to the monitor for clicks.

Silence test (gsrd with the "client active only if the plug-in wrote in the last 250 ms" rule, installed): music playing, paused at about 15.5 s on a spoken cue, 36 s recording of card channels 31/32 (level per 0.5 s): -15 to -26 dBFS while playing, then -82/-83 dBFS from the very next 0.5 s block to the end (the console's noise floor), no replay of old audio, no run of 24 or more exact zeros while the music played, 0 sample time jumps on 6,750 callbacks.

## App connected to the daemon, channel names to the plug-in (2026-10-26)

- `gsrd` answers more operations on its Mach service: `info` (a JSON string with the identity read from the card, rate, lock, clock sources, stream layout and names, custom names, counters, state, lead), `setRate`, `setLead` (restarts the streams), `setNames` (32 + 32 strings; stored in `/Library/Application Support/GSR24M/names.json` by the daemon so the plug-in has them without the app). Any local process can call them; no access control yet (to restrict with a code signing requirement).
- Channel names: the card's names are kept apart from the user's names; the header gets the user's name if there is one, otherwise the card's (`namesRevision` is bumped, the plug-in announces the change to CoreAudio with `PropertiesChanged` for the element names).
- App: `GSRApp/DaemonClient.swift` (XPC C API from Swift), `GSRCore/DaemonInfo.swift` (JSON model, builds the same `DiceReport` as dicedump; 4 new tests, 19 in all), `AppModel` polls every second; when the daemon answers it replaces the dicedump scan (the daemon holds the card open exclusively, so dicedump cannot read it at the same time); sample rate and operation mode (mapped to the playback lead: Lowest Latency 40 ms, Normal 80, Safe 1 160, Safe 2 300) are now settable; renaming a channel is saved in the app's file and pushed to the daemon, and all names are pushed again when the app finds the daemon. The sync source is still read-only. Without the daemon the app falls back to the read-only scan and says so.
- Tool `gsrd/gsrctl` (info, rate, lead, name) to test the operations without the app.

Rename test through the real chain (daemon operation `setNames` as the app sends it, via `gsrctl`; plug-in and daemon installed): input channel 3 renamed "Kick test" and output channel 1 "Retour 1"; CoreAudio reported the new names (kAudioObjectPropertyElementName on the device) within 2 s, the plug-in logged "channel names changed", the daemon wrote `/Library/Application Support/GSR24M/names.json`; clearing the names returned CH3 and CH1. `PropertiesChanged` is enough for names (unlike the safety offset, which needed a configuration change). Screenshot of the app (0.2) with the daemon running: connected to gsrd, GS-R24, 48000 Hz, locked, Normal Mode, device GS R-24.

User feedback (2026-10-26): in Audio MIDI Setup the 32 channels carry their names and renaming works; default names CH1 to CH32 are fine (that is what the card announces, cut before the '/'). In Logic Pro the device "seems to live its own life": not analysed yet, the user will come back to it. Suspects to check then: the plug-in asks CoreAudio for a configuration change (stops and restarts the clients' IO) when gsrd appears, when the rate changes and when the safety/latency values change; Logic may react to that, or to the 80 ms playback safety offset, or to the buffer size it asks for; the daemon log (/var/log/gsrd.log) and `log show` for "GSR24M" lines give the timing of those events.

User feedback: the sample rate change from the app (menu Sample Rate, daemon restarts the streams, plug-in follows) works cleanly.

## Late input frames: found and fixed (2026-10-26)

The diagnostic of the app (96 kHz, Normal mode) showed "input late 9616" while the card side counters were clean (0 CIP errors, 0 DBC jumps, longest send callback gap 5.5 ms). The counter kept growing in steady state (about 300 to 770 frames per 30 s). A 30 s record-only run through CoreAudio at 96 kHz (`cadevtest --rec`) showed 11 runs of exact zeros on all channels, the longest 136 frames (1.4 ms), and the counter went up by 768 in the same time: a real input dropout (a click), not a start-up artefact. Cause: the input safety offset announced to CoreAudio was 4 ms; the capture callbacks of the daemon are late by up to the longest callback gap (5.5 to 6.3 ms seen), so the HAL sometimes reads frames that have not been written yet and the plug-in returns silence for them. Fix: the input safety offset follows the operation mode: 6 ms (lead 40), 10 ms (80), 16 ms (160), 30 ms (300). To verify after the daemon is reinstalled: the late counter must stay flat and `cadevtest --rec` must show no run of exact zeros. The app table shows the input value next to the output value; the "usage" column was removed at the user's request (too much text).

## Verified: input dropouts gone; opening the app cut the sound (2026-10-26)

- With the input safety offset at 10 ms (Normal mode, 96 kHz): 60 s record-only run through CoreAudio: 20,000 callbacks, 0 sample time jumps, 0 runs of 24 or more exact zeros (longest 1 frame), input late counter 0 before and after, output late 0, longest callback gap 6.8 ms. The 4 ms offset had given 11 dropouts in 30 s.
- "Opening the app cuts the sound": the daemon log showed `session over ... bus reset ... waiting for the card to come back` within 0.2 s of every app start (and a second one when the app re-ran its scan). Cause: at start the app ran its read-only `dicedump` scan before the first answer of the daemon, and a second process opening the same FireWire device makes the daemon (which holds it open) see a bus reset: reproduced with `dicedump -g` alone while streaming: the daemon restarts its session, about 3 s without audio. Fix: the app does not scan when the daemon is installed (`/Library/LaunchDaemons/com.gsr24m.gsrd.plist` exists); it only polls the daemon, and says so if the daemon does not answer. dicedump stays usable only with the daemon stopped. To remember: any tool that opens the card while gsrd runs will interrupt the audio.

## Daemon crash at the end of every session: found (2026-10-26)

`launchctl print system/com.gsr24m.gsrd` showed `runs = 6` and `last terminating signal = Segmentation fault: 11`: the daemon had been crashing and launchd restarted it (KeepAlive). The crash reports (`/Library/Logs/DiagnosticReports/gsrd-*.ips`) all show the same stack: `onSent` called from the run loop (`IODispatchCalloutFromCFMessage`), invalid address 0x19bc. A DCL completion queued on the run loop before a session was stopped is delivered after `freeStreams()` has cleared the stream tables, and `onSent` reads a NULL stamp array. It happened at the end of every session (rate change, source change, lead change, bus reset); because the process restarted in under a second the audio came back, which hid it, and the clean-up that normally follows a session (clock restore, OWNER release) did not run each time. Fix: `onSent` and `onRecv` return at once when the stream they belong to has been torn down (NULL buffers, slot out of range). To check after reinstalling: `runs` must not grow when the rate or source is changed, and the log must show a "session over" followed by "streaming at ..." without a second "real-time policy set".

Test of the clock source fallback (no word clock available): `gsrctl source wc` -> accepted, session restarted, 3.4 s later "no lock on wc at 96000 Hz: back to the internal clock", streaming again at 96 kHz on the internal clock, app message "no Word Clock signal at 96000 Hz: back to the internal clock" (the audio was interrupted for about 6 s). A real lock on an external word clock could not be tested (no word clock available).

## Rate change "not smooth" (2026-10-26)

Timeline of a rate change made by the user from the app (96 kHz to 48 kHz), daemon (host-time stamps) and plug-in log: request at t0, session over at t0 + 0.05 s, card locked and measured at t0 + 1.6 s, streaming again at t0 + 2.0 s, anchor valid about 0.5 s later; the plug-in only asked CoreAudio to reconfigure at that point (t0 + 2.4 s). So the clients saw about 2.4 s of a stale clock and silence, then a stop/restart of their IO from the configuration change: two disturbances. The daemon had also been restarting after every session (crash fixed, see above), which made it worse before. Change: when a client sets the nominal rate or a format, the plug-in now asks CoreAudio for the configuration change at once and does the waiting inside `PerformDeviceConfigurationChange` (the HAL has stopped the IO by then): it waits up to 8 s for the daemon to publish the new rate with a fresh anchor, then applies it. One reconfiguration per rate change. A rate change decided by the daemon itself (source change, card change) still goes through the monitor thread. Offline harness still passes (48 kHz accepted, 12345 refused, plug-in follows). The remaining time (about 2 s) is the daemon's: stop, set the clock and wait for the lock (about 1 s), measure the card for 0.6 s, build and start. To check on the real chain after reinstalling the plug-in: one "rate change to ..." line per change in the plug-in log, and the reaction of Logic.

## Updater, installer, GitHub (2026-10-26)

- Public repository `FLORIANSV35/GSR24M-driver` (decided by the user: public, name, architecture and measurement notes included). Never published: the manufacturer's installers/firmware/manual (`AH DOWNLOAD/`, the PDF), decompiled vendor code (`re/*.decompiled.c`), the ASFW fork (`ASFireWire/`), recordings, binaries (see `.gitignore`).
- Version: file `VERSION` (0.2.0), read by `GSRCore/make_app.sh` and `build_release.sh`.
- Updater (app): `UpdateChecker` asks `GET /repos/FLORIANSV35/GSR24M-driver/releases/latest` at launch (once a day) and from Info → "Check for updates"; drafts and pre-releases are ignored; if the tag is newer the top strip shows a button that downloads the `.pkg`, checks its SHA-256 against the `.pkg.sha256` asset, then opens it (Installer asks for the administrator password). The version comparison, the release JSON parsing and the checksum file parsing are unit tested (25 tests in all).
- Installer: `./build_release.sh` builds the daemon, plug-in and app, runs the tests, and writes `dist/GSR24M-<version>.pkg` (+ `.sha256`): payload `/Applications/GSR24M.app`, `/Library/Audio/Plug-Ins/HAL/GSR24M.driver`, `/usr/local/libexec/gsrd`, the LaunchDaemon plist and `/usr/local/libexec/gsr24m-uninstall.sh`; bundles not relocatable; preinstall stops a running gsrd and removes the test installs (devsim, spike); postinstall sets ownership, bootstraps the daemon and restarts coreaudiod. Apple silicon, macOS 13 or later. Not signed with a Developer ID (no certificate): Gatekeeper may need a right click, but the app's updater downloads without the quarantine flag.
- Release process used: draft first, installer tried on the user's Mac, then published. v0.2.0 was deleted before publication (it had the stale output position bug); v0.2.1 is the first public release (pkg + sha256; the download matches its checksum; `/releases/latest` answers with it). The updater will show a banner when a later tag is published.

## "Nothing comes out after a rate change": stale output position (2026-10-26)

After the user changed the rate from the app, the audio output was silent while the card side was healthy (streaming, locked, 0 errors, 0 late frames). The ring header showed `outWritten` = 16,583,536 against `inWritten` = 8,619,600 and not moving: a high value written by the plug-in while the HAL was still on the old time line during the 2 s restart; the new time line starts again near 0 and the plug-in only ever raised `outWritten` (max), so every new frame looked "older than a ring" to the engine (`S + ringFrames > outWritten` false), and since `outWritten` no longer changed the daemon also decided no client was writing, which hid the problem from the late counter. Immediate cure without reinstalling: `gsrd/ringprobe --reset-out` (writes 0 into `outWritten`; the plug-in then writes on the right time line, sound back at once). Fixes: the plug-in now replaces the stored position when the new end is far behind it (a restarted time line) instead of keeping the maximum; the daemon forgets an output position that is more than 4 ring lengths ahead of the input position (logs it); a regression check in the offline harness writes a stale 90,000,000 and expects the real position back (passes). Version 0.2.1.
