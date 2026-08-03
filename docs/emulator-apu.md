# APU

The Ricoh 2A03's audio half. `Sources/NESCore/APU.swift`, with the channels in
`APUChannels.swift` and their shared building blocks in `APUComponents.swift`.

Five channels, mixed non-linearly, box-filtered down to the host sample rate and
handed to the player through a ring buffer. It is clocked once per CPU cycle
from `NES.step`, alongside the PPU.

## Channels

| Channel | Timer rate | Volume | Gates |
|---|---|---|---|
| Pulse 1 | every 2nd CPU cycle | envelope | length, sweep mute |
| Pulse 2 | every 2nd CPU cycle | envelope | length, sweep mute |
| Triangle | **every** CPU cycle | none — on or off | length, linear counter |
| Noise | every 2nd CPU cycle | envelope | length |
| DMC | every CPU cycle | sample level | byte counter |

Two details from that table explain most of how NES music sounds:

- The **triangle clocks twice as fast** as the pulses, so the same period value
  puts it an octave lower. That is why it carries the bass line.
- The **triangle has no volume control at all**. Its dynamic range is flat by
  construction, which is the characteristic NES bass timbre rather than a
  limitation anyone worked around.

### Pulse

Four duty cycles from an 8-step table. The fourth entry is the second inverted —
audibly identical to 25%, just phase-shifted, which matters only when two pulses
are beating against each other.

`resetSequencer()` on a write to `$4003`/`$4007` restarts the waveform, so a
re-triggered note starts from a known phase.

### Triangle

A 32-step sequence descending 15→0 and back. The sequencer **only advances while
both gates are open** and does not reset, so a re-triggered note resumes
mid-waveform rather than clicking.

At `timerPeriod < 2` the output is held at 7 instead of running. Real hardware
produces an ultrasonic buzz there that mostly manifests as a DC pop; silencing
it is inaudible and kinder to speakers.

### Noise

A 15-bit LFSR. `mode` selects the feedback tap: bit 1 gives the long, hiss-like
sequence, bit 6 the short metallic one. The register must never reach zero or it
locks up, so it powers on at 1.

The output polarity is inverted from the obvious reading — **bit 0 set means
silence**.

### DMC

Delta modulation: 1-bit deltas read from ROM, each nudging the output level by
±2 within `0...127`.

It is the only channel that touches the bus. `readMemory` is wired to the CPU
bus by `NES`, and each fetch adds **4 stall cycles** that `APU.step()` returns
for the CPU to absorb. Zelda uses the DMC sparingly; games that lean on it
depend on those stalls, and getting them wrong shows up as timing bugs
elsewhere entirely.

The sample region wraps to `$8000` rather than overflowing past `$FFFF`.

## Shared components

`APUComponents.swift` holds four small state machines, separated out because the
channels combine them differently and because a wrong envelope or length counter
is clearly audible but very hard to attribute by ear.

| | Clocked on | Job |
|---|---|---|
| `LengthCounter` | half-frame | Gates the channel off after a programmed duration |
| `Envelope` | quarter-frame | Constant volume, or a decay from 15 to 0 |
| `Sweep` | half-frame | Pitch slide on the pulse channels |
| `LinearCounter` | quarter-frame | The triangle's finer-grained extra gate |

`LengthCounter.table` is a literal 32-entry ROM table inside the chip, not a
formula. It is transcribed as one.

**The sweep unit differs between the two pulse channels**: channel 1 negates
with one's complement, channel 2 with two's complement. Downward sweeps
therefore land a semitone apart, and games were written around the difference.
`Sweep.isPulse1` carries it.

A channel is muted whenever its period is out of range (`< 8`, or a target
above `$07FF`) — **whether or not the sweep is enabled**. Missing that condition
leaves notes sounding that should be silent.

## Frame counter

A divider off the CPU clock producing quarter- and half-frame ticks. Step
boundaries are in CPU cycles (NTSC):

```
step1  7457    quarter
step2 14913    quarter + half
step3 22371    quarter
step4 29829    quarter + half + IRQ    (4-step mode only)
step5 37281    quarter + half          (5-step mode only)
```

Writing `$4017` resets the divider. Selecting 5-step mode clocks a quarter and a
half frame **immediately**, which is observable: it advances envelopes and
length counters at the moment of the write.

The frame IRQ and the DMC IRQ are OR'd into `irqAsserted`, which `NES.step`
polls into `cpu.setIRQLine` every instruction. Reading `$4015` clears the frame
IRQ; writing it clears the DMC's.

## Mixing

Channels are **not summed linearly**. The hardware DAC loads each channel
against the others, which is why a busy mix sounds compressed rather than
clipped. The documented approximation is used directly:

```swift
pulseOut = 95.88 / (8128 / (pulse1 + pulse2) + 100)
tndOut   = 159.79 / (1 / (tri/8227 + noise/12241 + dmc/22638) + 100)
```

Both terms are special-cased to zero when their inputs are zero, since the
divisions are otherwise undefined there.

### From 1.79 MHz to 44.1 kHz

Every CPU cycle contributes to an accumulator, and the average is emitted when
enough cycles have passed — a box filter, not point sampling. At a ratio near
40:1 point sampling aliases badly, turning high pulse notes into wandering
tones.

Then two one-pole filters:

- **DC blocker**, corner near 15 Hz. The mixer output is unipolar and its
  resting level depends on which channels are currently enabled, so no fixed
  offset can centre it — subtracting one converts silence into a loud DC step.
  The blocker removes whatever the bias happens to be and also stops the level
  jumping when a channel switches on or off.
- **Low pass**, standing in for the console's output filter. Takes the hardest
  edges off the squares without dulling them.

Output is scaled by `outputGain` (2.4) and hard-clamped to `-1...1`.

## Getting samples out

An internal ring buffer, drained by the host:

```swift
public var availableSamples: Int
public func read(into: UnsafeMutablePointer<Float>, count: Int)
public func drain(count: Int) -> [Float]
```

Two deliberate asymmetries:

- **Writes drop on overflow.** If the host is not draining, samples are
  discarded rather than blocking. A stalled audio thread must never stall
  emulation.
- **Reads repeat the last value on underrun.** Padding with silence clicks;
  holding the last sample does not.

`NESPlayer`'s `AudioOutput` mirrors both rules in its own `AudioRingBuffer`,
which sits between the main actor and CoreAudio's real-time thread and is
guarded by `OSAllocatedUnfairLock` — chosen because it participates in priority
inheritance, so the audio thread cannot be blocked indefinitely by a
lower-priority producer.

`EmulatorHost.drainAudio()` runs once per emulated frame. While fast-forwarding
it drains the APU and **throws the samples away**: several frames of audio per
display frame would sound like chipmunks and overflow the queue. The APU keeps
running either way, which is also what muting does — stopping it would desync
anything that depends on `$4015`.

## Verifying it

The suite covers this in three parts (see [testing.md](testing.md)): `APU
components` (15), `APU channels` (8), `APU integration` (7). Between them they
assert envelope decay, sweep arithmetic in both complement modes, length-counter
gating, the frame sequencer's boundaries, per-channel period and output, mixing,
DC blocking, and the sample buffer's rate.

Ears are the other half, and the suite cannot supply them:

```sh
swift run -c release nesrun audio zelda.nes --seconds 10 --out /tmp/zelda.wav
```

That renders headlessly to a WAV with signal statistics, so "is it producing
music, silence, or a DC offset?" is answerable without a device. It takes
`--load-state` and `--input`, so a specific piece of music can be reached first.
See [agent-harness.md](agent-harness.md).

`zeldamac --selftest` also checks the sample rate end to end — it fails if the
APU produces less than 95% or more than 105% of the samples five seconds of game
time should yield. See [macos-app.md](macos-app.md).

## The sample rate is not a constant

`APU.init(sampleRate:)` derives `cyclesPerSample` from it, so the rate decides
how many samples a frame produces. It must be whatever the audio hardware
actually wants, not a chosen default.

An Apple TV over HDMI runs at 48 kHz. Generating 44.1 kHz into it produced 735
samples a frame where 800 were consumed — a permanent 8% deficit that no buffer
absorbs. The ring drained and repeated its last sample, which sounds like the
music dragging rather than like an underrun.

`AudioOutput.hardwareSampleRate()` asks the session and the host passes the
answer to both the APU and the engine. See [gotchas.md](gotchas.md).

## Known simplifications

- **No cycle-exact register write timing.** Writes take effect at the
  instruction boundary rather than mid-instruction.
- **The DMC's stall cycles are absorbed in bulk** by the CPU rather than
  interleaved at the exact cycle of the fetch. Nothing in Zelda depends on the
  difference; a game timing raster effects against DMC playback might.
- **No PAL timing.** Every period table and frame-counter boundary here is NTSC.
