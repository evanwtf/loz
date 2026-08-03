# #4 — APU: implement audio

| | |
|---|---|
| **State** | closed |
| **Labels** | enhancement, emulator |
| **Opened** | 2026-07-31 |
| **Closed** | 2026-07-31 |
| **Author** | evandhoffman |

---

The game is currently silent. Implement the 2A03 APU.

**Channels**
- Pulse 1 and 2 (duty, envelope, sweep, length counter)
- Triangle (linear counter)
- Noise (LFSR, two modes)
- DMC (delta modulation, sample playback, and its CPU stall behaviour)
- Frame counter, 4-step and 5-step modes, with IRQ

**Output**
- Mix and resample ~1.79 MHz to 44.1 kHz
- Ring buffer feeding `AVAudioEngine`
- Audio clock should eventually drive frame pacing to avoid buffer under/overrun

**Testing**
Unit-test channel timers, envelopes, sweep muting, and length counters against known values before wiring any audio out.

https://claude.ai/code/session_01DVdyQgL6CFu9UqSoKdtYCw


---

## Comments (1)

### evandhoffman — 2026-07-31

Implemented: all five channels (pulse 1/2, triangle, noise, DMC), frame counter in both modes with IRQ, non-linear hardware mixer, box-filtered downsampling, and a DC blocker.

The DC blocker turned out to matter more than expected — the mixer output is unipolar and its resting level depends on which channels are live, so the fixed offset I started with turned silence into a constant -0.8 DC level (zero crossings: 0). With a one-pole high-pass it produces real music.

Verified by rendering the title theme and detecting pitch: **A#2 and A#3 exactly an octave apart** (116.7 / 233.3 Hz) plus D#3, G#3, F#2, F#3 — a coherent minor-key set. RMS 0.198, peak 0.61.

Playing through AVAudioEngine in the iOS app. `nesrun audio` renders to WAV with peak/RMS/zero-crossing stats. 30 APU tests.
