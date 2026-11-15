-- autosampler.lua
-- Reusable MIDI autosampler backend for monome norns.
--
-- The library owns scheduling, MIDI, softcut routing, WAV export, SFZ
-- generation and parameter registration.  It deliberately contains no screen
-- drawing; a host script is expected to render state through the callbacks or
-- by polling get_progress()/get_meters().
--
-- Public callbacks (set by assignment or :set_callback()):
--   on_state_change(state, previous_state, info)
--   on_progress(completed, total, info)
--   on_complete(result)
--   on_error(message, context)

local Autosampler = {}
Autosampler.__index = Autosampler

Autosampler.VERSION = "1.1.0"
Autosampler.MAX_CAPTURE_SECONDS = 300
Autosampler.SAMPLE_RATE = 48000
Autosampler.BYTES_PER_SAMPLE = 3 -- softcut writes 24-bit WAV files
Autosampler.ABORT_GRANULARITY = 0.05
Autosampler.TRIM_ANALYSIS_SECONDS = 5.0
Autosampler.TRIM_SAMPLES = 4096
Autosampler.TRIM_RELATIVE_THRESHOLD = 0.01
Autosampler.TRIM_ABSOLUTE_FLOOR = 0.00001
Autosampler.TRIM_PREROLL = 0.005
Autosampler.TRIM_TIMEOUT = 0.5
Autosampler.WRITE_TIMEOUT = 120
Autosampler.POLL_DEFAULT_TIME = 0.1 -- norns default poll period (s)

Autosampler.STATES = {
  IDLE = "idle",
  PREPARING = "preparing",
  RECORDING = "recording",
  GENERATING = "generating",
  STOPPING = "stopping",
  COMPLETE = "complete",
  CANCELLED = "cancelled",
  ERROR = "error",
}

local STATE = Autosampler.STATES

Autosampler.PARAMS = {
  MIDI_DEVICE = "midi_device",
  MIDI_CHANNEL = "midi_channel",
  LOW_NOTE = "low_note",
  HIGH_NOTE = "high_note",
  NOTE_STEP = "note_step",
  VEL_LAYERS = "vel_layers",
  HOLD_TIME = "hold_time",
  TAIL_TIME = "tail_time",
  GUARD_INTERVAL = "guard_interval",
  LATENCY_OFFSET = "latency_offset_ms",
  RECORD_MODE = "record_mode",
  PATCH_NAME = "patch_name",
}
local P = Autosampler.PARAMS

local NOTE_NAMES = {
  "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
}

local RECORD_MODES = {"stereo", "mono L", "mono R"}

local CALLBACK_NAMES = {
  on_state_change = true,
  on_progress = true,
  on_complete = true,
  on_error = true,
}

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local function round_int(value, fallback)
  value = tonumber(value)
  if value == nil then return fallback end
  return math.floor(value + 0.5)
end

local function is_finite(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function deep_copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[deep_copy(key, seen)] = deep_copy(item, seen)
  end
  return copy
end

local function shell_quote(value)
  value = tostring(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function with_trailing_slash(path)
  if path == nil or path == "" then return path end
  if path:sub(-1) == "/" then return path end
  return path .. "/"
end

local function sanitize_patch_name(name)
  name = tostring(name or "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  name = name:gsub("[^%w%-_ ]", "")
  name = name:gsub("%s+", "_")
  if name == "" then name = "autosampler" end
  if #name > 64 then name = name:sub(1, 64) end
  return name
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function dir_exists(path)
  local ok = os.execute("test -d " .. shell_quote(path))
  return ok == true or ok == 0
end

local function basename(path)
  path = tostring(path or "")
  return path:match("([^/\\]+)$") or path
end

--- List the entry names in a directory (best effort, non-recursive).
local function list_directory(util_api, path)
  local names = {}
  if path == nil or path == "" then return names end
  if util_api and type(util_api.scandir) == "function" then
    local ok, listing = pcall(util_api.scandir, path)
    if ok and type(listing) == "table" then
      for _, name in ipairs(listing) do names[#names + 1] = basename(name) end
      return names
    end
  end
  local handle = io.popen("ls -1 " .. shell_quote(path) .. " 2>/dev/null")
  if handle then
    local output = handle:read("*a")
    handle:close()
    for line in (output or ""):gmatch("[^\r\n]+") do
      names[#names + 1] = basename(line)
    end
  end
  return names
end

local function amp_to_db(value)
  value = tonumber(value) or 0
  if value <= 0.000001 then return -120 end
  return 20 * math.log(value, 10)
end

local function db_to_amp(db)
  if db == nil or db == -math.huge then return 0 end
  return 10 ^ (db / 20)
end

local function write_file(path, contents)
  local file, err = io.open(path, "wb")
  if not file then return nil, err end
  local ok, write_err = file:write(contents)
  local close_ok, close_err = file:close()
  if not ok then return nil, write_err end
  if close_ok == nil then return nil, close_err end
  return true
end

--- Convert a MIDI note number to the conventional C4=60 note name.
function Autosampler.note_name(note)
  note = round_int(note, 60)
  local octave = math.floor(note / 12) - 1
  local name = NOTE_NAMES[(note % 12) + 1]
  return string.format("%s%d", name, octave)
end

--- Interior linspace used for velocity layers.  Neither 0 nor 127 is
--- generated, matching the musical dynamic range requested by norns samplers.
function Autosampler.velocity_values(layers)
  layers = clamp(round_int(layers, 1), 1, 16)
  local values = {}
  for i = 1, layers do
    values[i] = math.floor((128 / (layers + 1)) * i + 0.5)
  end
  return values
end

--- Return the velocity trigger and non-overlapping SFZ range for every layer.
function Autosampler.velocity_regions(layers)
  layers = clamp(round_int(layers, 1), 1, 16)
  local values = Autosampler.velocity_values(layers)
  local regions = {}
  for i = 1, layers do
    local low, high = 1, 127
    if i > 1 then
      low = math.floor((values[i - 1] + values[i]) / 2) + 1
    end
    if i < layers then
      high = math.floor((values[i] + values[i + 1]) / 2)
    end
    if high < low then high = low end
    regions[i] = {
      index = i,
      velocity = values[i],
      low = low,
      high = high,
    }
  end
  return regions
end

local function normalize_record_mode(mode)
  if type(mode) == "number" then
    if mode == 1 then return 1, "stereo" end
    if mode == 2 then return 2, "mono_l" end
    if mode == 3 then return 3, "mono_r" end
  end
  mode = tostring(mode or "stereo"):lower():gsub("%s+", "_")
  if mode == "stereo" or mode == "1" then return 1, "stereo" end
  if mode == "mono_l" or mode == "monol" or mode == "left" or mode == "2" then
    return 2, "mono_l"
  end
  if mode == "mono_r" or mode == "monor" or mode == "right" or mode == "3" then
    return 3, "mono_r"
  end
  return nil, nil
end

--- Pure plan builder.  Useful for hosts and tests, and shared by start().
function Autosampler.make_plan(settings)
  settings = settings or {}

  local low_note = round_int(settings.low_note, 36)
  local high_note = round_int(settings.high_note, 84)
  local note_step = round_int(settings.note_step, 1)
  local vel_layers = round_int(settings.vel_layers, 1)
  local hold_time = tonumber(settings.hold_time)
  local tail_time = tonumber(settings.tail_time)
  local guard_interval = tonumber(settings.guard_interval)
  local latency_ms = tonumber(settings.latency_offset_ms)

  if not is_finite(low_note) or not is_finite(high_note) or
     not is_finite(note_step) or not is_finite(vel_layers) then
    return nil, "note range and layer counts must be finite"
  end
  if low_note < 0 or low_note > 127 or high_note < 0 or high_note > 127 then
    return nil, "note range must stay within 0-127"
  end
  if low_note > high_note then
    return nil, "low note must be less than or equal to high note"
  end
  if note_step < 1 or note_step > 12 then
    return nil, "note step must be between 1 and 12 semitones"
  end
  if vel_layers < 1 or vel_layers > 16 then
    return nil, "velocity layers must be between 1 and 16"
  end

  hold_time = hold_time or 2.0
  tail_time = tail_time or 1.0
  guard_interval = guard_interval or 2.0
  latency_ms = latency_ms or 0

  if not is_finite(hold_time) or not is_finite(tail_time) or
     not is_finite(guard_interval) or not is_finite(latency_ms) then
    return nil, "timing values must be finite"
  end
  if hold_time <= 0 then return nil, "hold time must be greater than zero" end
  if tail_time < 0 then return nil, "tail time cannot be negative" end
  if hold_time + tail_time > Autosampler.MAX_CAPTURE_SECONDS then
    return nil, string.format("hold + tail must be at most %d seconds", Autosampler.MAX_CAPTURE_SECONDS)
  end
  if guard_interval < 0 then return nil, "guard interval cannot be negative" end
  if latency_ms < 0 or latency_ms > 100 then
    return nil, "latency offset must be between 0 and 100 ms"
  end

  local export_start = latency_ms / 1000
  local export_duration = hold_time + tail_time - export_start
  if export_duration <= 0 then
    return nil, "latency offset must be shorter than hold + tail"
  end

  local mode_index, channel_mode = normalize_record_mode(settings.record_mode)
  if not mode_index then
    return nil, "record mode must be stereo, mono L, or mono R"
  end

  local notes = {}
  for note = low_note, high_note, note_step do
    notes[#notes + 1] = note
  end
  if #notes == 0 then return nil, "note range is empty" end

  local layers = Autosampler.velocity_regions(vel_layers)
  local count = #notes * #layers
  local patch = sanitize_patch_name(settings.patch_name)
  local channels = (channel_mode == "stereo") and 2 or 1
  local frames = math.floor(export_duration * Autosampler.SAMPLE_RATE)
  local bytes_per_file = 44 + frames * channels * Autosampler.BYTES_PER_SAMPLE
  local estimated_bytes = math.ceil(bytes_per_file * count * 1.05) + 1024

  return {
    patch = patch,
    low_note = low_note,
    high_note = high_note,
    note_step = note_step,
    vel_layers = vel_layers,
    hold_time = hold_time,
    tail_time = tail_time,
    guard_interval = guard_interval,
    latency_offset_ms = latency_ms,
    export_start = export_start,
    export_duration = export_duration,
    capture_seconds = hold_time + tail_time,
    mode_index = mode_index,
    channel_mode = channel_mode,
    channels = channels,
    notes = notes,
    layers = layers,
    count = count,
    estimated_bytes = estimated_bytes,
    estimated_seconds = count * (hold_time + tail_time + guard_interval),
  }
end

--- Deterministic primary sample filename requested by the sampler spec.
function Autosampler.sample_filename(plan, note, layer)
  return string.format(
    "%s_%d_%s_v%d-%d.wav",
    plan.patch,
    note,
    Autosampler.note_name(note),
    layer.low,
    layer.high
  )
end

--- Build a standard SFZ mapping.  Adjacent sampled notes share the gap
--- between them; this keeps step-sampled instruments playable across the
--- configured range.
function Autosampler.make_sfz(plan)
  local notes = plan.notes
  local ranges = {}
  for i, note in ipairs(notes) do
    local low = plan.low_note
    local high = plan.high_note
    if i > 1 then
      low = math.floor((notes[i - 1] + note) / 2) + 1
    end
    if i < #notes then
      high = math.floor((note + notes[i + 1]) / 2)
    end
    if low < 0 then low = 0 end
    if high > 127 then high = 127 end
    if high < low then high = low end
    ranges[i] = {low = low, high = high}
  end

  local lines = {
    "// Generated by norns autosampler.",
    string.format("// patch: %s", plan.patch),
    string.format("// notes: %d-%d step %d; velocity layers: %d",
      plan.low_note, plan.high_note, plan.note_step, plan.vel_layers),
    "",
  }

  for i, note in ipairs(notes) do
    local key_range = ranges[i]
    for _, layer in ipairs(plan.layers) do
      lines[#lines + 1] = string.format(
        "<region> sample=%s lokey=%d hikey=%d pitch_keycenter=%d lovel=%d hivel=%d",
        Autosampler.sample_filename(plan, note, layer),
        key_range.low,
        key_range.high,
        note,
        layer.low,
        layer.high
      )
    end
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

--- constructor.
function Autosampler.new(options)
  options = options or {}
  local self = setmetatable({}, Autosampler)

  self.options = options
  self.softcut = options.softcut or softcut
  self.audio = options.audio or audio
  self.midi = options.midi or midi
  self.clock = options.clock or clock
  self.params = options.params or params
  self.poll = options.poll or poll
  self.util = options.util or util
  self.norns = options.norns or norns
  self.path = options.path or _path
  self.controlspec = options.controlspec or controlspec

  self.settings = {
    midi_device = options.midi_device or 1,
    midi_channel = options.midi_channel or 1,
    low_note = options.low_note or 36,
    high_note = options.high_note or 84,
    note_step = options.note_step or 1,
    vel_layers = options.vel_layers or 1,
    hold_time = options.hold_time or 2.0,
    tail_time = options.tail_time or 1.0,
    guard_interval = options.guard_interval or 2.0,
    latency_offset_ms = options.latency_offset_ms or 0,
    record_mode = options.record_mode or 1,
    patch_name = options.patch_name or (os.date and os.date("patch-%Y%m%d") or "patch"),
  }

  self.state = STATE.IDLE
  self.callbacks = {}
  if options.callbacks then
    for name, callback in pairs(options.callbacks) do
      if CALLBACK_NAMES[name] and type(callback) == "function" then
        self.callbacks[name] = callback
      end
    end
  end

  self._initialized = false
  self._cleaned = false
  self._params_added = false
  self._running = false
  self._stop_requested = false
  self._completed = 0
  self._planned_total = 0
  self._last_error = nil
  self._result = nil
  self._plan = nil
  self._progress = nil
  self._clock_id = nil
  self._midi_port = nil
  self._current_note = nil
  self._active_channels = {}
  self._softcut_touched = false
  self._audio_touched = false
  self._files = {}
  self._aliases = {}
  self._mx_enabled = options.write_mx_pack ~= false
  self._auto_trim = options.auto_trim ~= false
  self._prune_stale = options.prune_stale ~= false
  self._write_pending = false
  self._mx_errors = {}
  self._test = nil
  self._test_clock = nil
  self._poll_active = false
  self._poll_restore = {}
  self._render_restore = nil

  self.amp_in_l = 0
  self.amp_in_r = 0
  self.input_peak_l = 0
  self.input_peak_r = 0
  self.input_rms_l = 0
  self.input_rms_r = 0

  return self
end

--- Register the complete parameter group.  Safe to call more than once.
function Autosampler:add_params()
  if self._params_added then return true end
  if not self.params then return false, "params API unavailable" end

  local cs = self.controlspec
  if not cs or type(cs.new) ~= "function" then
    return false, "controlspec API unavailable"
  end

  local count = 12
  self.params:add_group("AUTOSAMPLER", count)

  self.params:add_number(P.MIDI_DEVICE, "midi out device", 1, 16,
    self.settings.midi_device)
  self.params:add_number(P.MIDI_CHANNEL, "midi channel", 1, 16,
    self.settings.midi_channel)
  self.params:add_number(P.LOW_NOTE, "low note", 0, 127,
    self.settings.low_note)
  self.params:add_number(P.HIGH_NOTE, "high note", 0, 127,
    self.settings.high_note)
  self.params:add_number(P.NOTE_STEP, "note step", 1, 12,
    self.settings.note_step)
  self.params:add_number(P.VEL_LAYERS, "velocity layers", 1, 16,
    self.settings.vel_layers)
  self.params:add_control(P.HOLD_TIME, "hold time",
    cs.new(0.05, 299.95, "lin", 0.05, self.settings.hold_time, "s"))
  self.params:add_control(P.TAIL_TIME, "tail time",
    cs.new(0, 299.95, "lin", 0.05, self.settings.tail_time, "s"))
  self.params:add_control(P.GUARD_INTERVAL, "guard interval",
    cs.new(0, 300, "lin", 0.1, self.settings.guard_interval, "s"))
  self.params:add_control(P.LATENCY_OFFSET, "latency offset",
    cs.new(0, 100, "lin", 1, self.settings.latency_offset_ms, "ms"))
  self.params:add_option(P.RECORD_MODE, "record mode", RECORD_MODES,
    normalize_record_mode(self.settings.record_mode) or 1)
  self.params:add_text(P.PATCH_NAME, "patch name", self.settings.patch_name)

  if self.params.set_action then
    self.params:set_action(P.HOLD_TIME, function(value)
      self:_enforce_duration_budget(P.HOLD_TIME, value)
    end)
    self.params:set_action(P.TAIL_TIME, function(value)
      self:_enforce_duration_budget(P.TAIL_TIME, value)
    end)
    self.params:set_action(P.LOW_NOTE, function(value)
      self:_enforce_note_range(P.LOW_NOTE, value)
    end)
    self.params:set_action(P.HIGH_NOTE, function(value)
      self:_enforce_note_range(P.HIGH_NOTE, value)
    end)
  end

  self._params_added = true
  return true
end

function Autosampler:_param(id, fallback)
  if not self.params or type(self.params.get) ~= "function" then
    return fallback
  end
  local ok, value = pcall(self.params.get, self.params, id)
  if ok and value ~= nil then return value end
  return fallback
end

function Autosampler:_set_param(id, value, silent)
  if not self.params or type(self.params.set) ~= "function" then
    return false
  end
  return pcall(self.params.set, self.params, id, value, silent)
end

function Autosampler:_enforce_duration_budget(changed_id, changed_value)
  changed_value = tonumber(changed_value) or 0
  local other = 0
  if changed_id == P.HOLD_TIME then
    other = tonumber(self:_param(P.TAIL_TIME, 0)) or 0
  else
    other = tonumber(self:_param(P.HOLD_TIME, 0)) or 0
  end
  local maximum = Autosampler.MAX_CAPTURE_SECONDS - other
  if changed_value > maximum then
    self:_set_param(changed_id, math.max(0, maximum), true)
  end
end

function Autosampler:_enforce_note_range(changed_id, changed_value)
  changed_value = tonumber(changed_value) or 0
  if changed_id == P.LOW_NOTE then
    local high = tonumber(self:_param(P.HIGH_NOTE, changed_value)) or changed_value
    if changed_value > high then self:_set_param(P.HIGH_NOTE, changed_value, true) end
  else
    local low = tonumber(self:_param(P.LOW_NOTE, changed_value)) or changed_value
    if changed_value < low then self:_set_param(P.LOW_NOTE, changed_value, true) end
  end
end

function Autosampler:set_callback(name, callback)
  if not CALLBACK_NAMES[name] then return false, "unknown callback" end
  if callback ~= nil and type(callback) ~= "function" then
    return false, "callback must be a function or nil"
  end
  self.callbacks[name] = callback
  return true
end

function Autosampler:_emit_callback(name, ...)
  local callback = self[name]
  if type(callback) ~= "function" then callback = self.callbacks[name] end
  if type(callback) == "function" then
    local ok, err = pcall(callback, ...)
    if not ok then self._last_callback_error = err end
  end
end

function Autosampler:_set_state(new_state, info)
  local previous = self.state
  self.state = new_state
  if new_state ~= previous then
    self:_emit_callback("on_state_change", new_state, previous, info or {})
  end
end

function Autosampler:_emit_progress(completed, total, info)
  info = info or {}
  info.completed = completed
  info.total = total
  info.state = self.state
  self._progress = info
  self:_emit_callback("on_progress", completed, total, info)
end

function Autosampler:get_state() return self.state end
function Autosampler:is_running() return self._running end
function Autosampler:is_testing() return self._test ~= nil end
function Autosampler:get_last_error() return self._last_error end
function Autosampler:get_last_callback_error() return self._last_callback_error end
function Autosampler:get_result() return self._result end

function Autosampler:get_velocity_layers()
  return Autosampler.velocity_regions(self:_param(P.VEL_LAYERS, self.settings.vel_layers))
end

function Autosampler:get_max_velocity()
  local layers = self:get_velocity_layers()
  return layers[#layers].velocity
end

function Autosampler:get_progress()
  local progress = self._progress or {}
  local copy = {}
  for key, value in pairs(progress) do copy[key] = value end
  copy.state = self.state
  copy.completed = self._completed
  copy.total = self._planned_total
  copy.running = self._running
  copy.testing = self._test ~= nil
  return copy
end

function Autosampler:get_meters()
  return {
    l = self.amp_in_l,
    r = self.amp_in_r,
    peak_l = self.input_peak_l,
    peak_r = self.input_peak_r,
    rms_l = self.input_rms_l,
    rms_r = self.input_rms_r,
    db_l = amp_to_db(self.amp_in_l),
    db_r = amp_to_db(self.amp_in_r),
    peak_db_l = amp_to_db(self.input_peak_l),
    peak_db_r = amp_to_db(self.input_peak_r),
    rms_db_l = amp_to_db(self.input_rms_l),
    rms_db_r = amp_to_db(self.input_rms_r),
  }
end

function Autosampler:reset_meters()
  self.input_peak_l = 0
  self.input_peak_r = 0
  self.input_rms_l = 0
  self.input_rms_r = 0
end

function Autosampler:_meter_value(channel, value)
  value = tonumber(value) or 0
  if value < 0 then value = -value end
  if channel == "l" then
    self.amp_in_l = value
    if value > self.input_peak_l then self.input_peak_l = value end
    self.input_rms_l = math.sqrt(0.2 * value * value + 0.8 * self.input_rms_l * self.input_rms_l)
  else
    self.amp_in_r = value
    if value > self.input_peak_r then self.input_peak_r = value end
    self.input_rms_r = math.sqrt(0.2 * value * value + 0.8 * self.input_rms_r * self.input_rms_r)
  end
end

function Autosampler:_start_metering()
  if self._poll_active then return true end
  if not self.poll or type(self.poll.set) ~= "function" then return false end

  local rate = tonumber(self.options.poll_rate) or 0.05
  local polls = self.poll.polls
  local function install(name, channel)
    if polls and polls[name] == nil then return end
    local existing = polls and polls[name]
    if existing and existing.props then
      self._poll_restore[name] = {
        callback = existing.props.callback,
        time = existing.props.time,
      }
    end
    local poll_object = self.poll.set(name, function(value)
      self:_meter_value(channel, value)
    end)
    if poll_object then
      poll_object.time = rate
      if poll_object.start then poll_object:start() end
    end
  end

  install("amp_in_l", "l")
  install("amp_in_r", "r")
  self._poll_active = true
  return true
end

function Autosampler:_stop_metering()
  if not self._poll_active then return end
  local polls = self.poll and self.poll.polls
  if polls then
    for name, saved in pairs(self._poll_restore) do
      local poll_object = polls[name]
      if poll_object then
        if poll_object.stop then poll_object:stop() end
        -- Stock norns poll props carry no explicit period unless a script set
        -- one; the engine default is 0.1 s, so restore that instead of leaving
        -- our faster metering rate behind.
        if saved.time ~= nil then
          poll_object.time = saved.time
        else
          poll_object.time = Autosampler.POLL_DEFAULT_TIME
        end
        self.poll.set(name, saved.callback)
      end
    end
  end
  self._poll_active = false
  self._poll_restore = {}
  self._render_restore = nil
end

function Autosampler:_snapshot_audio()
  self._audio_snapshot = {}
  local ids = {
    "monitor_level",
    "cut_input_adc",
    "cut_input_eng",
    "cut_input_tape",
  }
  for _, id in ipairs(ids) do
    local value = self:_param(id, nil)
    if value == nil and self.norns and self.norns.state and self.norns.state.mix then
      local mix_key = id
      if id == "monitor_level" then mix_key = "monitor" end
      value = self.norns.state.mix[mix_key]
    end
    self._audio_snapshot[id] = value
  end
  if self.options.audio_snapshot then
    for id, value in pairs(self.options.audio_snapshot) do
      self._audio_snapshot[id] = value
    end
  end
end

function Autosampler:_set_audio_level(id, db, setter)
  -- Not silent: the parameter action is what actually updates the audio bus.
  local param_ok = self:_set_param(id, db, false)
  if setter and self.audio then
    local ok = pcall(setter, db_to_amp(db))
    if ok then return true end
  end
  return param_ok
end

function Autosampler:_apply_monitor()
  if self.options.monitor == false then return end
  self._audio_touched = true
  self:_set_audio_level("monitor_level", 0, self.audio and self.audio.level_monitor)
end

function Autosampler:_apply_capture_routes()
  self._audio_touched = true
  -- The softcut input is ADC only: mute engine and tape feeds and enable ADC.
  self:_set_audio_level("cut_input_adc", 0, self.audio and self.audio.level_adc_cut)
  self:_set_audio_level("cut_input_eng", -math.huge, self.audio and self.audio.level_eng_cut)
  self:_set_audio_level("cut_input_tape", -math.huge, self.audio and self.audio.level_tape_cut)
end

function Autosampler:_restore_audio()
  if not self._audio_touched or not self._audio_snapshot then return end
  local setters = {
    monitor_level = self.audio and self.audio.level_monitor,
    cut_input_adc = self.audio and self.audio.level_adc_cut,
    cut_input_eng = self.audio and self.audio.level_eng_cut,
    cut_input_tape = self.audio and self.audio.level_tape_cut,
  }
  for id, value in pairs(self._audio_snapshot) do
    if value ~= nil then self:_set_audio_level(id, value, setters[id]) end
  end
  self._audio_touched = false
end

function Autosampler:_snapshot_softcut()
  self._softcut_snapshot = nil
  if self.options.softcut_snapshot then
    local snapshot = self.options.softcut_snapshot
    if type(snapshot) == "function" then
      local ok, value = pcall(snapshot)
      if ok then snapshot = value end
    end
    if type(snapshot) == "table" then
      self._softcut_snapshot = deep_copy(snapshot)
    end
    return
  end
  if not self.softcut then return end

  local getter = self.softcut.get_voice_state
  if type(getter) == "function" then
    local snapshot = {}
    for voice = 1, 6 do
      local ok, state = pcall(getter, voice)
      if ok and type(state) == "table" then snapshot[voice] = deep_copy(state) end
    end
    self._softcut_snapshot = snapshot
    return
  end

  -- norns' softcut core has setters but no runtime state getter.  defaults()
  -- is the only portable fallback; hosts that know their prior voice state can
  -- pass options.softcut_snapshot for an exact restore.
  if type(self.softcut.defaults) == "function" then
    local ok, defaults = pcall(self.softcut.defaults)
    if ok and type(defaults) == "table" then
      self._softcut_snapshot = deep_copy(defaults)
    end
  end
end

local SIMPLE_SOFTCUT_KEYS = {
  "enable", "play", "rate", "loop_start", "loop_end", "loop", "fade_time",
  "rec_level", "pre_level", "rec", "record", "rec_offset", "position",
  "buffer", "level", "pan", "level_slew_time", "pan_slew_time",
  "recpre_slew_time", "rate_slew_time",
  "pre_filter_fc", "pre_filter_fc_mod", "pre_filter_rq",
  "pre_filter_lp", "pre_filter_hp", "pre_filter_bp", "pre_filter_br",
  "pre_filter_dry", "post_filter_fc", "post_filter_rq", "post_filter_lp",
  "post_filter_hp", "post_filter_bp", "post_filter_br", "post_filter_dry",
}

function Autosampler:_restore_softcut()
  if not self._softcut_touched or not self._softcut_snapshot then return end
  local softcut = self.softcut
  if not softcut then return end

  for voice = 1, 6 do
    local state = self._softcut_snapshot[voice]
    if type(state) == "table" then
      for _, key in ipairs(SIMPLE_SOFTCUT_KEYS) do
        local value = state[key]
        local setter = softcut[key]
        if key == "record" and type(softcut.rec) == "function" then setter = softcut.rec end
        if value ~= nil and type(setter) == "function" then
          pcall(setter, voice, value)
        end
      end
      if type(state.level_input_cut) == "table" and type(softcut.level_input_cut) == "function" then
        for channel = 1, 2 do
          local value = state.level_input_cut[channel]
          if value ~= nil then pcall(softcut.level_input_cut, channel, voice, value) end
        end
      end
      if type(state.level_cut_cut) == "table" and type(softcut.level_cut_cut) == "function" then
        for source = 1, 6 do
          local value = state.level_cut_cut[source]
          if value ~= nil then pcall(softcut.level_cut_cut, source, voice, value) end
        end
      end
    end
  end
  self._softcut_touched = false
end

function Autosampler:_require_softcut(mode)
  if not self.softcut then return nil, "softcut API unavailable" end
  local required = {
    "buffer", "enable", "play", "rec", "position", "rec_level", "pre_level",
    "loop_start", "loop_end", "loop", "level_input_cut", "level",
    "rec_offset", "fade_time", "recpre_slew_time", "level_slew_time", "rate",
  }
  if mode == "stereo" then
    required[#required + 1] = "buffer_write_stereo"
  else
    required[#required + 1] = "buffer_write_mono"
  end
  for _, name in ipairs(required) do
    if type(self.softcut[name]) ~= "function" then
      return nil, "softcut is missing " .. name .. "()"
    end
  end
  return true
end

function Autosampler:_configure_softcut(plan)
  local ok, err = self:_require_softcut(plan.channel_mode)
  if not ok then return false, err end

  if not self._softcut_snapshot then self:_snapshot_softcut() end
  self._softcut_touched = true

  local softcut = self.softcut
  local active = (plan.channel_mode == "stereo") and {1, 2}
    or (plan.channel_mode == "mono_l") and {1}
    or {2}
  self._active_channels = active

  -- Silence every input-to-voice feed first, then patch the pair used for the
  -- take.  This cannot leave a previous script's feedback path audible or
  -- (more importantly) writable in the recording region.
  for voice = 1, 6 do
    pcall(softcut.rec, voice, 0)
    pcall(softcut.level_input_cut, 1, voice, 0)
    pcall(softcut.level_input_cut, 2, voice, 0)
    if type(softcut.level_cut_cut) == "function" then
      for source = 1, 6 do pcall(softcut.level_cut_cut, source, voice, 0) end
    end
  end

  for _, voice in ipairs(active) do
    pcall(softcut.buffer, voice, voice)
    pcall(softcut.enable, voice, 1)
    pcall(softcut.play, voice, 0)
    pcall(softcut.level, voice, 0)
    pcall(softcut.pan, voice, 0)
    pcall(softcut.rate, voice, 1)
    pcall(softcut.fade_time, voice, 0.002)
    pcall(softcut.level_slew_time, voice, 0.01)
    pcall(softcut.recpre_slew_time, voice, 0.001)
    pcall(softcut.rec_offset, voice, 0)
    pcall(softcut.rec_level, voice, 1)
    pcall(softcut.pre_level, voice, 0)
    -- The softcut voice pre-filter defaults to a 16 kHz low-pass.  Bypass it
    -- so the autosampler captures the actual ADC signal.
    pcall(softcut.pre_filter_dry, voice, 1)
    pcall(softcut.pre_filter_lp, voice, 0)
    pcall(softcut.pre_filter_hp, voice, 0)
    pcall(softcut.pre_filter_bp, voice, 0)
    pcall(softcut.pre_filter_br, voice, 0)
    pcall(softcut.loop_start, voice, 0)
    pcall(softcut.loop_end, voice, plan.capture_seconds + 1.0)
    pcall(softcut.loop, voice, 1)
    pcall(softcut.level_input_cut, 1, voice, voice == 1 and 1 or 0)
    pcall(softcut.level_input_cut, 2, voice, voice == 2 and 1 or 0)
  end

  return true
end

function Autosampler:_hard_stop_recording()
  if not self.softcut then return end
  for _, voice in ipairs(self._active_channels or {}) do
    pcall(self.softcut.rec_level, voice, 0)
    pcall(self.softcut.rec, voice, 0)
    pcall(self.softcut.play, voice, 0)
  end
end

function Autosampler:_fade_stop_recording()
  if not self.softcut then return end
  for _, voice in ipairs(self._active_channels) do
    pcall(self.softcut.rec_level, voice, 0)
  end
  -- Let softcut's record ramp reach zero before closing the write head.  This
  -- avoids a hard discontinuity at the end of the recorded region.
  if self.clock and self.clock.sleep then self.clock.sleep(0.02) end
  for _, voice in ipairs(self._active_channels) do
    pcall(self.softcut.rec, voice, 0)
    -- Restore the record gain while the write head is closed, so the next
    -- take starts at full level instead of fading in over its first milliseconds.
    pcall(self.softcut.rec_level, voice, 1)
  end
end

function Autosampler:_current_render_callback()
  local nor = rawget(_G, "_norns")
  if type(nor) == "table" and type(nor.softcut_render) == "function" then
    return nor.softcut_render
  end
  return nil
end

function Autosampler:_restore_render_callback()
  local callback = self._render_restore
  self._render_restore = nil
  if callback and self.softcut and type(self.softcut.event_render) == "function" then
    pcall(self.softcut.event_render, callback)
  end
end

function Autosampler:_render_buffer_data(channels, duration, sample_count)
  local softcut = self.softcut
  if not softcut or type(softcut.event_render) ~= "function" or
     type(softcut.render_buffer) ~= "function" then
    return nil, "softcut render API unavailable"
  end

  local expected, data = {}, {}
  for _, channel in ipairs(channels) do expected[channel] = true end
  local received = 0
  local handler = function(channel, start_time, sec_per_sample, samples)
    if expected[channel] and not data[channel] then
      data[channel] = {
        start = tonumber(start_time) or 0,
        sec = tonumber(sec_per_sample) or 0,
        values = samples,
      }
      received = received + 1
    end
  end

  local previous = self:_current_render_callback()
  local set_ok = pcall(softcut.event_render, handler)
  if not set_ok then return nil, "could not install render callback" end
  self._render_restore = previous or function() end

  for _, channel in ipairs(channels) do
    pcall(softcut.render_buffer, channel, 0, duration, sample_count)
  end

  local remaining = tonumber(self.options.trim_timeout) or Autosampler.TRIM_TIMEOUT
  while received < #channels and remaining > 0 do
    if self._stop_requested then break end
    if not self.clock or not self.clock.sleep then break end
    local step = math.min(0.01, remaining)
    self.clock.sleep(step)
    remaining = remaining - step
  end

  self:_restore_render_callback()
  if self._stop_requested then return nil, "stopped" end
  if received == 0 then return nil, "no render data" end
  return data
end

--- Wait until every softcut disk job queued so far has completed.
---
---  WAV exports are asynchronous on crone's disk worker, and the file appears
--- as soon as the worker opens it, so polling for existence does not prove the
--- buffer has been read.  A tiny render request enqueued after the writes acts
--- as a FIFO barrier (the worker drains one job queue in order).  Without this,
--- the next take can rewind and overwrite the shared buffer while the previous
--- export is still reading it, producing corrupt WAVs for long captures.
---
--- Returns true when drained (or when the render API is unavailable), false
--- when interrupted by stop(), or nil plus a message on timeout.
function Autosampler:_drain_writes()
  if not self._write_pending then return true end
  local softcut = self.softcut
  if not softcut or type(softcut.event_render) ~= "function" or
     type(softcut.render_buffer) ~= "function" then
    return true
  end

  local channel = (self._active_channels and self._active_channels[1]) or 1
  local done = false
  local previous = self:_current_render_callback()
  local installed = pcall(softcut.event_render, function() done = true end)
  if not installed then return true end
  self._render_restore = previous or function() end

  local requested = pcall(softcut.render_buffer, channel, 0, 0.005, 8)
  if not requested then
    self:_restore_render_callback()
    return true
  end

  local remaining = tonumber(self.options.write_timeout) or Autosampler.WRITE_TIMEOUT
  while not done and remaining > 0 do
    if self._stop_requested then break end
    if not self.clock or type(self.clock.sleep) ~= "function" then break end
    local step = math.min(0.01, remaining)
    self.clock.sleep(step)
    remaining = remaining - step
  end
  self:_restore_render_callback()

  if self._stop_requested then return false end
  if not done then
    return nil, "timed out waiting for softcut disk writes"
  end
  self._write_pending = false
  return true
end

function Autosampler:_detect_onset(plan)
  if not self._auto_trim then return nil end

  local channels = self._active_channels
  if #channels == 0 then return nil end

  local analysis_duration = math.min(
    plan.capture_seconds,
    tonumber(self.options.trim_analysis_seconds) or Autosampler.TRIM_ANALYSIS_SECONDS
  )
  local sample_count = math.floor(tonumber(self.options.trim_samples) or Autosampler.TRIM_SAMPLES)
  if analysis_duration <= 0 or sample_count < 8 then return nil end

  local data, err = self:_render_buffer_data(channels, analysis_duration, sample_count)
  if not data then return nil, err end

  local first = data[channels[1]]
  for _, channel in ipairs(channels) do
    if data[channel] then first = data[channel] break end
  end
  if not first then return nil end

  local max_len = 0
  for _, channel in ipairs(channels) do
    local item = data[channel]
    if item and item.values then
      if #item.values > max_len then max_len = #item.values end
    end
  end
  if max_len < 1 then return nil end

  local envelope, peak = {}, 0
  for i = 1, max_len do
    local value = 0
    for _, channel in ipairs(channels) do
      local item = data[channel]
      if item and item.values[i] then
        value = math.max(value, math.abs(item.values[i]))
      end
    end
    envelope[i] = value
    if value > peak then peak = value end
  end
  if peak <= Autosampler.TRIM_ABSOLUTE_FLOOR then return nil end

  local floor = tonumber(self.options.trim_floor) or Autosampler.TRIM_ABSOLUTE_FLOOR
  local relative = tonumber(self.options.trim_relative) or Autosampler.TRIM_RELATIVE_THRESHOLD
  local threshold = math.max(peak * relative, floor)
  local run, onset_index = 0, nil
  for i = 1, #envelope do
    if envelope[i] >= threshold then
      run = run + 1
      if run >= 3 then
        onset_index = i - 2
        break
      end
    else
      run = 0
    end
  end
  if not onset_index then return nil end

  local sec_per_sample = first.sec
  if sec_per_sample <= 0 then sec_per_sample = analysis_duration / sample_count end
  local onset_time = (first.start or 0) + (onset_index - 1) * sec_per_sample
  local preroll = tonumber(self.options.trim_preroll) or Autosampler.TRIM_PREROLL
  local trimmed = math.max(0, onset_time - preroll)
  return trimmed
end

function Autosampler:_export_window(plan)
  local start_time = plan.export_start
  local duration = plan.export_duration

  if self._auto_trim then
    local onset, err = self:_detect_onset(plan)
    if err == "stopped" then return nil, nil, "stopped" end
    if onset then
      -- A detected onset is the true signal start, so prefer it even when it
      -- falls before the configured latency offset; the offset remains the
      -- fallback when detection is unavailable.  Otherwise a too-large offset
      -- would clip the sample's attack.
      local candidate = math.max(0, onset)
      local minimum_tail = math.min(0.02, plan.capture_seconds * 0.05)
      if candidate < plan.capture_seconds - minimum_tail then
        start_time = candidate
        duration = plan.capture_seconds - candidate
      end
    end
  end

  return start_time, duration
end

function Autosampler:_read_settings()
  return {
    midi_device = self:_param(P.MIDI_DEVICE, self.settings.midi_device),
    midi_channel = self:_param(P.MIDI_CHANNEL, self.settings.midi_channel),
    low_note = self:_param(P.LOW_NOTE, self.settings.low_note),
    high_note = self:_param(P.HIGH_NOTE, self.settings.high_note),
    note_step = self:_param(P.NOTE_STEP, self.settings.note_step),
    vel_layers = self:_param(P.VEL_LAYERS, self.settings.vel_layers),
    hold_time = self:_param(P.HOLD_TIME, self.settings.hold_time),
    tail_time = self:_param(P.TAIL_TIME, self.settings.tail_time),
    guard_interval = self:_param(P.GUARD_INTERVAL, self.settings.guard_interval),
    latency_offset_ms = self:_param(P.LATENCY_OFFSET, self.settings.latency_offset_ms),
    record_mode = self:_param(P.RECORD_MODE, self.settings.record_mode),
    patch_name = self:_param(P.PATCH_NAME, self.settings.patch_name),
  }
end

function Autosampler:build_plan()
  local settings = self:_read_settings()
  local plan, err = Autosampler.make_plan(settings)
  if plan then
    plan.midi_device = round_int(settings.midi_device, 1)
    plan.midi_channel = round_int(settings.midi_channel, 1)
  end
  return plan, err
end

function Autosampler:_audio_root()
  local root = self.options.audio_path
  if not root and self.path then root = self.path.audio end
  if not root and _path then root = _path.audio end
  return root
end

function Autosampler:_make_dir(path)
  if not path or path == "" then return false, "empty path" end
  if self.util and type(self.util.make_dir) == "function" then
    local ok = pcall(self.util.make_dir, path)
    if ok and dir_exists(path) then return true end
  end
  local ok = os.execute("mkdir -p " .. shell_quote(path))
  if (ok == true or ok == 0) and dir_exists(path) then return true end
  return false, "could not create " .. path
end

function Autosampler:_free_disk_bytes()
  if self.options.disk_free_mb ~= nil then
    return tonumber(self.options.disk_free_mb) * 1024 * 1024
  end
  if self.norns and tonumber(self.norns.disk) then
    -- norns reports free space in 1024000-byte MB units (matron stat.cc).
    return tonumber(self.norns.disk) * 1024000
  end
  local root = self:_audio_root()
  if not root then return nil end
  local command = "df -Pk " .. shell_quote(root) .. " 2>/dev/null"
  local output
  if self.util and type(self.util.os_capture) == "function" then
    local ok, captured = pcall(self.util.os_capture, command, true)
    if ok then output = captured end
  end
  if not output then
    local handle = io.popen(command)
    if handle then
      output = handle:read("*a")
      handle:close()
    end
  end
  if not output then return nil end
  local last
  for line in output:gmatch("[^\r\n]+") do
    if not line:match("^Filesystem") and line:match("%S") then last = line end
  end
  if not last then return nil end
  local fields = {}
  for field in last:gmatch("%S+") do fields[#fields + 1] = field end
  local available_kb = tonumber(fields[4])
  if not available_kb then return nil end
  return available_kb * 1024
end

function Autosampler:_check_disk(plan, folder)
  local free_bytes = self:_free_disk_bytes()
  if free_bytes == nil then return true end -- cannot determine; let the OS decide
  local reserve = 10 * 1024 * 1024
  local need = plan.estimated_bytes + reserve
  if free_bytes < need then
    return false, string.format(
      "not enough disk space (need %.1f MB, %.1f MB free)",
      need / (1024 * 1024), free_bytes / (1024 * 1024)
    )
  end
  return true
end

function Autosampler:_connect_midi(device)
  if not self.midi or type(self.midi.connect) ~= "function" then
    return nil, "MIDI API unavailable"
  end
  local ok, port = pcall(self.midi.connect, device)
  if not ok or not port then return nil, "could not connect to MIDI output " .. tostring(device) end
  if port.name == "none" and port.device == nil then
    return nil, "no MIDI device on output " .. tostring(device)
  end
  self._midi_port = port
  return port
end

function Autosampler:_note_on(note, velocity, channel)
  local port = self._midi_port
  if not port or type(port.note_on) ~= "function" then
    return false, "MIDI output is not connected"
  end
  local ok, err = pcall(port.note_on, port, note, velocity, channel)
  if not ok then return false, tostring(err) end
  return true
end

function Autosampler:_note_off(note, channel)
  local port = self._midi_port
  if not port then return end
  channel = channel or self:_param(P.MIDI_CHANNEL, self.settings.midi_channel)
  if type(port.note_off) == "function" then
    pcall(port.note_off, port, note, 0, channel)
  end
end

function Autosampler:_all_notes_off()
  local port = self._midi_port
  if not port then return end
  local channel = self:_param(P.MIDI_CHANNEL, self.settings.midi_channel)
  if type(port.cc) == "function" then
    pcall(port.cc, port, 123, 0, channel)
  end
end

function Autosampler:_release_current_note()
  if self._current_note then
    self:_note_off(self._current_note.note, self._current_note.channel)
    self._current_note = nil
  end
end

function Autosampler:_sleep_interruptible(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then return not self._stop_requested end
  if not self.clock or type(self.clock.sleep) ~= "function" then
    return false, "clock API unavailable"
  end
  local remaining = seconds
  while remaining > 0.000001 do
    if self._stop_requested then return false end
    local step = math.min(Autosampler.ABORT_GRANULARITY, remaining)
    self.clock.sleep(step)
    remaining = remaining - step
  end
  return not self._stop_requested
end

function Autosampler:init()
  if self._initialized then return true end
  self._cleaned = false
  self._initialized = true
  self._last_error = nil

  self:_snapshot_audio()
  self:_snapshot_softcut()
  self:_start_metering()
  self:_apply_monitor()
  self:_set_state(STATE.IDLE, {phase = "init"})
  return true
end

--- Begin a sampling run.  Validation/disk probing happen synchronously; the
--- actual note-by-note work runs in a clock coroutine so the UI remains alive.
function Autosampler:start()
  if self._running then return false, "sampler is already running" end
  if not self._initialized then
    local ok, err = self:init()
    if not ok then return self:_start_error(err) end
  end

  self:stop()
  self:reset_meters()
  self._stop_requested = false
  self._completed = 0
  self._last_error = nil
  self._files = {}
  self._aliases = {}
  self._mx_errors = {}

  local plan, err = self:build_plan()
  if not plan then return self:_start_error(err) end

  if not self.clock or type(self.clock.run) ~= "function" or type(self.clock.sleep) ~= "function" then
    return self:_start_error("clock API unavailable")
  end

  local root = self:_audio_root()
  if not root or root == "" then return self:_start_error("audio path is unavailable") end
  root = with_trailing_slash(root)

  local mx_requested = self.options.write_mx_pack ~= false
  local pack_root = with_trailing_slash(self.options.pack_root or (root .. "autosampler"))
  local mx_root = with_trailing_slash(self.options.mx_samples_root or (root .. "mx.samples"))
  plan.folder = pack_root .. plan.patch .. "/"
  plan.sfz_path = plan.folder .. plan.patch .. ".sfz"
  plan.mx_folder = nil
  if mx_requested then plan.mx_folder = mx_root .. plan.patch .. "/" end

  local made, make_err = self:_make_dir(plan.folder)
  if not made then return self:_start_error(make_err) end
  if plan.mx_folder then
    local mx_made = self:_make_dir(plan.mx_folder)
    if not mx_made then plan.mx_folder = nil end
  end
  self._mx_enabled = plan.mx_folder ~= nil

  local disk_ok, disk_err = self:_check_disk(plan, plan.folder)
  if not disk_ok then return self:_start_error(disk_err) end

  local device = round_int(self:_param(P.MIDI_DEVICE, self.settings.midi_device), 1)
  local channel = round_int(self:_param(P.MIDI_CHANNEL, self.settings.midi_channel), 1)
  if device < 1 or device > 16 then return self:_start_error("MIDI output must be 1-16") end
  if channel < 1 or channel > 16 then return self:_start_error("MIDI channel must be 1-16") end
  local port, midi_err = self:_connect_midi(device)
  if not port then return self:_start_error(midi_err) end
  plan.midi_device = device
  plan.midi_channel = channel

  local configured, config_err = self:_configure_softcut(plan)
  if not configured then return self:_start_error(config_err) end
  self:_apply_capture_routes()
  self:_apply_monitor()

  -- From this point on the pack is being replaced: an old SFZ must not survive
  -- an aborted replacement run.
  if file_exists(plan.sfz_path) then os.remove(plan.sfz_path) end

  self._plan = plan
  self._planned_total = plan.count
  self._running = true
  self._result = {
    patch = plan.patch,
    folder = plan.folder,
    sfz = plan.sfz_path,
    mx_folder = plan.mx_folder,
    count = plan.count,
    plan = plan,
    files = self._files,
    aliases = self._aliases,
  }

  self:_set_state(STATE.PREPARING, {plan = plan})
  self:_emit_progress(0, plan.count, {
    phase = "starting",
    note = plan.notes[1],
    velocity = plan.layers[1] and plan.layers[1].velocity,
  })

  local ok, clock_id_or_err = pcall(self.clock.run, function()
    self:_run_guarded()
  end)
  if not ok then
    self._running = false
    self:_hard_stop_recording()
    return self:_start_error("could not start clock: " .. tostring(clock_id_or_err))
  end
  self._clock_id = clock_id_or_err
  -- norns' clock.run resumes the coroutine immediately, so a failure during
  -- the first capture has already been reported by _fail() at this point.
  if not self._running then
    return false, self._last_error or "could not start sampling run"
  end
  return true
end

function Autosampler:_start_error(message)
  message = tostring(message or "could not start sampler")
  self._last_error = message
  self:_set_state(STATE.ERROR, {phase = "start"})
  self:_emit_callback("on_error", message, {phase = "start"})
  return false, message
end

function Autosampler:_run()
  local plan = self._plan
  self:_set_state(STATE.RECORDING, {plan = plan})
  local completed = 0

  for _, note in ipairs(plan.notes) do
    for _, layer in ipairs(plan.layers) do
      if self._stop_requested then return "cancelled" end
      local index = completed + 1
      self:_emit_progress(completed, plan.count, {
        phase = "recording",
        index = index,
        note = note,
        note_name = Autosampler.note_name(note),
        velocity = layer.velocity,
        vel_low = layer.low,
        vel_high = layer.high,
        file = Autosampler.sample_filename(plan, note, layer),
      })

      local ok, capture_err = self:_capture(plan, note, layer, completed)
      if not ok then
        if self._stop_requested then return "cancelled" end
        error(capture_err or "sample capture failed")
      end
      completed = completed + 1
      self._completed = completed
    end
  end

  if self._stop_requested then return "cancelled" end
  self:_set_state(STATE.GENERATING, {plan = plan})

  -- Buffer writes are asynchronous.  Drain the disk worker first so "complete"
  -- means the samples are fully written, not merely created on disk.
  local writes_ok, writes_err = self:_drain_writes()
  if writes_ok == false then return "cancelled" end
  if writes_ok == nil then error(writes_err or "timed out waiting for disk writes") end

  local files_ok, files_err = self:_wait_for_files(self._files, 5)
  if files_ok == false then return "cancelled" end
  if files_ok == nil then error(files_err or "timed out waiting for sample writes") end

  local sfz, sfz_err = self:_write_sfz(plan)
  if not sfz then error(sfz_err or "could not write SFZ") end

  local aliases_ok, aliases_err = self:_finalize_mx_aliases(plan)
  if aliases_ok == false and self._stop_requested then return "cancelled" end
  if aliases_ok == nil then
    -- Optional convenience pack; the primary .sfz pack is already complete.
    self._mx_errors[#self._mx_errors + 1] = tostring(aliases_err or "mx.samples alias failure")
  end

  -- The new pack is complete; drop samples left by earlier runs with a
  -- different note range or layer count so neither folder mixes generations.
  self:_prune_stale_files(plan)

  self._result.sfz = sfz
  self._result.completed = completed
  self._result.plan = plan
  self._result.mx_complete = self._mx_enabled
    and plan.mx_folder ~= nil
    and (#self._aliases == #self._files)
  self._result.mx_errors = self._mx_errors
  self._running = false
  self:_release_current_note()
  self:_set_state(STATE.COMPLETE, {plan = plan, result = self._result})
  self:_emit_callback("on_complete", self._result)
  return "complete"
end

function Autosampler:_capture(plan, note, layer, completed)
  -- Never rewind the shared buffer while a previous export is still reading it.
  local drained, drain_err = self:_drain_writes()
  if drained == false then return false, "stopped" end
  if drained == nil then return nil, drain_err end

  local ok, err = self:_begin_recording()
  if not ok then return nil, err end

  local channel = plan.midi_channel
  local sent, send_err = self:_note_on(note, layer.velocity, channel)
  if not sent then
    self:_fade_stop_recording()
    return nil, send_err
  end
  self._current_note = {note = note, channel = channel}

  local held = self:_sleep_interruptible(plan.hold_time)
  self:_note_off(note, channel)
  self._current_note = nil
  if not held then
    self:_fade_stop_recording()
    return false, "stopped"
  end

  local tailed = self:_sleep_interruptible(plan.tail_time)
  if not tailed then
    self:_fade_stop_recording()
    return false, "stopped"
  end

  self:_fade_stop_recording()
  if self._stop_requested then return false, "stopped" end

  local export_start, export_duration, trim_err = self:_export_window(plan)
  if not export_start then
    if trim_err == "stopped" then return false, "stopped" end
    export_start, export_duration = plan.export_start, plan.export_duration
  end

  local filename, path
  local export_ok, export_err = pcall(function()
    filename = Autosampler.sample_filename(plan, note, layer)
    path = plan.folder .. filename
    -- Remove a stale sample first so the post-run existence check proves the
    -- new asynchronous write actually happened.
    if file_exists(path) then os.remove(path) end
    if plan.channel_mode == "stereo" then
      self.softcut.buffer_write_stereo(path, export_start, export_duration)
    else
      local channel_index = (plan.channel_mode == "mono_l") and 1 or 2
      self.softcut.buffer_write_mono(path, export_start, export_duration, channel_index)
    end
  end)
  if not export_ok then return nil, "buffer export failed: " .. tostring(export_err) end

  self._write_pending = true
  self._files[#self._files + 1] = path

  self._completed = completed + 1
  self:_emit_progress(completed + 1, plan.count, {
    phase = "exported",
    index = completed + 1,
    note = note,
    note_name = Autosampler.note_name(note),
    velocity = layer.velocity,
    vel_low = layer.low,
    vel_high = layer.high,
    file = filename,
    wav = path,
    export_start = export_start,
    export_duration = export_duration,
  })

  local guarded = self:_sleep_interruptible(plan.guard_interval)
  if not guarded then return false, "stopped" end
  return true
end

function Autosampler:_begin_recording()
  if not self.softcut then return nil, "softcut API unavailable" end
  for _, voice in ipairs(self._active_channels) do
    pcall(self.softcut.rec, voice, 0)
    pcall(self.softcut.play, voice, 0)
    pcall(self.softcut.position, voice, 0)
    pcall(self.softcut.rec_level, voice, 1)
    pcall(self.softcut.pre_level, voice, 0)
    pcall(self.softcut.rec, voice, 1)
  end
  return true
end

function Autosampler:_wait_for_files(paths, timeout)
  local remaining = timeout or 5
  while true do
    local missing = false
    for _, path in ipairs(paths) do
      if not file_exists(path) then missing = true break end
    end
    if not missing then return true end
    if self._stop_requested then return false, "stopped" end
    if remaining <= 0 then return nil, "timed out waiting for WAV writes" end
    local step = math.min(0.05, remaining)
    if self.clock and self.clock.sleep then self.clock.sleep(step) end
    remaining = remaining - step
  end
end

function Autosampler:_finalize_mx_aliases(plan)
  if not self._mx_enabled or not plan.mx_folder then return true end

  local paths = {}
  for _, note in ipairs(plan.notes) do
    for _, layer in ipairs(plan.layers) do
      paths[#paths + 1] = plan.folder .. Autosampler.sample_filename(plan, note, layer)
    end
  end

  local ready, wait_err = self:_wait_for_files(paths, 5)
  if ready == false then return false, wait_err end

  local file_index = 0
  for _, note in ipairs(plan.notes) do
    for _, layer in ipairs(plan.layers) do
      file_index = file_index + 1
      local source = paths[file_index]
      if file_exists(source) then
        local alias = self:_link_mx_sample(source, plan.mx_folder, note, layer.index, plan.vel_layers)
        if alias then
          self._aliases[#self._aliases + 1] = alias
        else
          self._mx_errors[#self._mx_errors + 1] = Autosampler.sample_filename(plan, note, layer)
        end
      else
        self._mx_errors[#self._mx_errors + 1] = Autosampler.sample_filename(plan, note, layer)
      end
    end
  end
  return ready, wait_err
end

function Autosampler:_remove_stale_wavs(folder, keep, matches)
  if not folder or folder == "" then return 0 end
  local removed = 0
  for _, name in ipairs(list_directory(self.util, folder)) do
    if not keep[name] and name:sub(-4):lower() == ".wav" and matches(name) then
      if os.remove(folder .. name) then removed = removed + 1 end
    end
  end
  return removed
end

--- Delete samples from earlier runs that this run did not produce.  The patch
--- folder and mx.samples folder are dedicated to one patch, but a later run
--- with a smaller note range or fewer velocity layers would otherwise leave
--- notes/dynamics behind that mx.samples still indexes.
function Autosampler:_prune_stale_files(plan)
  if not self._prune_stale then return end
  local keep = {}
  for _, path in ipairs(self._files) do keep[basename(path)] = true end
  local prefix = plan.patch .. "_"
  self:_remove_stale_wavs(plan.folder, keep, function(name)
    return name:sub(1, #prefix) == prefix
  end)
  if self._mx_enabled and plan.mx_folder and #self._aliases > 0 then
    local mx_keep = {}
    for _, path in ipairs(self._aliases) do mx_keep[basename(path)] = true end
    self:_remove_stale_wavs(plan.mx_folder, mx_keep, function(name)
      return name:match("^%d+%.%d+%.%d+%.%d+%.%d+%.wav$") ~= nil
    end)
  end
end

function Autosampler:_link_mx_sample(source, mx_folder, note, layer_index, layers)
  local name = string.format("%d.%d.%d.1.0.wav", note, layer_index, layers)
  local destination = mx_folder .. name
  local command = "ln -f " .. shell_quote(source) .. " " .. shell_quote(destination) .. " 2>/dev/null"
  local ok = os.execute(command)
  if (ok == true or ok == 0) and file_exists(destination) then return destination end

  -- Different filesystem (or a restrictive FS) can prevent hardlinks.  A
  -- symlink is still transparent to mx.samples/libsndfile and costs no space.
  command = "ln -sf " .. shell_quote(source) .. " " .. shell_quote(destination) .. " 2>/dev/null"
  ok = os.execute(command)
  if (ok == true or ok == 0) and file_exists(destination) then return destination end
  return nil
end

function Autosampler:_write_sfz(plan)
  local contents = Autosampler.make_sfz(plan)
  local ok, err = write_file(plan.sfz_path, contents)
  if not ok then return nil, "could not write SFZ: " .. tostring(err) end
  return plan.sfz_path
end

function Autosampler:_fail(message)
  self._running = false
  self._stop_requested = false
  self:_restore_render_callback()
  self:_release_current_note()
  self:_hard_stop_recording()
  self._last_error = tostring(message or "unknown error")
  self:_set_state(STATE.ERROR)
  self:_emit_callback("on_error", self._last_error, {phase = "run"})
end

function Autosampler:_cancelled()
  self._running = false
  self._stop_requested = false
  self:_restore_render_callback()
  self:_release_current_note()
  self:_hard_stop_recording()
  self:_set_state(STATE.CANCELLED)
end

function Autosampler:_run_guarded()
  local ok, result_or_error = xpcall(function()
    return self:_run()
  end, function(err)
    return tostring(err) .. "\n" .. debug.traceback("", 2)
  end)

  if not ok then
    self:_fail(result_or_error)
  elseif result_or_error == "cancelled" then
    self:_cancelled()
  end
end

--- Request a graceful, abort-safe stop.  The active clock coroutine tears
--- down recording at its next 50 ms checkpoint.
function Autosampler:stop()
  if self._test then self:_stop_test() end
  if not self._running then return false, "sampler is not running" end
  if self._stop_requested then return true end
  self._stop_requested = true
  self:_release_current_note()
  self:_set_state(STATE.STOPPING)
  return true
end

function Autosampler:_stop_test()
  if self._test then
    local test = self._test
    self._test = nil
    self:_note_off(test.note, test.channel)
  end
  if self._test_clock and self.clock and type(self.clock.cancel) == "function" then
    pcall(self.clock.cancel, self._test_clock)
  end
  self._test_clock = nil
end

--- Send a test note without starting/stopping the sampler.  The default
--- velocity is the highest configured velocity-layer trigger, and the default
--- duration is hold time.  Input peaks/RMS are live through get_meters().
function Autosampler:trigger_test(note, velocity, duration)
  if self._running then return false, "cannot test while sampling" end
  if not self._initialized then
    local ok, err = self:init()
    if not ok then return false, err end
  end
  if not self.clock or type(self.clock.run) ~= "function" or type(self.clock.sleep) ~= "function" then
    return false, "clock API unavailable"
  end

  note = round_int(note, 60)
  if note < 0 or note > 127 then return false, "test note must be 0-127" end
  local layers = Autosampler.velocity_regions(self:_param(P.VEL_LAYERS, self.settings.vel_layers))
  velocity = round_int(velocity, layers[#layers].velocity)
  if velocity < 1 or velocity > 127 then return false, "test velocity must be 1-127" end
  duration = tonumber(duration) or tonumber(self:_param(P.HOLD_TIME, self.settings.hold_time)) or 2
  if duration <= 0 or duration > Autosampler.MAX_CAPTURE_SECONDS then
    return false, "test duration must be greater than zero and at most 300 seconds"
  end

  local device = round_int(self:_param(P.MIDI_DEVICE, self.settings.midi_device), 1)
  if device < 1 or device > 16 then return false, "MIDI output must be 1-16" end
  local port, err = self:_connect_midi(device)
  if not port then return false, err end
  local channel = round_int(self:_param(P.MIDI_CHANNEL, self.settings.midi_channel), 1)
  if channel < 1 or channel > 16 then return false, "MIDI channel must be 1-16" end

  self:_stop_test()
  self:reset_meters()
  local sent, send_err = self:_note_on(note, velocity, channel)
  if not sent then return false, send_err end
  self._test = {note = note, channel = channel, velocity = velocity}

  self._test_clock = self.clock.run(function()
    local ok, sleep_err = pcall(function() self.clock.sleep(duration) end)
    local test = self._test
    if test and test.note == note and test.channel == channel then
      self:_note_off(note, channel)
      self._test = nil
      self._test_clock = nil
    end
    if not ok then
      self:_emit_callback("on_error", "test note scheduling failed: " .. tostring(sleep_err), {phase = "test"})
    end
  end)
  return true
end

--- Cleanly restore host state.  Safe to call more than once.
function Autosampler:cleanup()
  if self._cleaned then return true end
  self._cleaned = true

  self:_stop_test()
  self:_restore_render_callback()
  if self._running then
    self._stop_requested = true
    self:_release_current_note()
    self:_hard_stop_recording()
    if self._clock_id and self.clock and type(self.clock.cancel) == "function" then
      pcall(self.clock.cancel, self._clock_id)
    end
    self._running = false
  else
    self:_release_current_note()
  end
  self:_all_notes_off()
  self:_stop_metering()
  self:_restore_audio()
  self:_restore_softcut()

  self._initialized = false
  self._clock_id = nil
  self._midi_port = nil
  return true
end

return Autosampler
