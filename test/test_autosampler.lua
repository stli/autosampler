-- Self-contained norns API mocks and behavioural tests for lib/autosampler.lua.
-- Run from anywhere with: lua test/test_autosampler.lua

local script_dir = arg[0]:match("^(.*)[/\\]") or "."
local lib_path = script_dir .. "/../lib/autosampler.lua"
local Autosampler = dofile(lib_path)

local checks = 0
local function check(condition, message)
  checks = checks + 1
  if not condition then error("FAIL: " .. message, 2) end
end

local function approx(a, b, epsilon)
  return math.abs((a or 0) - (b or 0)) <= (epsilon or 1e-6)
end

local function dbamp(db)
  if db == -math.huge then return 0 end
  return 10 ^ (db / 20)
end

----------------------------------------------------------------------------
-- scheduler / clock mock
----------------------------------------------------------------------------
local scheduler = {threads = {}, next_id = 1, sleeps = 0, sleep_total = 0}
local clock_api = {}
local render_pump = nil -- installed by the softcut mock; simulates event delivery

function clock_api.run(fn, ...)
  local id = scheduler.next_id
  scheduler.next_id = id + 1
  local co = coroutine.create(fn)
  scheduler.threads[id] = co
  local ok, err = coroutine.resume(co, ...)
  if not ok then error(err, 0) end
  if coroutine.status(co) == "dead" then scheduler.threads[id] = nil end
  return id
end

function clock_api.sleep(seconds)
  seconds = tonumber(seconds) or 0
  scheduler.sleeps = scheduler.sleeps + 1
  scheduler.sleep_total = scheduler.sleep_total + seconds
  -- Model the norns main loop: queued render callbacks are delivered while a
  -- clock coroutine is suspended.
  if render_pump then render_pump() end
  return coroutine.yield(seconds)
end

function clock_api.cancel(id)
  scheduler.threads[id] = nil
end

function scheduler.drain(limit)
  limit = limit or 20000
  local iterations = 0
  while true do
    local ids = {}
    for id in pairs(scheduler.threads) do ids[#ids + 1] = id end
    if #ids == 0 then return end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local co = scheduler.threads[id]
      if co and coroutine.status(co) == "suspended" then
        local ok, err = coroutine.resume(co)
        if not ok then error("scheduler error: " .. tostring(err), 0) end
        if coroutine.status(co) == "dead" then scheduler.threads[id] = nil end
      end
    end
    iterations = iterations + 1
    if iterations > limit then error("scheduler did not become idle") end
  end
end

----------------------------------------------------------------------------
-- params / controlspec mock
----------------------------------------------------------------------------
local params_api = {items = {}, order = {}, saved = {}}

local function add_basic(id, name, kind, value)
  params_api.items[id] = {id = id, name = name, kind = kind, value = value, action = function() end}
  params_api.order[#params_api.order + 1] = id
end

function params_api:add_group(group_id, name, count)
  add_basic(group_id, name, "group", nil)
end

function params_api:add_number(id, name, min, max, default)
  add_basic(id, name, "number", default)
  local item = self.items[id]
  item.min, item.max = min, max
end

function params_api:add_control(id, name, controlspec)
  add_basic(id, name, "control", controlspec.default)
end

function params_api:add_option(id, name, options, default)
  add_basic(id, name, "option", default)
  self.items[id].options = options
end

function params_api:add_text(id, name, text)
  add_basic(id, name, "text", text)
end

function params_api:set_action(id, fn)
  local item = self.items[id]
  if not item then error("no param " .. id) end
  item.action = fn
end

function params_api:get(id)
  local item = self.items[id]
  if not item then error("no param " .. id) end
  return item.value
end

function params_api:set(id, value, silent)
  local item = self.items[id]
  if not item then error("no param " .. id) end
  if item.kind == "number" then
    if value < item.min then value = item.min end
    if value > item.max then value = item.max end
  end
  item.value = value
  if not silent then item.action(value) end
end

function params_api:lookup_param(id)
  return self.items[id]
end

local controlspec_api = {}
function controlspec_api.new(min, max, warp, step, default, units, quantum)
  return {min = min, max = max, warp = warp, step = step, default = default, units = units, quantum = quantum}
end

----------------------------------------------------------------------------
-- audio mock
----------------------------------------------------------------------------
local audio_api = {levels = {
  monitor = 0, adc_cut = 0, eng_cut = 1, tape_cut = 0,
}}
function audio_api.level_monitor(value) audio_api.levels.monitor = value end
function audio_api.level_adc_cut(value) audio_api.levels.adc_cut = value end
function audio_api.level_eng_cut(value) audio_api.levels.eng_cut = value end
function audio_api.level_tape_cut(value) audio_api.levels.tape_cut = value end

-- Install the core LEVELS / SOFTCUT params that the library expects to exist.
add_basic("monitor_level", "monitor", "control", -12)
add_basic("cut_input_adc", "input adc", "control", 0)
add_basic("cut_input_eng", "input engine", "control", 0)
add_basic("cut_input_tape", "input tape", "control", -math.huge)
params_api:set_action("monitor_level", function(value) audio_api.level_monitor(dbamp(value)) end)
params_api:set_action("cut_input_adc", function(value) audio_api.level_adc_cut(dbamp(value)) end)
params_api:set_action("cut_input_eng", function(value) audio_api.level_eng_cut(dbamp(value)) end)
params_api:set_action("cut_input_tape", function(value) audio_api.level_tape_cut(dbamp(value)) end)
audio_api.level_monitor(dbamp(-12))
audio_api.level_adc_cut(dbamp(0))
audio_api.level_eng_cut(dbamp(0))
audio_api.level_tape_cut(dbamp(-math.huge))

----------------------------------------------------------------------------
-- softcut mock
----------------------------------------------------------------------------
local softcut_api = {calls = {}, writes = {}}
local function softcut_call(name, ...)
  local args = {...}
  softcut_api.calls[#softcut_api.calls + 1] = {name = name, args = args, n = #args, a = args[1], b = args[2], c = args[3]}
end

local function add_setter(name)
  softcut_api[name] = function(...) softcut_call(name, ...) end
end

for _, name in ipairs({
  "buffer", "enable", "play", "rec", "position", "rec_level", "pre_level",
  "loop_start", "loop_end", "loop", "level_input_cut", "level", "pan", "rate",
  "fade_time", "level_slew_time", "recpre_slew_time", "rec_offset",
  "level_cut_cut",
}) do add_setter(name) end

local function default_voice_state(voice)
  return {
    enable = 0, play = 0, rate = 1, loop_start = (voice - 1) * 2, loop_end = (voice - 1) * 2 + 1,
    loop = 1, fade_time = 0.0005, rec_level = 0, pre_level = 0, rec = 0, record = 0,
    rec_offset = -0.00015, position = 0, buffer = (voice % 2) + 1, level = 0, pan = 0,
    level_input_cut = {0, 0}, level_cut_cut = {0, 0, 0, 0, 0, 0},
    level_slew_time = 0.001, pan_slew_time = 0.001, recpre_slew_time = 0.001,
    rate_slew_time = 0.001, pre_filter_fc = 16000, pre_filter_fc_mod = 1,
    pre_filter_rq = 4, pre_filter_lp = 1, pre_filter_hp = 0, pre_filter_bp = 0,
    pre_filter_br = 0, pre_filter_dry = 0, post_filter_fc = 12000,
    post_filter_rq = 4, post_filter_lp = 0, post_filter_hp = 0,
    post_filter_bp = 0, post_filter_br = 0, post_filter_dry = 1,
  }
end

function softcut_api.defaults()
  local defaults = {}
  for voice = 1, 6 do defaults[voice] = default_voice_state(voice) end
  return defaults
end

local function write_mock_wav(path, channels)
  local file = assert(io.open(path, "wb"))
  file:write("RIFF", string.rep("\0", 36), string.rep("\1", 32 * channels))
  file:close()
end

function softcut_api.buffer_write_stereo(path, start_time, duration)
  softcut_call("buffer_write_stereo", path, start_time, duration)
  softcut_api.writes[#softcut_api.writes + 1] = {path = path, start = start_time, duration = duration, channels = 2}
  write_mock_wav(path, 2)
end

softcut_api.render_callback = nil
softcut_api.render_onset = nil
softcut_api.async_render = false
softcut_api.render_requests = 0
softcut_api.pending_renders = {}
function softcut_api.event_render(fn)
  softcut_api.render_callback = fn
end
local function deliver_render(request)
  local sec_per_sample = request.duration / request.samples
  local values = {}
  for i = 1, request.samples do
    local t = request.start + (i - 1) * sec_per_sample
    values[i] = (softcut_api.render_onset and t >= softcut_api.render_onset) and 0.25 or 0
  end
  if softcut_api.render_callback then
    softcut_api.render_callback(request.channel, request.start, sec_per_sample, values)
  end
end
softcut_api.deliver_render = deliver_render
function softcut_api.render_buffer(channel, start_time, duration, samples)
  softcut_api.render_requests = softcut_api.render_requests + 1
  local request = {channel = channel, start = start_time, duration = duration, samples = samples}
  if softcut_api.async_render then
    softcut_api.pending_renders[#softcut_api.pending_renders + 1] = request
  else
    deliver_render(request)
  end
end
render_pump = function()
  if softcut_api.async_render and #softcut_api.pending_renders > 0 then
    local request = table.remove(softcut_api.pending_renders, 1)
    deliver_render(request)
  end
end

function softcut_api.buffer_write_mono(path, start_time, duration, channel)
  softcut_call("buffer_write_mono", path, start_time, duration, channel)
  softcut_api.writes[#softcut_api.writes + 1] = {
    path = path, start = start_time, duration = duration, channels = 1, channel = channel,
  }
  write_mock_wav(path, 1)
end

----------------------------------------------------------------------------
-- MIDI mock
----------------------------------------------------------------------------
local midi_api = {messages = {}}
local midi_port = {name = "Mock MIDI", device = true}
function midi_port:note_on(note, velocity, channel)
  midi_api.messages[#midi_api.messages + 1] = {kind = "on", note = note, velocity = velocity, channel = channel}
end
function midi_port:note_off(note, velocity, channel)
  midi_api.messages[#midi_api.messages + 1] = {kind = "off", note = note, velocity = velocity, channel = channel}
end
function midi_port:cc(cc, value, channel)
  midi_api.messages[#midi_api.messages + 1] = {kind = "cc", cc = cc, value = value, channel = channel}
end
function midi_api.connect(device)
  midi_api.last_device = device
  return midi_port
end

----------------------------------------------------------------------------
-- poll mock
----------------------------------------------------------------------------
local poll_api = {polls = {}}
local function poll_object(name, id)
  return {
    props = {name = name, id = id, callback = nil, time = 0.1},
    running = false,
    start = function(self) self.running = true end,
    stop = function(self) self.running = false end,
  }
end
poll_api.polls.amp_in_l = poll_object("amp_in_l", 1)
poll_api.polls.amp_in_r = poll_object("amp_in_r", 2)
function poll_api.set(name, callback)
  local poll = poll_api.polls[name]
  if poll then poll.props.callback = callback end
  return poll
end

----------------------------------------------------------------------------
-- util / norns / path mocks
----------------------------------------------------------------------------
local test_root = "/tmp/autosampler-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000))
os.execute("rm -rf " .. test_root)
assert(os.execute("mkdir -p " .. test_root) == true or true)

local util_api = {}
function util_api.make_dir(path) os.execute("mkdir -p '" .. path .. "'") end
function util_api.trim_string_to_width(text) return text end

local norns_api = {disk = 100000, state = {mix = {
  monitor = -12, cut_input_adc = 0, cut_input_eng = 0, cut_input_tape = -math.huge,
}}}

local path_api = {audio = test_root .. "/audio/"}

----------------------------------------------------------------------------
-- static/pure API tests
----------------------------------------------------------------------------
do
  local values = Autosampler.velocity_values(4)
  check(#values == 4, "four velocity layers")
  check(values[1] == 26 and values[2] == 51 and values[3] == 77 and values[4] == 102,
    "velocity linspace values, got " .. table.concat(values, ","))
  local regions = Autosampler.velocity_regions(2)
  check(regions[1].low == 1 and regions[1].high == 64, "first velocity range")
  check(regions[2].low == 65 and regions[2].high == 127, "second velocity range")
  check(regions[1].velocity == 43 and regions[2].velocity == 85, "two-layer triggers")
  check(Autosampler.note_name(60) == "C4", "C4 note name")
  check(Autosampler.note_name(61) == "C#4", "C#4 note name")

  local plan, err = Autosampler.make_plan({
    low_note = 60, high_note = 62, note_step = 2, vel_layers = 2,
    hold_time = 0.1, tail_time = 0.05, guard_interval = 0.02,
    latency_offset_ms = 10, record_mode = "stereo", patch_name = "Test Patch",
  })
  check(plan, "plan built: " .. tostring(err))
  check(plan.patch == "Test_Patch", "patch sanitized")
  check(#plan.notes == 2 and plan.notes[1] == 60 and plan.notes[2] == 62, "step notes")
  check(plan.count == 4, "plan count")
  check(approx(plan.export_start, 0.01), "export start")
  check(approx(plan.export_duration, 0.14), "export duration")

  local name = Autosampler.sample_filename(plan, 60, plan.layers[2])
  check(name == "Test_Patch_60_C4_v65-127.wav", "sample filename: " .. name)
  local sfz = Autosampler.make_sfz(plan)
  check(sfz:find("<region>", 1, true) ~= nil, "sfz has regions")
  check(sfz:find("Test_Patch_60_C4_v65-127.wav", 1, true) ~= nil, "sfz references sample")
  check(sfz:find("pitch_keycenter=60", 1, true) ~= nil, "sfz key center")
  check(sfz:find("lovel=65 hivel=127", 1, true) ~= nil, "sfz velocity range")

  local bad, bad_err = Autosampler.make_plan({
    low_note = 60, high_note = 61, hold_time = 200, tail_time = 101,
  })
  check(bad == nil and bad_err:match("300"), "duration budget rejected")
  local bad2 = Autosampler.make_plan({low_note = 64, high_note = 60})
  check(bad2 == nil, "inverted note range rejected")
end

do
  local dated = Autosampler.new({})
  check(dated.settings.patch_name == os.date("patch-%Y%m%d"), "date-based default patch name")
end

----------------------------------------------------------------------------
-- instance integration test
----------------------------------------------------------------------------
local callbacks = {states = {}, progress = {}, complete = {}, errors = {}}
local sampler = Autosampler.new({
  softcut = softcut_api,
  audio = audio_api,
  midi = midi_api,
  clock = clock_api,
  params = params_api,
  poll = poll_api,
  util = util_api,
  norns = norns_api,
  path = path_api,
  controlspec = controlspec_api,
  disk_free_mb = 100000,
  callbacks = {
    on_state_change = function(state, previous) callbacks.states[#callbacks.states + 1] = {state, previous} end,
    on_progress = function(done, total, info) callbacks.progress[#callbacks.progress + 1] = {done, total, info} end,
    on_complete = function(result) callbacks.complete[#callbacks.complete + 1] = result end,
    on_error = function(message, context) callbacks.errors[#callbacks.errors + 1] = {message, context} end,
  },
})

local ok, err = sampler:add_params()
check(ok, "add params: " .. tostring(err))
params_api:set("midi_device", 1)
params_api:set("midi_channel", 3)
params_api:set("low_note", 60)
params_api:set("high_note", 62)
params_api:set("note_step", 2)
params_api:set("vel_layers", 2)
params_api:set("hold_time", 0.1)
params_api:set("tail_time", 0.05)
params_api:set("guard_interval", 0.02)
params_api:set("latency_offset_ms", 10)
params_api:set("record_mode", 1)
params_api:set("patch_name", "Test Patch")

check(sampler:init(), "sampler init")
check(sampler:get_state() == "idle", "idle after init")
check(approx(audio_api.levels.monitor, 1), "monitoring enabled at init")
check(poll_api.polls.amp_in_l.props.callback ~= nil, "input poll installed")
poll_api.polls.amp_in_l.props.callback(0.5)
poll_api.polls.amp_in_r.props.callback(0.25)
local meters = sampler:get_meters()
check(approx(meters.db_l, -6.0206, 0.001), "left dB meter: " .. tostring(meters.db_l))
check(approx(meters.db_r, -12.0412, 0.001), "right dB meter: " .. tostring(meters.db_r))
check(approx(meters.peak_l, 0.5), "left peak hold")

-- Test trigger defaults to middle C and the highest configured velocity (85).
midi_api.messages = {}
scheduler.sleeps = 0
local tested, test_err = sampler:trigger_test()
check(tested, "test trigger: " .. tostring(test_err))
check(sampler:is_testing(), "test active")
scheduler.drain()
check(not sampler:is_testing(), "test finished")
check(midi_api.messages[1] and midi_api.messages[1].kind == "on", "test note on")
check(midi_api.messages[1].note == 60 and midi_api.messages[1].velocity == 85,
  "test defaults to C4/max velocity")
check(midi_api.messages[2] and midi_api.messages[2].kind == "off", "test note off")

-- Start the full run.
midi_api.messages = {}
softcut_api.writes = {}
softcut_api.calls = {}
scheduler.sleeps = 0
local started, start_err = sampler:start()
check(started, "start: " .. tostring(start_err))
check(sampler:is_running(), "running")
local blocked, blocked_err = sampler:trigger_test()
check(not blocked and blocked_err:match("sampling"), "test blocked while sampling")
scheduler.drain()

check(sampler:get_state() == "complete", "complete state, got " .. sampler:get_state())
check(#callbacks.complete == 1, "one on_complete callback")
check(#callbacks.errors == 0, "no errors during run: " .. tostring(callbacks.errors[1] and callbacks.errors[1][1]))
local result = callbacks.complete[1]
check(result.count == 4, "result count")
check(result.completed == 4, "completed count")
check(#softcut_api.writes == 4, "four WAV exports, got " .. #softcut_api.writes)
check(#result.files == 4, "four files")
check(#result.aliases == 4, "four mx.samples aliases")
check(result.mx_complete == true, "mx pack complete")
for _, call in ipairs(softcut_api.writes) do
  check(call.channels == 2, "stereo export")
  check(approx(call.start, 0.01), "latency trim start")
  check(approx(call.duration, 0.14), "latency trim duration")
  check(io.open(call.path, "rb") ~= nil, "wav exists")
end

local expected = {
  "Test_Patch_60_C4_v1-64.wav",
  "Test_Patch_60_C4_v65-127.wav",
  "Test_Patch_62_D4_v1-64.wav",
  "Test_Patch_62_D4_v65-127.wav",
}
for i, name in ipairs(expected) do
  local path = result.folder .. name
  check(result.files[i] == path, "filename " .. i .. ": " .. tostring(result.files[i]))
  check(io.open(path, "rb") ~= nil, "primary wav " .. path)
end

check(io.open(result.sfz, "rb") ~= nil, "SFZ exists")
local sfz_file = assert(io.open(result.sfz, "rb"))
local sfz_text = sfz_file:read("*a")
sfz_file:close()
check(select(2, sfz_text:gsub("<region>", "")) == 4, "four SFZ regions")
check(sfz_text:find("lokey=60 hikey=61", 1, true) ~= nil, "SFZ stretched first key range")
check(sfz_text:find("lokey=62 hikey=62", 1, true) ~= nil, "SFZ last key range")

check(result.mx_folder ~= nil, "mx folder")
for _, alias_name in ipairs({"60.1.2.1.0.wav", "60.2.2.1.0.wav", "62.1.2.1.0.wav", "62.2.2.1.0.wav"}) do
  check(io.open(result.mx_folder .. alias_name, "rb") ~= nil, "mx alias " .. alias_name)
end

-- MIDI sequence / velocities.
local ons, offs = {}, {}
for _, msg in ipairs(midi_api.messages) do
  if msg.kind == "on" then ons[#ons + 1] = msg end
  if msg.kind == "off" then offs[#offs + 1] = msg end
end
check(#ons == 4 and #offs == 4, "four on + four off MIDI messages")
check(ons[1].note == 60 and ons[1].velocity == 43 and ons[1].channel == 3, "first MIDI note/velocity/channel")
check(ons[2].note == 60 and ons[2].velocity == 85, "second MIDI velocity layer")
check(ons[3].note == 62 and ons[3].velocity == 43, "third MIDI note")
check(ons[4].note == 62 and ons[4].velocity == 85, "fourth MIDI note")

-- Capture routing and monitor state before cleanup.
check(approx(audio_api.levels.monitor, 1), "monitor stays on after run")
check(approx(audio_api.levels.adc_cut, 1), "ADC only into softcut")
check(approx(audio_api.levels.eng_cut, 0), "engine feed muted")
check(approx(audio_api.levels.tape_cut, 0), "tape feed muted")
local saw_left, saw_right = false, false
local bad_feedback = false
for _, call in ipairs(softcut_api.calls) do
  if call.name == "level_input_cut" then
    if call.a == 1 and call.b == 1 and call.c == 1 then saw_left = true end
    if call.a == 2 and call.b == 2 and call.c == 1 then saw_right = true end
  end
  if call.name == "level_cut_cut" and call.c ~= 0 then bad_feedback = true end
  if call.name == "play" and call.b == 1 then error("softcut playback enabled during capture") end
end
check(saw_left and saw_right, "stereo ADC routed L/R")
check(not bad_feedback, "no softcut feedback routes")
check(scheduler.sleeps > 0, "clock sleeps used")

-- Start/stop abort path.
check(sampler:stop() == false, "stop while idle is a no-op")
local restarted = sampler:start()
check(restarted, "restart for cancellation")
sampler:stop()
scheduler.drain()
check(sampler:get_state() == "cancelled", "cancelled state, got " .. sampler:get_state())
check(#callbacks.complete == 1, "cancel does not call on_complete")
check(#callbacks.errors == 0, "cancel is not an error")

-- Cleanup restores audio and softcut host state.
sampler:cleanup()
check(approx(audio_api.levels.monitor, dbamp(-12), 1e-5), "monitor restored")
check(approx(audio_api.levels.eng_cut, 1), "engine feed restored")
check(approx(audio_api.levels.tape_cut, 0), "tape feed restored")
local restored_rec = false
for i = #softcut_api.calls, 1, -1 do
  local call = softcut_api.calls[i]
  if call.name == "rec" and call.b == 0 then restored_rec = true break end
end
check(restored_rec, "softcut write heads closed on cleanup")

-- Mono R path: route ADC channel 2 to softcut voice/buffer 2 and export mono.
softcut_api.writes = {}
softcut_api.calls = {}
midi_api.messages = {}
local mono_errors = {}
local mono = Autosampler.new({
  softcut = softcut_api, audio = audio_api, midi = midi_api, clock = clock_api,
  params = params_api, poll = poll_api, util = util_api, norns = norns_api,
  path = path_api, controlspec = controlspec_api, disk_free_mb = 100000,
  callbacks = {on_error = function(message) mono_errors[#mono_errors + 1] = message end},
})
assert(mono:add_params())
params_api:set("low_note", 60)
params_api:set("high_note", 60)
params_api:set("note_step", 1)
params_api:set("vel_layers", 1)
params_api:set("hold_time", 0.06)
params_api:set("tail_time", 0.02)
params_api:set("guard_interval", 0)
params_api:set("latency_offset_ms", 0)
params_api:set("record_mode", 3)
params_api:set("patch_name", "Mono R")
check(mono:init())
local mono_started, mono_start_err = mono:start()
check(mono_started, "mono start: " .. tostring(mono_start_err))
scheduler.drain()
check(mono:get_state() == "complete", "mono complete")
check(#mono_errors == 0, "no mono errors")
check(#softcut_api.writes == 1, "one mono export")
check(softcut_api.writes[1].channels == 1 and softcut_api.writes[1].channel == 2,
  "mono R uses buffer channel 2")
check(softcut_api.writes[1].path:match("Mono_R_60_C4_v1%-127%.wav$") ~= nil, "mono filename")
local saw_r_input = false
for _, call in ipairs(softcut_api.calls) do
  if call.name == "level_input_cut" and call.a == 2 and call.b == 2 and call.c == 1 then
    saw_r_input = true
  end
end
check(saw_r_input, "mono R ADC routing")
mono:cleanup()

-- Auto-trim finds the first sustained signal and exports from just before it.
softcut_api.writes = {}
softcut_api.calls = {}
softcut_api.render_onset = 0.06
local trim_sampler = Autosampler.new({
  softcut = softcut_api, audio = audio_api, midi = midi_api, clock = clock_api,
  params = params_api, poll = poll_api, util = util_api, norns = norns_api,
  path = path_api, controlspec = controlspec_api, disk_free_mb = 100000,
})
assert(trim_sampler:add_params())
params_api:set("low_note", 60)
params_api:set("high_note", 60)
params_api:set("note_step", 1)
params_api:set("vel_layers", 1)
params_api:set("hold_time", 0.12)
params_api:set("tail_time", 0)
params_api:set("guard_interval", 0)
params_api:set("latency_offset_ms", 0)
params_api:set("record_mode", 1)
params_api:set("patch_name", "Trim Test")
check(trim_sampler:init())
local trim_started, trim_err = trim_sampler:start()
check(trim_started, "auto-trim start: " .. tostring(trim_err))
scheduler.drain()
check(trim_sampler:get_state() == "complete", "auto-trim run complete")
check(#softcut_api.writes == 1, "auto-trim one export")
local trimmed = softcut_api.writes[1]
check(trimmed.start > 0.052 and trimmed.start < 0.058,
  "auto-trim start near 55ms, got " .. tostring(trimmed.start))
check(approx(trimmed.duration, 0.12 - trimmed.start, 0.0001), "auto-trim shortens duration")
trim_sampler:cleanup()
softcut_api.render_onset = nil

-- Disk-space guard rejects an impossible run before note events.
local old_disk = norns_api.disk
norns_api.disk = 0
local disk_errors = {}
local disk_sampler = Autosampler.new({
  softcut = softcut_api, audio = audio_api, midi = midi_api, clock = clock_api,
  params = params_api, poll = poll_api, util = util_api, norns = norns_api,
  path = path_api, controlspec = controlspec_api,
  callbacks = {on_error = function(message) disk_errors[#disk_errors + 1] = message end},
})
assert(disk_sampler:add_params())
params_api:set("low_note", 60)
params_api:set("high_note", 60)
params_api:set("hold_time", 0.1)
params_api:set("tail_time", 0)
params_api:set("guard_interval", 0)
params_api:set("vel_layers", 1)
params_api:set("record_mode", 1)
params_api:set("patch_name", "No Disk")
check(disk_sampler:init())
local disk_started, disk_start_err = disk_sampler:start()
check(not disk_started and disk_start_err:match("disk space"), "disk space rejected")
check(#disk_errors == 1 and disk_errors[1]:match("disk space"), "disk on_error callback")
check(not disk_sampler:is_running(), "disk failure did not enter running state")
check(disk_sampler:get_state() == "error", "failed start enters error state")
disk_sampler:cleanup()
norns_api.disk = old_disk

-- UI file must remain presentation-only.
local ui_file = assert(io.open(script_dir .. "/../autosampler.lua", "rb"))
local ui_text = ui_file:read("*a")
ui_file:close()
check(ui_text:find("include(\"lib/autosampler\")", 1, true) ~= nil, "UI includes library")
check(ui_text:find("screen.clear", 1, true) ~= nil, "UI owns screen drawing")
local lib_file = assert(io.open(lib_path, "rb"))
local lib_text = lib_file:read("*a")
lib_file:close()
check(lib_text:find("screen.", 1, true) == nil, "library has no screen calls")
check(lib_text:find("buffer_write_stereo", 1, true) ~= nil, "library exports stereo")
check(lib_text:find("buffer_write_mono", 1, true) ~= nil, "library exports mono")

----------------------------------------------------------------------------
-- regression tests for review fixes
----------------------------------------------------------------------------
local function make_test_sampler(options)
  local opts = {
    softcut = softcut_api, audio = audio_api, midi = midi_api, clock = clock_api,
    params = params_api, poll = poll_api, util = util_api, norns = norns_api,
    path = path_api, controlspec = controlspec_api, disk_free_mb = 100000,
  }
  for key, value in pairs(options or {}) do opts[key] = value end
  return Autosampler.new(opts)
end

local function count_wavs(dir)
  if not dir then return 0 end
  local handle = io.popen("ls -1 '" .. dir .. "' 2>/dev/null")
  if not handle then return 0 end
  local output = handle:read("*a")
  handle:close()
  local n = 0
  for name in output:gmatch("[^\r\n]+") do
    if name:sub(-4):lower() == ".wav" then n = n + 1 end
  end
  return n
end

-- Stale samples from an earlier configuration are pruned from both packs.
do
  softcut_api.writes = {}
  softcut_api.calls = {}
  softcut_api.render_onset = nil
  midi_api.messages = {}
  local s = make_test_sampler()
  assert(s:add_params())
  params_api:set("low_note", 60)
  params_api:set("high_note", 61)
  params_api:set("note_step", 1)
  params_api:set("vel_layers", 2)
  params_api:set("hold_time", 0.06)
  params_api:set("tail_time", 0.02)
  params_api:set("guard_interval", 0)
  params_api:set("latency_offset_ms", 0)
  params_api:set("record_mode", 1)
  params_api:set("patch_name", "Prune Test")
  assert(s:init())
  assert(s:start())
  scheduler.drain()
  check(s:get_state() == "complete", "prune run 1 complete")
  local first = s:get_result()
  check(count_wavs(first.folder) == 4,
    "primary pack run1 count, got " .. count_wavs(first.folder))
  check(count_wavs(first.mx_folder) == 4,
    "mx pack run1 count, got " .. count_wavs(first.mx_folder))

  local primary_note = first.folder .. "keep-me.txt"
  local mx_note = first.mx_folder .. "keep-me.txt"
  for _, path in ipairs({primary_note, mx_note}) do
    local file = assert(io.open(path, "wb"))
    file:write("sentinel")
    file:close()
  end

  params_api:set("high_note", 60)
  params_api:set("vel_layers", 1)
  assert(s:start())
  scheduler.drain()
  check(s:get_state() == "complete", "prune run 2 complete")
  local second = s:get_result()
  check(#second.files == 1, "prune run2 file count")
  check(count_wavs(second.folder) == 1,
    "primary pack pruned, got " .. count_wavs(second.folder))
  check(count_wavs(second.mx_folder) == 1,
    "mx pack pruned, got " .. count_wavs(second.mx_folder))
  check(io.open(second.sfz, "rb") ~= nil, "sfz survives pruning")
  check(io.open(primary_note, "rb") ~= nil, "non-sample file in pack survives pruning")
  check(io.open(mx_note, "rb") ~= nil, "non-sample file in mx pack survives pruning")
  s:cleanup()
end

-- Metering restores the host callback and rate; an unset rate returns to the
-- norns default instead of leaking the metering rate.
do
  local before = function() end
  poll_api.polls.amp_in_l.props.callback = before
  poll_api.polls.amp_in_l.props.time = nil
  poll_api.polls.amp_in_l.time = nil
  poll_api.polls.amp_in_r.props.callback = before
  poll_api.polls.amp_in_r.props.time = 0.25
  poll_api.polls.amp_in_r.time = 0.25

  local s = make_test_sampler()
  assert(s:add_params())
  assert(s:init())
  check(poll_api.polls.amp_in_l.props.callback ~= before, "poll callback installed")
  check(poll_api.polls.amp_in_l.time == 0.05, "metering poll rate applied")
  s:cleanup()
  check(poll_api.polls.amp_in_l.props.callback == before, "poll callback restored")
  check(poll_api.polls.amp_in_l.time == 0.1, "unset poll rate restored to default")
  check(poll_api.polls.amp_in_r.time == 0.25, "explicit poll rate restored")

  poll_api.polls.amp_in_l.props.callback = nil
  poll_api.polls.amp_in_l.time = nil
  poll_api.polls.amp_in_r.props.callback = nil
  poll_api.polls.amp_in_r.time = nil
  poll_api.polls.amp_in_r.props.time = 0.1
end

-- A detected onset wins over a larger configured latency offset.
do
  softcut_api.writes = {}
  softcut_api.render_onset = 0.02
  local s = make_test_sampler()
  assert(s:add_params())
  params_api:set("low_note", 60)
  params_api:set("high_note", 60)
  params_api:set("note_step", 1)
  params_api:set("vel_layers", 1)
  params_api:set("hold_time", 0.12)
  params_api:set("tail_time", 0)
  params_api:set("guard_interval", 0)
  params_api:set("latency_offset_ms", 30)
  params_api:set("record_mode", 1)
  params_api:set("patch_name", "Onset Wins")
  assert(s:init())
  assert(s:start())
  scheduler.drain()
  check(s:get_state() == "complete", "onset-wins complete")
  check(#softcut_api.writes == 1, "onset-wins one export")
  local start = softcut_api.writes[1].start
  check(start < 0.02, "onset before latency offset used, got " .. tostring(start))
  check(approx(start, 0.01495, 0.0002), "onset-wins start near 15 ms, got " .. tostring(start))
  check(approx(softcut_api.writes[1].duration, 0.12 - start, 0.0001),
    "onset-wins duration")
  s:cleanup()
  softcut_api.render_onset = nil
end

-- Asynchronous render delivery (the real norns path) still auto-trims, and the
-- disk-drain barrier is exercised before completion.
do
  softcut_api.writes = {}
  softcut_api.calls = {}
  softcut_api.render_onset = 0.06
  softcut_api.async_render = true
  softcut_api.pending_renders = {}
  softcut_api.render_requests = 0
  local s = make_test_sampler()
  assert(s:add_params())
  params_api:set("low_note", 60)
  params_api:set("high_note", 60)
  params_api:set("note_step", 1)
  params_api:set("vel_layers", 1)
  params_api:set("hold_time", 0.12)
  params_api:set("tail_time", 0)
  params_api:set("guard_interval", 0)
  params_api:set("latency_offset_ms", 0)
  params_api:set("record_mode", 1)
  params_api:set("patch_name", "Async Trim")
  assert(s:init())
  assert(s:start())
  scheduler.drain()
  check(s:get_state() == "complete", "async complete")
  check(#softcut_api.writes == 1, "async one export")
  local start = softcut_api.writes[1].start
  check(start > 0.052 and start < 0.058,
    "async auto-trim start, got " .. tostring(start))
  -- two channel renders for onset analysis plus one disk-drain barrier
  check(softcut_api.render_requests == 3,
    "render requests include write barrier, got " .. softcut_api.render_requests)
  check(#softcut_api.pending_renders == 0, "async render queue drained")
  s:cleanup()
  softcut_api.async_render = false
  softcut_api.render_onset = nil
  softcut_api.pending_renders = {}
end

-- Clean up test artifacts.
os.execute("rm -rf " .. test_root)
print(string.format("OK: %d checks passed", checks))
