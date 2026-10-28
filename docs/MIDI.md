# MIDI of the GS-R24M: design

Status: design and first code, nothing tested on the console yet (the console was not at hand on 2026-10-27). Hardware tests are a phase of their own, listed at the end.

## What the console sends

The console's MIDI controller (firmware V1.2.3) has operating modes, set at power-up by holding PLAY and pressing a SOLO/SEL button (user guide p.35). Modes 1 to 4 send the "default MIDI map" (user guide p.32 to 34 and the A&H map "GS_R24 Default MIDI"). Modes 5 (Reaper), 6 (Pro Tools), 7 (US-2400 emulation) and 9 (Sonar) are "MIDI fixed": A&H only publishes the function of each control (map "GS_R24 DAW Functionality"), not the codes.

The owner's console is set to **mode 3** ("Default MIDI, External tally, press/release = note on/off"), the mode his Bome MIDI Translator Pro project works with; the HUI tick is off on purpose (it was audible in the audio). The app answers Pro Tools' keep-alive itself. The codes that project listens to are the starting point of the input table:

| Control | What the Bome project listens to (channel 1 unless noted) |
| --- | --- |
| tick | `9F 00 7F` (channel 16), the HUI keep-alive trigger: only sent in mode 6, not in mode 3 |
| fader n (1 to 24) | `B0 n pp` (controller n) |
| SEL n | note `n` (0x01 to 0x18), on `90 n 7F`, off `80 n 00` |
| SEL n with Shift | note `0x22 + n` (0x23 to 0x3A) |
| ST1, ST2 | notes 0x21, 0x22 (Bank left, Bank right) |
| buttons 1 to 8 | notes 0x6D to 0x74 |
| keypad up, left, centre, right, down | notes 0x75 to 0x79 |
| transport | MMC `F0 7F 7F 06 cc F7`: cc 05 GTS, 01 STOP, 02 PLAY, 04 GTE, 06 REC |
| jogwheel | `B0 7B pp`: 00 to 3E clockwise, 3F to 7F counter-clockwise |
| jog switch | note 0x43 (the default map says 0x7A; to be checked, 0x43 is also the Shift code of ST1) |
| LEDs | the console lights its LEDs when it receives a note on the same note number (external tally) |

Rules of the Bome project that are **inactive** (`Actv00`) and therefore not reproduced by default: Pan, Mute, RecRdy and Auto per channel, the two MIDI faders, Step left and right, Shuttle.

## What Pro Tools wants: HUI

Pro Tools talks to a control surface called HUI. One HUI device is 8 channels, so 24 channels need three virtual HUI devices (the Bome project uses three virtual ports: channels 1 to 8, 9 to 16, 17 to 24).

- Switch: `B0 0F zone` then `B0 2F (0x40 | port)` for press, `B0 2F port` for release.
- Fader of strip z (0 to 7): `B0 z hi`, `B0 (0x20 + z) lo`. Touch is port 0 of the strip's zone.
- Jog: `B0 0D v`.
- Keep-alive: Pro Tools sends `90 00 00`, the surface answers `90 00 7F`.
- From the host to the surface (LEDs): `B0 0C zone`, `B0 2C (0x40 | port)`.

Zones and ports **verified** by the Bome project (it works with Pro Tools): strips 0 to 7 with ports 0 touch, 1 select, 2 mute, 3 solo, 4 auto, 7 rec/rdy (5 and 6, v-select and insert, are from the HUI documentation as remembered, not verified); zone 0x09 port 0 Mix window, port 1 Edit window; zone 0x0A port 1 and 3 bank left and right; zone 0x0D ports 0 down, 1 left, 2 mode, 3 right, 4 up, 5 scrub, 6 shuttle; zone 0x0E ports 1 and 2 jog steps, 3 stop, 4 play, 5 record; zone 0x0F ports 0 and 1 return to zero and to end; zone 0x14 port 0 enter.

## What the Bome project does besides renaming

- **Touch**: the console sends no touch message. A fader move sends touch-on, the value, and a timer of 600 ms after the last move sends touch-off.
- **Two SEL layers**: the plain SEL switches send HUI "select" and the shifted ones HUI "solo" by default. Buttons 1 to 4 change what the layers send: SOLO, MUTE, REC (what the shifted layer does), and SEL (swap the two layers). The console's LEDs follow (notes 0x6D to 0x70).
- **Jog**: in step mode the wheel sends HUI jog-left (zone 0E port 1) or jog-right (port 2) pulses; in scrub mode it sends the HUI jog value. The jog switch toggles between the two and drives the LED (notes 0x21 and 0x43).
- **Bank left and right** refuse to overlap.
- **Keystrokes**: button 5 sends Shift+F to the computer, and one more button runs a keystroke sequence. Not MIDI; needs the Accessibility permission on macOS.
- **Return path** (HUI to console, `HUI 2 GS`): HUI faders to the motorised faders (`B0 n value`), HUI select LEDs to the SEL LEDs, transport LEDs, zoom-mode LED.
- **DISPLAY** (third preset): HUI small displays (track names, 4 characters), meters and mode LEDs are sent to four serial devices (aliases AR1 to AR4, 115200 baud, 8N1), as `10 zone c1 c2 c3 c4 F7` for names, `11 zone level F7` for meters (three brightness levels) and `11 zone state F7` for modes.

## Architecture

```
console -- card -- FireWire -- gsrd (MIDI slot of stream 0, 3 ports, 31.25 kbaud pacing)
                                  | XPC (midiSubscribe, midiSend)
                       user agent (LaunchAgent, one per login)
                         |- CoreMIDI virtual ports  "GS-R24M MIDI 1/2/3"            Legacy mode: bytes go through unchanged
                         |- CoreMIDI virtual ports  "GS-R24M HUI 1/2/3"             Pro Tools mode: translation engine
                         |- serial ports                                           DISPLAY
                       app (SwiftUI): mode, surface drawing, bindings, learn, status
```

The daemon runs in the system domain, so CoreMIDI ports it created would not be visible to the user's applications; that is why the ports live in a per-user agent.

Modes:
- **Legacy**: the three MIDI ports of the card as CoreMIDI sources and destinations, unchanged. Whatever mode the console is in.
- **Pro Tools**: translation to three HUI devices, with what each control does chosen in the app.

## More Pro Tools functions

The Bome project only covers the functions the owner had entered. The catalog (`HUICatalog`) now also holds entries that follow the HUI layout but were not tried (channel left and right, the Transport, Memory locations and Status windows), shown as "(to verify)". The complete table of the HUI could not be found online (the HUI specification is not public; the documents that contain it were not reachable), so no code is guessed beyond that.

Three ways to get the rest, all in the MIDI tab:
- **Test in Pro Tools**: every HUI action has a button that presses and releases the switch in Pro Tools at once (through the agent's `huiSend`); no console needed. Checked end to end: the agent puts the expected bytes on the virtual port "GS-R24M HUI 1".
- **Explore HUI**: a grid of every zone (0x00 to 0x1F) and port (0 to 7). A click presses that switch in Pro Tools; what is found can be named and then appears in the choice menus (stored in `midi.json`, `userSwitches`). It needs Pro Tools running with the HUI peripherals set to GS-R24M HUI 1 to 3, which also makes the ping answer work.
- **Pro Tools keyboard shortcuts** for the keyboard action: Undo, Redo, Save, Cut, Copy, Paste, Select all, Delete, the edit modes F1 to F4, the tools F5 to F7, toggle Mix and Edit windows, play or stop. These are the default key map of Pro Tools; they work whatever the HUI does, and need the Accessibility permission.

## Bindings (what the owner asked to choose)

Every control of the surface, with its Shift variant, has a binding. A binding is an action:
- a HUI switch (zone and port), held while the control is held, or pulsed;
- a channel function for the SEL switches (select, mute, solo, rec/rdy, auto, v-select, insert), per layer;
- setting or swapping the SEL layers, toggling the jog mode;
- a keyboard shortcut;
- nothing.

The default bindings reproduce the active rules of the Bome project. The app draws the surface (drawn from the user guide p.31: 24 channel strips with SEL switches, ST1, ST2, the master fader, 12 rotary controls and 2 MIDI faders, transport row, Shift, 8 numbered buttons, keypad, jogwheel), a click selects a control, a menu changes its action. "Learn": press a control on the console and the app finds which control it is (or records the message when the code of a control is not known), which settles the uncertainty on the codes of mode 6.

## State of the work

Done, all tested without the console (87 unit tests, plus the checks listed here):
1. gsrd: MIDI on the wire, `gsrd/gsr_midi.c`, client `gsrd/gsrmidi`. The new daemon is installed on the owner's Mac (installed 2026-10-27); it has not seen the card since (the console was off).
2. GSRCore, `Sources/GSRCore/MIDI/`: message parser, HUI encoders, console map, bindings, translation engine, `MIDIHost` (routing, settings file), surface layout, learn. The engine is checked against 200 console to HUI and 80 HUI to console vectors taken from the Bome project (`midi/bmtp_vectors.py` writes them to `GSRCore/Tests/GSRCoreTests/Fixtures/bome-vectors.json`; the project file itself stays out of the repository).
3. User agent `GSRMidiAgent` (`Sources/GSRCore/MIDI/Platform/`): XPC client of gsrd with automatic resubscription, 12 virtual CoreMIDI ports (checked in both directions with a second MIDI client), keystrokes, and a Mach service `com.gsr24m.midiagent` for the app (status, traffic, reload). Run as a LaunchAgent: tested from `GSRCore/install-agent.sh`; the agent answered the status request over XPC and reported the daemon subscription. A bytes sent to a virtual port reached the daemon.
4. App, MIDI tab: mode switch, drawing of the surface from the user guide (24 strips, ST1, ST2, 12 rotaries, 2 MIDI faders, transport, Shift, 8 buttons, keypad, jogwheel), inspector with the codes of the control, the action editor (HUI switch from a catalog or zone and port, press and release at once, channel function, SEL layers, jog toggle, keystroke), Learn, traffic monitor, defaults. Settings are saved to `~/Library/Application Support/GSR24M/midi.json`, which the agent reloads.
5. Installer: the agent and its LaunchAgent plist are in the package (`build_release.sh`, postinstall, preinstall, uninstall). Not built into a release.

Not done:
- DISPLAY (the Bome project's third preset, HUI displays and meters to four serial devices). Left out on purpose: the owner says the display hardware is outdated and the function has to be designed again. Nothing of it is in the code.
- The shifted codes of buttons 1 to 8 and of the keypad: in mode 3 Shift is a separate note (0x6C) and does not change the codes of the SEL switches, so the engine uses a software Shift (note 0x6C held) for every layer.
- Persisting the keystroke of the Bome rule "New Take" (ST2 with Shift).

Differences from the Bome project, on purpose: the touch-on message is sent once per touch instead of at every fader move; the release of a shifted SEL switch (solo) always matches its press (the Bome project releases a variable that is never set on Solo 1); the keep-alive is also answered when Pro Tools asks for it, not only when the console's tick arrives.

Gotchas found while building the agent: a Swift program must keep the XPC listener in a property (Swift releases it otherwise and the Mach service closes at once); CoreMIDI needs the main run loop (`RunLoop.main.run()`, not `dispatchMain()`); a LaunchAgent's Mach service is visible in the user's graphical session.

## Test phase with the console (to do later)

- Start the agent (`GSRCore/install-agent.sh`, no sudo; the installer does it for every user). Run `gsrmidi listen` (daemon already installed) and press every control: check the port numbering (DBC modulo 8, port 0 for the console), the codes of mode 3 in the table above, the jog switch code, the shifted buttons.
- `gsrmidi send 0 90 6D 7F`: the LED of button 1 lights; check the 31.25 kbaud pacing with a burst of LED messages and motorised fader moves.
- Pro Tools: the three HUI devices are detected (Setup, Peripherals), faders and transport work, the touch timer behaves, the return path moves the motorised faders and lights the LEDs.
- DISPLAY on the serial devices.
- App, MIDI tab: Learn on every control, the SEL layers and the mode buttons with the LEDs, rebinding a control and seeing it act in Pro Tools, the traffic monitor, "Allow keyboard shortcuts" and the Shift+F keystroke.
- Legacy mode: the three virtual ports with a MIDI monitor application, in both directions; the console's messages in the different console modes.

## Observed on the console

- Mode 3, checked on the console (2026-10-27, port 0, channel 1): SEL n = note n, ST1 = 0x21, ST2 = 0x22, buttons 1 to 8 = 0x6D to 0x74, keypad 0x75 up, 0x76 left, 0x77 centre, 0x78 right, 0x79 down, transport = MMC (stop 01, play 02, GTE 04, GTS 05, rec 06), fader n = controller n, rotary n = controller 0x3F+n, MIDI fader 1 = controller 0x4C, jogwheel = controller 0x7B (1 clockwise, 127 counter-clockwise). Each switch sends note on at the press and note off at the release. Shift is the note 0x6C, held while pressed, and changes no other code (SEL, ST, buttons, keypad, transport are identical with Shift): the bridge keeps the Shift state itself. No tick. The jogwheel push sends nothing, with or without Shift.
- A test with the console set to a mode that the owner took for mode 6 showed a console speaking native HUI (heartbeat `90 00 7F` every 0.57 s on the three ports, switches as HUI zone/port pairs, Shift as `9F 6C`, fader touch around every move, rotary as `B0 40+n` relative, MIDI fader 1 as `BF 4C`). That does not match the manual's mode 6 (default map plus tick `9F 00 7F`); it looks like mode 7 (US-2400 emulation). It is not used: the bridge targets mode 3.

- SEL switches and ADD mode (found with Pro Tools, 2026-10-27): with the console's ADD MODE off, pressing a SEL switch makes the console send the previously pressed SEL switch again in the same millisecond (or the same note twice). Pro Tools reads two presses on a track as a double click and asks to rename it, and an overlap selects two tracks. With ADD MODE on the console stops doing it. The bridge also drops such an echo (a SEL repeated within 8 ms of a press, when it is the previous one or the same one), and a SEL pressed less than 0.35 s after the previous one, which is still held, replaces the selection instead of adding to it (`multiSelectHoldSeconds`, `overlapSelects` in the settings).
- The ST1 LED is lit at start on purpose: the Bome project uses it, with the jog LED (note 0x43), to show that the jogwheel steps (Shift+ST1 toggles scrub).

## Console mode 6: tried, dropped (2026-10-27)

The console works in mode 6 as a native HUI device (three ports, Shift+SEL = solo, ST1/ST2 = bank, SEL and transport lights taken from Pro Tools directly; with the agent in Legacy mode and Pro Tools on "GS-R24M MIDI 1 to 3" everything worked, lights included). A Pro Tools mode on top of it was written (HUI switches recognised and handed to the mode 3 engine, fader touch rebuilt) and then removed: the owner found it too complex for remapping, and the numbered buttons send frames that depend on the current track. What was learned:
- the console puts a touch press and release around every fader position, which made Pro Tools drop the touch every second (automation jumped back): a pass-through needs one press at the first move and one release 0.8 s after the last;
- passing everything from Pro Tools to the console crashed the console: at its connection Pro Tools sends the state of every light and every display of the three HUI devices, again and again (about 500 KB per port). A bridge must send the console only what it can use, and each light once per change.
Codes seen in mode 6, for reference (HUI zone/port): SEL n = strip zone, port 1 (Shift: port 3); ST1 0A/1, ST2 0A/3, Shift+ST1 09/1, Shift+ST2 09/0; PLAY 0E/4, STOP 0E/3, REC 0E/5, GTS 0F/0, GTE 0F/1; jog right 0E/2, left 0E/1; keypad up 0D/4, left 0D/1, centre 0D/2, right 0D/3, down 0D/0; button 8 (Enter) 14/0, buttons 4 to 7 on zone 18, ports 2, 5, 1, 4.

## Transport lights in console mode 3: not solved

The A&H map table says mode 3 has its transport lights on MIDI return tally ("MMC LEDS: Midi"), but nothing seen on the console lights PLAY, STOP or REC: `B1 77/78/79` (what the Bome project sends), `B0 77/78/79`, notes 0x67 to 0x6B with transport in MMC or in note mode (SEL 17), MMC commands 01 to 0D, the MMC and notes the console itself sends, sent back one by one, Pro Tools as MMC master sending STOP, and a sweep of the notes of channel 1. The sweep of the controllers and of channel 2 was not finished. The lights do work by themselves when the buttons are pressed. Open idea: read the console MIDI firmware (`GSR_V1.2.3.gsu`, TTComp-compressed STM32 image) for study; never write it to the card.

## SEL banks (as the owner calls them)

**SEL BANK 1** is the plain SEL (select by default); **SEL BANK 2** is **CUSTOM** (what Shift+SEL does). Buttons 1, 2 and 3 choose what BANK 2 does: solo, mute, record ready. Button 4, **SEL REV**, swaps the two banks like a locked Shift: Shift+SEL selects and the plain SEL does the choice of buttons 1 to 3; after the swap, buttons 1 to 3 change what the plain SEL does. The LEDs of the active choice and of button 4 stay lit. The console has two banks of SEL lights and shows the second one by itself while Shift is held: the plain bank is written with the notes 0x01 to 0x18 (the plain layer's function), the shifted bank with the notes 0x23 to 0x3A (the shifted layer's function). Writing everything in the plain bank and switching the lights by software on Shift made the selection vanish while Shift was held.

## Console through a MIDI interface (0.4.1)

The MIDI tab can reach the console through a MIDI interface of the Mac wired to the console's MIDI IN and OUT sockets, instead of the card's MIDI ports (`externalRoute` in `midi.json`, menu "FireWire card / MIDI interface" with an input and an output). The console's modes apply to the physical port too (release notes V1.2.3). One socket pair means one port: the card port of the console (`consolePort`) is the only one sent; the other virtual ports get nothing from the interface. The mode (power up holding PLAY, then SEL 3, then STOP) and the MIDI channel (power up holding REC, then SEL n, then STOP) are kept in the console's EEPROM; the tab shows both. The System tab and the MIDI tab have restart buttons for the MIDI agent, gsrd and the audio driver.
