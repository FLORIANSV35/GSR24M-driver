# Features: same as the A&H Control Panel, plus diagnostics

Reference: `re/NOTES.md` (Control Panel guide, 4.3.1 release notes, panel strings). Status values: done, planned, not planned.

## 1. Functions of the original panel

| Original function | Ours | Status |
| --- | --- | --- |
| Device list with clock icon on the master and padlock for lock state | Device list, clock and lock icons | planned (needs live device) |
| Clock master selection (when a ZED-R16 is chained) | Same | planned |
| Sample rate selection | Same, restricted to rates the device advertises | planned |
| Sync source selection (internal, Word Clock, ADAT, AES) | Same, names read from the device | planned |
| Hide the rate or sync selector when there is only one choice | Same | planned |
| Operation mode (Low Latency, Normal, Safe 1, Safe 2) | Same, maps to ring depth | planned |
| Buffer size (Windows only in the original) | Not needed on macOS | not planned |
| Measured sampling rate and device status | Same | planned |
| Device nickname | Read-only (project rule) | planned, read-only |
| Parameter locking while audio clients are active | Same | planned |
| Event log, last 40 events, shift-click to open | Event log window (see 2) | planned |
| Show details: firmware version | Read-only display of the DICE version | done for report files |
| Firmware loader | Not provided: we never write firmware | not planned (rule) |
| OHCI controller checker with support verdict | Controller info from the I/O registry (see 2) | planned |
| WDM channel mapper, DPC latency checker | Windows only | not planned |
| Customisable panel (`cpl.defs`) | Our own show/hide of sections and channels | done in the first app |

## 2. Diagnostic tools (new)

1. Live register viewer: GLOBAL, TX, RX, EXT_SYNC with decoded fields, refreshed on demand, copy as text.
2. Report export: the dicedump text format, ready to attach to an ASFW issue (identity, Vendor_ID, Model_ID, streams, host, macOS, controller).
3. Config ROM viewer: raw quadlets and parsed root directory (vendor, model, unit spec, version).
4. Bus view: nodes, speeds, root and cycle master, IRM, bandwidth and channels in use, bus reset counter and timestamps.
5. Controller info: OHCI vendor and revision behind the Thunderbolt to FireWire adapter, adapter chain as seen by the system.
6. Clock timeline: lock, unlock, slip and rate changes over time, with the device's state (disabled, locking, locked, flaky, illegal rate).
7. Stream health counters: packets received, dropped, DBC discontinuities, CIP header errors, SYT jitter and sample-rate estimate, underruns on playback, ring fill level.
8. Level meters per channel and signal-present indicator, with the same channel names as the console.
9. Loopback and tone test: send a test tone to chosen outputs, check it arrives on chosen inputs, report delay and any dropouts.
10. Long-run recorder: log counters every second for hours, stop on first error, save a summary.
11. Bus reset and cable-pull test: expected recovery, time to resume audio.
12. Self-check before use: card found, DICE identity rule satisfied, owner taken, lock achieved, streams enabled; a plain-language result for each step.

## 3. What can be built without the card

- Items 1 (from a file), 2, 3 (from a dump), 8 (synthetic levels) and the UI of 6 and 7 can be built and shown against recorded data.
- Items 4, 5, 9, 10, 11 and the live parts of the others need the card.

## 4. Order

First app (done): loads a report, shows identity, clock, channels, choice of sections and channels.
Next: report export, event log window, self-check screen, register viewer from a file. Then live versions once `gsrd` exists.
