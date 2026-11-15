# autosampler

A focused autosampler for **monome norns** (48 kHz, Lua 5.3, `softcut`).

The core of the pack is two files:

- `lib/autosampler.lua` — reusable backend: scheduling, MIDI, softcut routing, WAV export, SFZ generation, parameters, state machine. It never draws to the screen.
- `autosampler.lua` — small norns front-end that owns the display and maps K2/K3.

It records line input into a reusable `softcut` buffer while playing note-by-note through an external synth over MIDI, automatically trims the silence before the detected onset, then writes 24-bit WAV files, a standard `.sfz` mapping, and an `mx.samples`-compatible alias pack.

## Install

The recommended way is maiden's REPL (`http://norns.local/maiden` → REPL):

```
;install https://github.com/stli/autosampler
```

This clones the project to `dust/code/autosampler/`. To update later, run `;update autosampler`.

Alternatively, copy this directory there yourself:

```
dust/code/autosampler/
├── autosampler.lua
├── lib/
│   └── autosampler.lua
└── README.md
```

Then select **autosampler** from the script list (restart norns if it does not appear) and set the external synth to receive on the configured MIDI device/channel.

## Quick start

1. In `PARAMETERS > AUTOSAMPLER`, choose the MIDI output device, channel, note range, note step, velocity layers and timing.
2. Set the patch name. The default is today's date (`patch-20261115`); it is sanitized for the filesystem (`My Patch` becomes `My_Patch`).
3. Play the synth and use the on-screen input meters to check gain staging.
4. Press **K2** for a test note (middle C, highest configured velocity layer, hold time).
5. Press **K3** to start. Press **K3** again to stop gracefully.

Monitoring is enabled on init: ADC is routed directly to the outputs during setup and sampling. The previous monitor level and softcut input routing are restored in `cleanup()`.

## Parameters

| Parameter | Range | Default |
|---|---|---|
| MIDI out device | 1–16 | 1 |
| MIDI channel | 1–16 | 1 |
| low note | 0–127 | 36 |
| high note | 0–127 | 84 |
| note step | 1–12 semitones | 1 |
| velocity layers | 1–16 | 1 |
| hold time | 0.05–299.95 s | 2.0 s |
| tail time | 0–299.95 s | 1.0 s |
| guard interval | 0–300 s | 2.0 s |
| latency offset | 0–100 ms | 0 ms |
| record mode | stereo / mono L / mono R | stereo |
| patch name | text | `patch-YYYYMMDD` |

`hold + tail` is constrained to 300 seconds or less, both by parameter actions and again during plan validation.

Velocity trigger points use an interior linspace so neither 0 nor 127 is generated:

```lua
math.floor((128 / (N + 1)) * i + 0.5) -- i = 1..N
```

For example, 2 layers trigger at 43 and 85. Their non-overlapping SFZ ranges are 1–64 and 65–127.

## Capture workflow

Each `(note, velocity layer)` does the following inside an abort-safe `clock.run` coroutine:

1. Reset both write heads to 0 and arm the softcut voices with ADC as their only input.
2. Send MIDI note-on.
3. Wait `hold_time`, send note-off, then wait `tail_time`.
4. Fade the record gain down briefly and close the write heads.
5. Inspect the recorded buffer with `softcut.render_buffer` and advance the export start to the detected onset. If analysis is unavailable or finds no signal, the configured `latency_offset_ms` is used as the export start.
6. Export a WAV from the chosen start through `hold_time + tail_time`, then wait `guard_interval` before the next note.

Because softcut's disk writes are asynchronous, the library also drains the disk worker (a tiny render request queued behind the writes acts as a FIFO barrier) before rewinding the reusable buffer for the next take and before reporting completion. The guard interval remains the audible silence pause. The record region is `0 .. hold + tail + 1`, reused for every take.

Onset detection analyzes up to the first 5 seconds of the take through softcut's render API, using a 4096-bin peak envelope and a threshold 40 dB below the peak. Three consecutive active bins are required, with 5 ms of pre-roll retained before the onset. A detected onset takes precedence over `latency_offset_ms` — otherwise an offset calibrated too high would clip the note's attack; the offset remains the fallback when analysis is unavailable or finds no signal. The old `event_render` callback is restored after each analysis. Hosts can disable or tune this with `options.auto_trim = false`, `trim_analysis_seconds`, `trim_samples`, `trim_relative`, `trim_floor`, `trim_preroll`, and `trim_timeout`.

Before starting, the library checks free space using `norns.disk` when available and `df` otherwise. The estimate assumes softcut's 24-bit WAV output plus a 10 MB reserve.

### Filenames

Primary samples are written to:

```
dust/audio/autosampler/<patch>/
```

with the requested naming shape:

```
<patch>_<midi-note>_<note-name>_v<low>-<high>.wav
```

For example, middle C in a 2-layer stereo pack is:

```
My_Patch_60_C4_v1-64.wav
My_Patch_60_C4_v65-127.wav
```

A standard `<patch>.sfz` is written beside the WAVs. Sampled keys are stretched into the gaps between adjacent notes, so a step-sampled pack remains playable across the selected range.

### mx.samples compatibility

`mx.samples` expects a folder under `dust/audio/mx.samples/` whose WAVs are named:

```
<midi>.<dynamic>.<total-dynamics>.<variation>.<release>.wav
```

The capture automatically creates an alias pack (hardlinks, falling back to symlinks if the two folders are on different filesystems):

```
dust/audio/mx.samples/<patch>/
```

For the same middle-C example:

```
60.1.2.1.0.wav
60.2.2.1.0.wav
```

If linking fails, the primary SFZ pack is still valid and the failure is reported in `result.mx_errors`. Restart/select the pack in `mx.samples` after a run so it re-indexes the folder.

After a successful run the library removes `.wav` files left in either pack folder by earlier runs with a different note range or velocity-layer count, so `mx.samples` never indexes stale notes or dynamics. Set `options.prune_stale = false` to keep them. The disk-write barrier can be tuned with `options.write_timeout` (seconds, default 120).

The stock `mx.samples` script only lists pack names present in its own `available_instruments` table. The generated folder is already in the correct format; either add the sanitized patch id there, or use `mx.samples` as a library (`skeys:on({name = "<patch>", ...})`) in a host script.

## Library API

```lua
local Autosampler = include("lib/autosampler")
local sampler = Autosampler.new({
  patch_name = "my_patch",
  -- callbacks can also be assigned directly or with :set_callback()
  callbacks = {
    on_state_change = function(state, previous, info) end,
    on_progress = function(done, total, info) end,
    on_complete = function(result) end,
    on_error = function(message, context) end,
  },
})

sampler:add_params()
sampler:init()

sampler:trigger_test()             -- C4, max configured velocity, hold_time
sampler:trigger_test(72, 127, 1.5)

local ok, err = sampler:start()    -- non-blocking
sampler:stop()                     -- graceful abort at the next 50 ms checkpoint
sampler:cleanup()                  -- always call from norns cleanup()
```

Useful query methods:

- `get_state()`, `is_running()`, `is_testing()`, `get_last_error()`, `get_last_callback_error()`
- `get_progress()` — state, completed, total, current note/velocity/phase
- `get_meters()` — raw input L/R, peak hold, smoothed RMS estimate, and dB values
- `get_velocity_layers()` — triggers and SFZ velocity ranges
- `build_plan()` — validate the current parameters and get counts/estimates without starting
- `get_result()` — patch folder, SFZ path, files, mx aliases and errors

The live meters come from norns polls on `amp_in_l` and `amp_in_r`. Poll callbacks and rates that existed before `init()` are restored in `cleanup()`; if a poll had no explicit rate, the engine default (0.1 s) is restored instead of leaving the metering rate behind.

Static helpers are available for tests and other tools: `note_name`, `velocity_values`, `velocity_regions`, `make_plan`, `sample_filename`, and `make_sfz`.

## Routing and state restoration

During capture the library:

- routes ADC into softcut and mutes the engine and tape feeds (`cut_input_eng/tape = -inf`);
- zeros all softcut input matrices before patching only the active voice/channel pair;
- disables playback and output on the recording voices;
- never routes softcut output back into its input.

The core norns softcut API exposes setters but no runtime state getter. Exact prior voice state can therefore be supplied by a host that knows it:

```lua
local sampler = Autosampler.new({
  softcut_snapshot = my_saved_voice_state,
})
```

Without that hook, the library snapshots `softcut.defaults()` as its best portable fallback and restores those values on cleanup. Audio mix parameters (monitor level, ADC/engine/tape softcut feeds) are snapshotted from norns params and restored exactly.

The **audio contents** of the reusable softcut region are necessarily overwritten by sampling and are not restored; only routing, levels, and voice parameters are restored.

## Tests

The included mock-based tests need a Lua 5.3 interpreter:

```sh
lua test/test_autosampler.lua
```

They exercise velocity math, filenames, SFZ ranges, stereo and mono-R routing, MIDI ordering, latency and automatic onset trimming, date-based naming, disk rejection, cancellation, state restoration, asynchronous disk-write draining, stale-pack pruning, and the no-screen-drawing boundary.

## References

- `mx.samples` — norns multisample player and filename conventions: <https://github.com/schollz/mx.samples>
- `timber` — lib/UI separation and parameter patterns: <https://github.com/markwheeler/timber>
- `oooooo` — softcut routing and WAV export: <https://github.com/schollz/oooooo>
- `piwip` — threshold-based recording and sample trimming: <https://github.com/schollz/piwip>
