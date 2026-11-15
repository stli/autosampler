Build a modular Lua autosampler library (`lib/autosampler.lua`) and a lightweight example UI script (`autosampler.lua`) for **monome norns** (48 kHz, Lua 5.3 + `softcut` API).

### Core Architecture & Ecosystem Conventions
- **Library (`lib/autosampler.lua`)**: Pure logic, state machine, MIDI/audio routing, and `params` registration (`autosampler:add_params()`). Follow standard norns library conventions (see `markwheeler/timber` for `lib/` encapsulation and UI separation). Expose event callbacks (`on_state_change`, `on_progress`, `on_complete`, `on_error`) with zero screen drawing inside the library.
- **Audio Backend (`softcut`)**: Record raw line-in (`ADC`) into a reusable `softcut` buffer region (stereo or mono L/R selectable) and write WAVs during the guard interval via `softcut.buffer_write_stereo` / `buffer_write_mono` (reference `schollz/oooooo` for clean `softcut` buffer management and WAV export without clicks).
- **Monitoring**: Route line-in to line-out (`audio.level_monitor`) for zero-latency monitoring during setup/sampling, saving and restoring the user's prior `audio` and `softcut` states on `init()` and `cleanup()`. Ensure `softcut` only records `ADC`, never `DAC`.

### Parameters & Controls
- **MIDI**: Output device (`1–16`), MIDI channel (`1–16`).
- **Name**: Name of the patch, default patch-%YYYY%MM%DD
- **Note Range & Step**: `low_note` (`0–127`), `high_note` (`0–127`), `note_step` (`1–12` semitones, default `1`).
- **Velocity Layers**: `vel_layers` (`1–16`). Calculate velocities using interior `linspace` in `(0, 127)` so `0` and `127` are excluded: `math.floor((128 / (N + 1)) * i + 0.5)` for `i = 1..N`.
- **Timing**:
  - `hold_time`: Note On duration in seconds (default `2.0`).
  - `tail_time`: Post-Note-Off recording time for release/reverb tails (default `1.0`). Enforce `hold_time + tail_time <= 300s`.
  - `guard_interval`: Silence pause after recording stops before the next Note On (default `2.0s`).
  - `latency_offset_ms`: Trim offset (`0–100 ms`) applied when exporting buffers to remove USB MIDI + synth + JACK round-trip silence (see `piwip` for automated threshold/trimming patterns).
- **Test Trigger**: Method `autosampler:trigger_test(note, vel, duration)` that sends a test MIDI note (defaulting to middle C at max configured velocity) while exposing live input peak/RMS metering (`poll` on `amp_in_l` / `amp_in_r`) so the user can check gain staging before sampling.

### Sampling Workflow & Output
1. Run inside an abort-safe `clock.run` coroutine (`autosampler:start()` / `autosampler:stop()`).
2. Check available disk space before starting; save files under `_path.audio .. "autosampler/<patch_name>/"`.
3. For each `(note, velocity_layer)`:
   - Reset `softcut` write head to `0`, enable rec, send `note_on`.
   - Sleep `hold_time` -> send `note_off` -> sleep `tail_time` -> disable rec.
   - Export WAV from `latency_offset_ms` to `(hold_time + tail_time)` named `{patch}_{midi_num}_{note_name}_v{vel_low}-{vel_high}.wav` (compatible with standard `.sfz` and norns `mx.samples` note/velocity naming conventions).
   - Sleep `guard_interval`.
   - Auto trim silence at sample start

### Key Community References (llllllll.co / GitHub)
- **`mx.samples` (`llllllll.co/t/mx-samples/41400`)**: Standard norns velocity-layered multisample player; match its note/dynamic filename conventions so captured patches are immediately playable on norns.
- **`piwip` (`llllllll.co/t/piwip`)**: Reference for automated threshold recording, silence detection, and sample start/end trimming.
- **`oooooo` (`github.com/schollz/oooooo`)**: Reference for clean `softcut` input routing and `buffer_write_stereo` / `buffer_write_mono` WAV export.