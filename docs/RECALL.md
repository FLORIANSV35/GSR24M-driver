# Console recall by measurement (design, not built yet)

Goal: the GS-R24M is an analogue console. Its EQ knobs, aux sends, group faders and master fader have no memory and no motor. This tool
**captures** their effect after a mix and helps the operator **recall** them before the next one, by measuring the console through the
FireWire card and comparing with the stored capture. Everything below comes from the console user guide (AP7784: block diagram p.10,
mono channel p.11-15, aux p.22, groups p.23, master p.26, 17-24 switch p.28, MIDI p.30-34, routing options p.37-39) and from what was measured on the card.

## What the console lets us reach through the card

| Card channel | Send (console to Mac) | Return (Mac to console) |
| --- | --- | --- |
| 1-24 | mono channel send. Switch **A** up: right after pre-amp and 100 Hz filter. Switch **A** pressed: after the EQ (after the EQ IN switch). Never affected by the fader. | Switch **B** pressed: replaces the pre-amp signal at the point just before the insert (the analogue input is disconnected). Switch **C** pressed: replaces the signal after the EQ (feeds the fader and the pre-fade sends). |
| 17-24 with the recessed switch "17-24 = AUX+GRP" pressed | **17-20 = Aux 1-4 buses, 21-24 = Groups 1-4** (instead of channels 17-24) | unchanged |
| 31-32 | main L/R mix (the "2 Track 1" output) | "DIG MASTER" input of the monitor section only (it does not enter the mix) |

Consequences:
- **EQ**: with **A and B pressed on a channel** (routing option 8 of the guide, "feedback loop possible": harmless here because the app only plays generated noise, it never plays back what it receives), the Mac noise goes: card return N, pre-insert, EQ, card send N. The ratio send/return is the EQ curve of that channel, alone, whatever the fader, aux, pan or mute. The 24 channels do not interact (each has its own return and send), so they can be measured **at the same time**.
- **Aux sends, group faders, master**: with **B only**, a test tone enters channel N and spreads on the buses according to the channel's controls (send knobs, fader for post-fade sends, pan, routing switches, mute). The aux bus levels are on card 17-20, the groups on 21-24 and the main mix on 31-32 (the recessed switch must be pressed). One channel at a time, so the origin of the level is known: a **24 x 10 matrix of gains** (rows: channels, columns: Aux 1-4, Group 1-4, Main L, Main R).
- **Not reachable**: Aux 5-6 (not on the interface), Studio outputs, stereo and valve channels (could be added: they have their own returns), the 100 Hz filter (it sits before the return point), pre-amp gain, pan law details.
- **Channel faders** (GS-R24M only) are motorised and have MIDI: with MIDI READ on, the console moves a fader to the position sent over MIDI (p.30); with WRITE on it sends the position when a fader is touched. So channel fader recall can be exact and does not need audio measurement; the group and master faders are not motorised. This needs the MIDI path (3 MIDI ports in the 17th slot of stream 0), not built yet.

## What the measurement says, and what it cannot say

The matrix gives the **effective gain of each path**. Two controls on the same path cannot be separated by one measurement (aux 1 level of channel 5 = send knob x Aux 1 master x EQ gain at 1 kHz x, for post-fade, the fader). So recall works on **deviations against the capture** and the tool tells the operator where to look:
1. Common offset on a column over many channels = the **master/group fader** of that column (median of the deviations, ignoring channels that are off by themselves).
2. Remaining deviation of one channel on that column = its **send knob** (or its fader if the send is post-fade, or its routing).
3. EQ deviation per band: the curve is compared with the stored curve (no model needed): the deviation is split into bands (LF, LMF, HMF, HF, around the knob ranges of the guide) and each band's knob is named. A parametric fit can be added later.
The operator moves the knob while the tool plays the test signal in a loop and shows the live deviation in dB, with a tolerance (green within 0.2 dB). This is a closed loop, not a one-shot restore.

## Test signals and analysis

- **EQ**: pink noise (about 5 s, different seed per channel), 48 or 96 kHz, averaged cross-spectrum (Welch, Hann, 16k points): H(f) = Pxy / Pxx, shown from 20 Hz to 20 kHz in 1/12 octave. Stored with the coherence so a bad measurement (noise, insert left connected, clipping) is rejected. The send/return gain through the card is constant and cancels in the comparison (the card is only the measuring path).
- **Levels**: 1 kHz sine, synchronous detection over a whole number of cycles (as the 0.5 s blocks already used in `gsrloop`), one channel at a time, 2 s each plus settling. Earlier measurements on this chain repeated within 0.01 dB.
- **Level of the test signals**: low (about -30 dBFS) with 0.5 s fades in and out, and **never started without the checklist being confirmed**.
- **Protection**: the capture refuses to start if a send that must be silent is not (noise floor check before playing) and stops at once if a level above the expected range comes back (feedback or clipping).

## Checklist shown before any sound (from the user, completed from the guide)

- Unplug the **inserts** (channels, groups, main, mono).
- Switch off the **monitors and the headphones** (the owner's decision: this is the only audio warning the tool shows). Reminder for the record: the noise and the tone also reach every other bus the channel feeds (main L/R, aux, group and studio outputs); anything connected there will hear them.
- **A and B pressed** on all channels for the EQ pass; **B only** for the aux/group/master pass. Switch **C**, **D** and the 17-24 recessed switch as required (17-24 pressed for the buses).
- Unmute the channels to measure (the aux sends are muted with the channel by default) or let the tool report them as muted.
- Channel faders: for a repeatable capture, either put them at unity or recall them first by MIDI.

## Data kept per capture

JSON in `~/Library/Application Support/GSR24M/recalls/<date name>.json`: sample rate, checklist answers, for each channel the EQ curve (frequency, dB, coherence), the 24 x 10 matrix (dB), the noise floor, the app and card versions, and free text. Several captures can be kept and compared.

## Workflow

1. **After the mix**: checklist, one click "Capture": EQ pass (about 10 s for all channels at once), then the matrix (24 channels x 2 s, about a minute), then a summary and a save.
2. **Before the next mix**: checklist, "Recall": the tool measures the same things, shows the table of deviations (channels, aux, groups, master) and the EQ curves (stored against live), and guides one control at a time with the live reading.

## Where it fits in the code

- A measurement module in the app (or a small separate tool first) that plays and records through the CoreAudio device "GS-R24M FireWire": magnitudes do not depend on latency, so the normal audio path is good enough, and it needs no change in `gsrd`. The app must warn when another application is using the device.
- Pure analysis code in `GSRCore` (spectral estimation, tone detection, deviation logic, capture file), with unit tests on synthetic signals (known filters).
- First experiment before building the interface: one channel in A+B, pink noise, plot of the measured curve against the knob positions written down by hand, to check repeatability (target: the same curve within 0.2 dB on two runs) and the real tolerance.

## Open questions for the owner

Decided by the owner: only "monitors and headphones off" in the checklist; tolerance **0.2 dB** (levels and EQ curves).
Still open: channel faders by MIDI (needs the MIDI path); what to do with mutes, routing switches and pans (note, measure or ignore); whether Aux 5-6, studio outputs, stereo and valve channels are in scope.

## Measured on the console EQ (channel 1, GS-R24M)

- Reference "EQ IN up" against "EQ IN pressed, all gains at 1": flat within ±0.6 dB (about +0.5 dB tilt above 5 kHz). So the EQ IN up measurement is a valid flat reference.
- Gain knobs stop a little beyond the printed ±15: +16.7 dB (LF), +16.3 dB (HF), +16.0 dB (LM bell). Shelf corners as in the guide: LF 62 Hz, HF 12.8 kHz.
- The bells are **not** a fixed-Q second-order section. LM bell, F knob at 120, Q knob fully left, modelled as one bell: +16.4 dB gives centre 111 Hz and Q 0.74; +11.7 dB gives 177 Hz and Q 0.60; +7.5 dB gives 176 Hz and Q 0.41; -9.2 dB gives 178 Hz and Q 0.20. Q knob at middle and right stop at +16 dB gave Q 1.12 and 4.75 (the middle reads like the left stop: the first half of the knob changes little). Width and apparent centre depend on gain and direction.
- A least-squares fit of the four sections to a curve with several broad overlapping bands is not unique: solutions with a different HF/LF/mid split fit within 0.4 to 0.7 dB. Adding the phase (the ratio LIVE / REF of the complex transfer functions, integer-sample delay removed, `recall/phasefit.py`) changed the fitted values very little: the phase is nearly redundant with the magnitude for these minimum-phase sections.
- Consequence for the app: the comparison of curves and the per-band deviation are exact and need no model. The knob positions are only an estimate (about ±2 dB on gains, ±50 % on frequencies when bands overlap), so each section of the strip shows how far to turn it, computed from the deviation of the curves in its band.
- Do not measure from the command line while the app is measuring the same channel: both play the same noise and the level doubles (+6 dB).
- Following the knob that is turned (`EQGuide`, `KnobTracker`): fitting all eight knobs to one curve is ambiguous, but one knob moving at a time is not. For each knob the change of the live curve is projected on that knob's sensitivity pattern (from the four-section model around the fitted settings): a matched filter, so it gathers evidence from the whole curve. A knob is named when its signal is at least 5.5 standard deviations above the noise (assumed 0.2 dB rms on a curve difference) and explains at least 70 % of the change once the noise is taken out. Delays of 0.7, 1.5 and 3 s are compared, so a slow turn counts too; a knob has to win twice in a row and stays lit 2.5 s. First version (change of 0.3 dB rms against the curve 0.7 s earlier) named the right knob in 26 of 72 simulated turns (slow turns, HF, Q and F were missed); the matched filter names it in 72 of 72, with no wrong knob and no false alarm over 1080 still steps, also at twice the assumed noise (`GSR_SIM=1 swift test` runs the comparison and a noise sweep). Latency 0.5 to 1 s for a fast turn, up to 3.6 s for a very slow Q turn. On real pairs where one knob moved (LM gain up, down, to a cut, from flat; LM F 120 to 300 and back) the right knob explains 71 to 97 %, the next 18 to 53 %; with several knobs changed at once nothing is named. The real measurement noise on a still console is much lower than the simulated one (sliding one-period windows of a recording agree to 0.1 dB). The knob lights up on the strip and shows how far it still has to go to reach the target (clockwise or counter-clockwise, or in place), the distance coming from the same projection of the gap to the target. Phase added to the projection changed the numbers by less than 0.01.

## Getting a recall done: what was tried (simulation, console modelled with the measured gain-dependent Q, the app's model deliberately wrong)

- Reading the eight knobs from a curve is ambiguous (several settings fit within 0.4 to 0.7 dB), so the displayed target positions are a starting point, off by about 2 dB and 40 % in frequency and Q.
- From a random start, turning one knob at a time (best knob by its own projection, each set to its best point) does not converge: 17 % reach a 0.2 dB gap in 40 moves, no better than a random choice. Solving all eight knobs at once and applying the result with 30 % error on every knob does not either (15 % to 50 % in 15 rounds, even with exact sensitivities): the knobs are coupled and the error is amplified.
- From the displayed target positions set by eye, then refined with the live curve as feedback, it works: 85 to 93 % of the cases reach a 0.2 dB gap, median 8 to 14 moves (90th percentile 18 to 30). Choosing the knob to touch from the joint solution (`EQGuide.guidance`) beats choosing it knob by knob (8 against 10 moves with a 2x smaller fit error, 14 against 20 with the full one).
- So the workflow in the app: set the knobs to the white marks, then follow the dashed knob (the one with the largest part of the remaining gap), which turns into the lit knob with "turn right/left" and "in place" as soon as it is touched. The better the displayed positions, the fewer the moves: fit error halved gives 93 % in 8 moves.
- Ideas not built: reading the knob angles from a photo of the strip (would give the starting point without the ambiguity of the fit); estimating the live positions by adding up the identified moves from a flat start.

## What the strip shows (2026-10-27)

The knob positions are estimates (off by about 2 dB and 40 % in frequency and Q), so the strip shows no value. Every knob has three arrows on each side: the arrows towards the side to turn light up green, one for a small move, three for a long way (from the distance the knob still has to go: up to 1 tolerance in place, up to 3 tolerances one arrow, up to 8 two arrows, more three; the tolerances are those of `EQGuide.tolerance`: 0.3 dB for a gain, 5 % for a frequency, 0.12 for a Q). A green circle around the knob means it is in place. The distances come from the joint solution of the eight knobs (`EQGuide.guidance`, all knobs at once), and for the knob being turned from the closer projection `EQGuide.remaining`. A white ring marks the knob being turned and a dashed ring the one worth touching next. A section shows a green check when its band agrees with the stored curve within 0.2 dB.

## Reaching 90 % with the console's own limits (simulation, 2026-10-27)

The EQ model of `EQFit` carries the limits of the console: gains up to the stops (about +-16.7 dB), LF and HF shelves with a fixed corner (60 Hz, 12 kHz) and a gain only, LM bell 18 Hz to 1 kHz, HM bell 400 Hz to 18 kHz, Q 0.4 to 6.5 as the model reads it. Everything below stays inside those limits (the fit is clamped, the simulated knobs too).

`RecallConvergence.swift` (gated: `GSR_SIM=1 GSR_TRIALS=60 swift test --filter recallConvergence`, `... --filter fitQuality`) simulates the whole recall: random settings the console can have give the target curve (noise 0.08 dB); the operator sets the knobs where the app shows the target (error of setting by eye: 0.4 dB, 8 % in frequency, 15 % in Q), then follows the advice one knob at a time (each move 25 % off); the console is the model plus a smooth error of 0 or 0.3 dB. Goal: the accuracy of `EQMeasure.accuracy` (tolerance 0.2 dB, half mean score and half worst point) at 90 %.

What changed the result:
- the guidance stopped at "nothing worth touching" (best knob under 0.15 dB rms) with a point still 0.6 to 1.2 dB off, which is below 90 %: the threshold is now 0.03 dB. From 1 case of 10 to 55-57 of 60 reaching 90 %, median 4 to 5 moves;
- the global fit of a curve was left in a look-alike minimum in about 8 % of the cases (a bell near 25 Hz against the LF shelf, a bell near 15 kHz against the HF shelf). It now screens a grid of bell frequencies and Q (gains by linear least squares), keeps the best candidate of each pair of frequencies, refines them with Levenberg-Marquardt and finishes the best three with the simplex: residual above 0.2 dB in 7 of 150 fits instead of 12 (90th percentile 0.087 dB, the noise level). The fit takes about twice as long.

Remaining failures (about 5 to 8 %): the two bells close together in frequency (LM near its top, HM near its bottom, 370 to 600 Hz) and in opposite directions, where the two knobs act almost alike and the advice goes round; and fits that still miss a bell at the end of its sweep (residual above 0.3 dB). Not tried on the real console yet.

### Order of the knobs (simulation, 2026-10-27)

`GSR_SIM=1 GSR_ORACLE=1 GSR_TRIALS=60 swift test --filter knobOrder` compares orders on identical targets and starting knobs (model error 0 and 0.3 dB; knobs known exactly so that only the order differs):

| Advice | reach 90 % (of 60) | median moves |
| --- | --- | --- |
| the knob that explains most of the gap (before) | 55 to 56 | 4 |
| greedy inside the sections, taken from the top: HF, HM, LM, LF | 55 to 56 | 4 to 5 |
| greedy inside stages: gains, then frequencies, then Q | 54 to 55 | 5 to 6 |
| one knob at a time in a fixed order, top to bottom | 53 to 54 | 7 to 9 |
| one knob at a time: gains, frequencies, Q (or frequencies, gains, Q) | 51 to 53 | 9 to 10 |
| one knob at a time: Q, frequencies, gains | 52 to 55 | 7 to 8 |

A fixed order of the knobs alone does not raise the success and takes twice as many moves: the knobs of a bell are not independent (the gain that is right depends on the frequency and the Q), so a knob set to its best value alone has to be set again after the next. Advising section by section from the top costs nothing, and gives a predictable order: the strip shows the arrows of the first section that is not in place, the sections under it wait, the dashed ring is the knob of that section that explains most of the gap.

### First pass, then refinement, Q last (simulation, 2026-10-27; this is what the application does)

The runs above start with the knobs near the displayed target, which is not the usual case: the channel has whatever settings the last session left. From knobs left anywhere (`GSR_FAR=1`), the knob that explains most of the gap reaches 90 % within 40 moves in 21 cases out of 60, in a median of 17 moves; one pass over the knobs in a fixed order, each by its own projection of the gap, does worse (15 of 60). What works is a **first pass towards the fitted target**: each knob, one after the other, in the order gains, frequencies, Q, is turned towards the position the fit of the stored curve gives for it, until the curves agree to 65 %; then the refinement of the joint advice, the Q knobs last. Result: **48 to 50 cases out of 60** (model error 0.3 dB and 0). The Q is last because the Q of a bell, as the console behaves, depends on its gain and frequency.

`RecallAdvisor` (GSRCore, tested) holds the rules: first pass in `passOrder` (HF, HM gain, LM gain, LF, HM frequency, LM frequency, HM Q, LM Q), a knob counts as placed within 3 tolerances, the pass ends at 65 % or when the list is done; refinement: the open knobs that are not a Q first (the one explaining most of the gap is the dashed ring), the Q knobs only when nothing else is out of place, and back to the gains if one drifts; a knob turned and let go that still looks out of place is set aside 25 s, and so is an advice that brings its knob no closer in 20 s. The strip shows the arrows of the knob of the moment during the first pass, of every open knob except the Q during the refinement.

## Settings noted on the screen while capturing (2026-10-27)

Under the curve (the score and the buttons of capture and measure are on its left) the Recall tab draws the channel strip as on the console, block after block: INPUT (gain, LINE, +48V, POL, HPF), EQ (HF, HM, LM, LF with their G, F and Q knobs, EQ IN), AUX (aux 1 to 6 and the Pre switch of aux 3 and 4), PAN / BUS (pan, L-R, M, 1-2, 3-4), INTERFACE (switches A to D, MUTE) and LEVEL (the fader), from the user guide p.10 to 15. The knobs are turned with the mouse (drag in a circle round the knob), the switches go on, off, not noted by a click, the fader is dragged, a double click clears a control. Everything is kept with the capture (`manual` for the EQ knobs, `strips` for the rest; older captures still load; the target's file is written a moment after the last change).

- The EQ knobs carry the **estimate of the app** (the fit of the captured curve with the flat reference) as a small cyan marker and as grey figures until they are turned; "Use the estimate" accepts it rounded to what a knob can be read to (0.5 dB, two significant digits for a frequency, 0.1 for a Q). What is set wins over the fit and becomes the **target of the first pass** of the recall; the app says how closely the values reproduce the captured curve (a way to catch a mistake). The Q is the one printed on the knob and is turned into the Q the model reads with the gain of the bell (`EQFit.effectiveQ`).
- The same EQ knobs carry the arrows of the recall (three on each side, green circle when in place), so the strip is both where the capture is noted and where the recall is followed.
- The other controls have no effect that the EQ measurement can see, so the app cannot check them: they are the list of what to set on the console. The positions drawn for the aux knobs and the fader follow the printed scales only approximately; the figure under each control is what counts.
- **Fader level by MIDI**: the button "Capture fader level (MIDI)" of the LEVEL block waits for the position of the fader of the channel from the console's MIDI (controller `n` of channel `n`, 0 to 127, sent when the fader is moved or touched with WRITE on), through the MIDI agent, keeps the last position once the fader has been still for 0.8 s (20 s at most) and stores both the figure in dB (read on the printed scale, approximate) and the MIDI position (exact, `StripSheet.faderMIDI`). Dragging the fader on the screen sets both too. The MIDI position is what a recall can send back to the motorised fader (the console moves it with `B0 n v` when READ is on), which the button "Recall fader" does: it asks the MIDI agent (operation `faderSet`) to send `B0 n v` to the console, through the rate limit in Pro Tools mode.


## Capture of all channels at once, console rotaries (2026-10-28)

- **Parallel capture.** `RecallEngine.start(channels:)` plays one pink noise per channel (seed = channel number, so the noises do not resemble each other) and records every send at the same time. The level of each is lowered so that the sum stays under -20 dBFS. Two whole periods are analysed (about 4 s of recording), so "Capture all channels" and "Reference all channels" take about 5 s instead of 3.5 minutes. A send that comes back below -80 dBFS has no A+B pressed: it is not stored and the application names those channels. Check with `GSR_HW_MULTI=1 swift test --filter printsEveryChannel`.
- **Rotaries of the console move the knobs of the strip.** Mode 3 sends rotary n as controller 0x3F + n, absolute 0 to 127. Rotaries 1 to 6, 11 and 12 are the eight EQ knobs from the top of the strip (HF G, HM Q, F, G, LM Q, F, G, LF G), 7 the input gain, 8 the pan, 9 and 10 the aux sends 1 and 2 (3 and 4 with Shift held). The knob takes the position it has on the console, on the printed scale.
- **Q floor of the fit lowered from 0.4 to 0.1.** On the capture "16 test" (typed values as rough orders of magnitude) the fit with a 0.4 floor stayed 7 to 11 dB rms off on channels set to deep cuts; deep cuts are much wider than a fixed-Q section. With 0.1: 0.13 to 0.27 dB on channels 4 and 6, 2.8 dB on channel 5 (all four bands at the stop). Shelf gains of channels 1 to 3 agree with the typed values within 1.5 dB; the typed bell gains and Q do not (a rough reading, and several settings give nearly the same curve). `GSR_CALIB="<capture name>"` prints the comparison. The simulated recall still reaches 90 % in 19 cases of 20.
