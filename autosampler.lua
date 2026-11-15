-- autosampler.lua
-- Lightweight norns front-end for lib/autosampler.lua.
--
-- K2: test note at middle C / highest configured velocity
-- K3: start or stop the capture run

local Autosampler = include("lib/autosampler")

local sampler
local refresh
local message = nil

local STATE_LABELS = {
  idle = "IDLE",
  preparing = "PREP",
  recording = "REC",
  generating = "SFZ",
  stopping = "STOP",
  complete = "DONE",
  cancelled = "STOP",
  error = "ERR",
}

local MODE_LABELS = {stereo = "ST", mono_l = "L", mono_r = "R"}

local function trim_to_width(text, width)
  text = tostring(text or "")
  if util and util.trim_string_to_width then
    return util.trim_string_to_width(text, width)
  end
  if #text > 28 then return text:sub(1, 25) .. "..." end
  return text
end

local function current_patch()
  local result = sampler and sampler:get_result()
  if result and result.patch then return result.patch end
  local plan = sampler and select(1, sampler:build_plan())
  if plan and plan.patch then return plan.patch end
  local ok, value = pcall(params.get, params, "patch_name")
  if ok then return tostring(value) end
  return "autosampler"
end

local function draw_meter(label, y, db, peak_db)
  local x, width = 18, 78
  screen.level(3)
  screen.move(4, y)
  screen.text(label)

  screen.level(1)
  screen.rect(x, y - 4, width, 4)
  screen.fill()

  local fill = util.clamp((db + 60) / 60, 0, 1)
  if fill > 0 then
    screen.level(db > -3 and 15 or 7)
    screen.rect(x, y - 4, math.max(1, width * fill), 4)
    screen.fill()
  end

  local peak_fill = util.clamp((peak_db + 60) / 60, 0, 1)
  if peak_fill > 0 then
    screen.level(15)
    local px = x + width * peak_fill
    screen.move(px, y - 5)
    screen.line(px, y)
    screen.stroke()
  end

  screen.level(4)
  screen.move(124, y)
  screen.text_right(string.format("%d", math.floor(db + 0.5)))
end

local function draw_progress(completed, total, y)
  local width = 120
  screen.level(1)
  screen.rect(4, y, width, 4)
  screen.fill()
  if total > 0 and completed > 0 then
    screen.level(completed >= total and 15 or 8)
    screen.rect(4, y, math.max(1, width * completed / total), 4)
    screen.fill()
  end
end

function redraw()
  if not sampler then return end
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  local progress = sampler:get_progress()
  local plan = nil
  local plan_error = nil
  if sampler:is_running() then
    local result = sampler:get_result()
    plan = result and result.plan
  else
    plan, plan_error = sampler:build_plan()
  end
  local total = progress.total or 0
  if total == 0 and plan then total = plan.count end

  local state = sampler:get_state()
  local label = STATE_LABELS[state] or string.upper(state)
  if sampler:is_testing() then
    label = "TEST"
  elseif state == "idle" and total > 0 then
    label = string.format("%dx", total)
  end

  screen.level(15)
  screen.move(4, 9)
  screen.text("AUTOSAMPLER")
  screen.level(8)
  screen.move(124, 9)
  screen.text_right(label)
  screen.level(2)
  screen.move(4, 11)
  screen.line(124, 11)
  screen.stroke()

  local patch = current_patch()
  local mode = "ST"
  if plan then mode = MODE_LABELS[plan.channel_mode] or "ST" end
  screen.level(6)
  screen.move(4, 21)
  screen.text(trim_to_width(patch, 94))
  screen.level(4)
  screen.move(124, 21)
  screen.text_right(mode)

  local meta
  if sampler:is_testing() then
    meta = "test note active"
  elseif sampler:is_running() then
    local note = progress.note_name or Autosampler.note_name(progress.note or 60)
    meta = string.format("%s v%d  %d/%d", note, progress.velocity or 0,
      progress.completed or 0, total)
  elseif message then
    meta = message
  elseif state == "error" then
    meta = tostring(sampler:get_last_error() or "error"):match("^[^\n]+")
  elseif state == "complete" then
    local result = sampler:get_result()
    meta = string.format("%d samples saved", result and result.count or total)
  elseif plan_error then
    meta = plan_error
  elseif plan then
    meta = string.format("%s-%s st%d v%d  m%d/c%d",
      Autosampler.note_name(plan.low_note),
      Autosampler.note_name(plan.high_note),
      plan.note_step, plan.vel_layers, plan.midi_device, plan.midi_channel)
  else
    meta = "ready"
  end
  screen.level(4)
  screen.move(4, 30)
  screen.text(trim_to_width(meta, 120))

  draw_progress(progress.completed or 0, total, 34)

  local meters = sampler:get_meters()
  draw_meter("L", 46, meters.db_l, meters.peak_db_l)
  draw_meter("R", 55, meters.db_r, meters.peak_db_r)

  screen.level(3)
  screen.move(4, 63)
  if sampler:is_running() then
    screen.text("K3 stop")
  else
    screen.text("K2 test K3 start")
  end
  screen.move(127, 63)
  screen.text_right("48k")

  screen.update()
end

local function note_error(err)
  message = tostring(err or "error"):match("^[^\n]+")
  redraw()
end

function init()
  sampler = Autosampler.new({})
  sampler:set_callback("on_state_change", function() redraw() end)
  sampler:set_callback("on_progress", function() redraw() end)
  sampler:set_callback("on_complete", function(result)
    message = string.format("%d samples saved", result.count or 0)
    redraw()
  end)
  sampler:set_callback("on_error", note_error)

  local ok, err = sampler:add_params()
  if not ok then message = err end
  local initialized, init_err = sampler:init()
  if not initialized then message = init_err end

  refresh = metro.init({
    event = function() redraw() end,
    time = 1 / 15,
    count = -1,
  })
  if refresh then refresh:start() end
  redraw()
end

function key(number, state)
  if state ~= 1 or not sampler then return end
  if number == 2 then
    local ok, err = sampler:trigger_test()
    if ok then message = nil else message = err end
  elseif number == 3 then
    if sampler:is_running() then
      sampler:stop()
      message = nil
    else
      local ok, err = sampler:start()
      message = ok and nil or err
    end
  end
  redraw()
end

function cleanup()
  if refresh then refresh:stop() end
  if sampler then sampler:cleanup() end
end
