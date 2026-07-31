--[[
  master.lua -- fleet screen + code freshness + update orchestration

  SETUP
    * Advanced Computer, 4x4 Advanced Monitor, ender modem on a free side
    * Bootstrap:  wget https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/update.lua update
    * startup:    shell.run("update")  then  shell.run("master")

  Shows every machine on the bus, marks each CURRENT or STALE against the
  GitHub repo, and pushes updates with UPDATE ALL (stop -> wait idle ->
  update -> reboot -> restore prior state). See the vault note
  "M - Master Control" for the full design.
]]

-------------------------------------------------------------------------------
-- CONFIG
-------------------------------------------------------------------------------

local USER   = "giftguruai2024-create"
local REPO   = "mc-base"
local BRANCH = "main"

local OFFLINE_AFTER  = 20   -- s without a heartbeat before a machine is offline
local IDLE_TIMEOUT   = 60   -- s to wait for a machine to acknowledge idle
local RETURN_TIMEOUT = 90   -- s to wait for a machine to come back updated
local EVENTS_KEPT    = 40   -- ring buffer size for the events strip

-------------------------------------------------------------------------------

local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)

local bus = require("bus")

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached", 0) end
mon.setTextScale(0.5)
local W, H = mon.getSize()

if not http then error("HTTP is disabled -- master cannot compare against GitHub", 0) end

local ok, err = bus.open{
  label   = os.getComputerLabel() or "Master",
  role    = "control",
  program = "master.lua",
  accepts = { "rescan" },
}
if not ok then error(err, 0) end

local SELF_LABEL = bus.identity().label
local selfFp     = bus.fingerprint()

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local machines, record, isOnline = bus.registry(OFFLINE_AFTER)

local remote, remoteErr = nil, "not scanned yet"   -- Task 8 fills these
local flow = {}            -- label -> "stopping" / "updating" / "SKIPPED" ...
local events = {}          -- newest first: { t = "12:04", from, text }
local selected = nil       -- label shown in the detail pane (Task 12)
local updating = false     -- UPDATE ALL in progress

local requestRescan    = false
local requestUpdateAll = false

local rowByY  = {}
local buttons = {}

-------------------------------------------------------------------------------
-- Freshness
--
-- Fetch files.txt from the repo, hash every listed file with the SAME
-- function the machines use, and compare per file. Cache-bust every fetch:
-- GitHub raw caches for minutes and a stale cache here means the screen
-- lies about the whole base.
-------------------------------------------------------------------------------

local function fetchRemote()
  local res = http.get(BASE .. "files.txt?cb=" .. tostring(os.epoch("utc")))
  if not res then
    remote, remoteErr = nil, "unreachable"
    return
  end
  local manifest = res.readAll()
  res.close()

  local out = {}
  for line in manifest:gmatch("[^\r\n]+") do
    local name = line:match("^%s*(.-)%s*$")
    if name ~= "" and name:sub(1, 1) ~= "#" then
      local r = http.get(BASE .. name .. "?cb=" .. tostring(os.epoch("utc")))
      if not r then
        remote, remoteErr = nil, "failed on " .. name
        return
      end
      out[name] = bus.hashString(r.readAll())
      r.close()
    end
  end
  remote, remoteErr = out, nil
end

-- A machine is STALE if any repo-tracked file differs from, or is missing
-- from, its reported fingerprint. Machines that report no fingerprint at
-- all predate the bus change: unknown, not broken.
local function codeState(m)
  if remote == nil then return "unknown" end
  if type(m.fingerprint) ~= "table" then return "unknown" end
  for name, want in pairs(remote) do
    if m.fingerprint[name] ~= want then return "stale" end
  end
  return "current"
end

local function selfIsStale()
  if remote == nil then return false end
  for name, want in pairs(remote) do
    if selfFp[name] ~= want then return true end
  end
  return false
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local function fill(x, y, w, h, colour)
  mon.setBackgroundColor(colour)
  local blank = string.rep(" ", w)
  for row = y, y + h - 1 do
    mon.setCursorPos(x, row)
    mon.write(blank)
  end
end

local function centreText(text, x, y, w, h, bg, fg)
  if #text > w then text = text:sub(1, w) end
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  mon.setCursorPos(x + math.floor((w - #text) / 2), y + math.floor((h - 1) / 2))
  mon.write(text)
end

local function writeAt(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg or colors.black)
  mon.setTextColor(fg or colors.white)
  mon.write(text)
end

local function sortedLabels()
  local out = {}
  for label in pairs(machines) do out[#out + 1] = label end
  table.sort(out)
  return out
end

local CODE_COLOURS = {
  current = colors.lime,
  stale   = colors.orange,
  unknown = colors.gray,
}

local function layoutButtons()
  buttons = {
    { label = "UPDATE ALL", colour = colors.orange,
      action = function() requestUpdateAll = true end },
    { label = "STOP ALL",   colour = colors.red,
      action = function() bus.command("*", "stop") end },
    { label = "RESCAN",     colour = colors.gray,
      action = function() requestRescan = true end },
  }
  local n = #buttons
  local gap = 2
  local bw = math.floor((W - 4 - (n - 1) * gap) / n)
  local bh = 3
  local total = n * bw + (n - 1) * gap
  local startX = math.floor((W - total) / 2) + 1
  local y = H - bh
  for i, b in ipairs(buttons) do
    b.x, b.y, b.w, b.h = startX + (i - 1) * (bw + gap), y, bw, bh
  end
end

local function countStates()
  local total, stale, offline = 1, 0, 0   -- master counts itself
  for _, label in ipairs(sortedLabels()) do
    total = total + 1
    if not isOnline(label) then offline = offline + 1
    elseif codeState(machines[label]) == "stale" then stale = stale + 1 end
  end
  if selfIsStale() then stale = stale + 1 end
  return total, stale, offline
end

local function drawRow(y, name, role, link, linkColour, code, codeColour)
  rowByY[y] = name
  writeAt(2, y, name:sub(1, 18), colors.white)
  writeAt(21, y, tostring(role):sub(1, 8), colors.lightGray)
  writeAt(31, y, link, linkColour)
  writeAt(41, y, code, codeColour)
end

local function redraw()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  rowByY = {}

  local total, stale, offline = countStates()
  fill(1, 1, W, 1, colors.blue)
  centreText(("BASE MASTER   %d machines   %d stale   %d offline")
    :format(total, stale, offline), 1, 1, W, 1, colors.blue, colors.white)

  if remoteErr then
    fill(1, 2, W, 1, colors.black)
    centreText("GitHub: " .. remoteErr, 1, 2, W, 1, colors.black, colors.orange)
  end

  fill(1, 3, W, 1, colors.gray)
  writeAt(2, 3, "MACHINE", colors.white, colors.gray)
  writeAt(21, 3, "TYPE", colors.white, colors.gray)
  writeAt(31, 3, "LINK", colors.white, colors.gray)
  writeAt(41, 3, "CODE", colors.white, colors.gray)

  local y = 4

  -- the master's own row, always first
  local selfCode = selfIsStale() and "stale" or (remote and "current" or "unknown")
  drawRow(y, SELF_LABEL, "control", "self", colors.cyan,
          flow[SELF_LABEL] or selfCode, flow[SELF_LABEL] and colors.yellow
                                        or CODE_COLOURS[selfCode])
  y = y + 1

  for _, label in ipairs(sortedLabels()) do
    local m = machines[label]
    local online = isOnline(label)
    local code = codeState(m)
    local codeText = flow[label] or code
    local codeColour = flow[label] and colors.yellow or CODE_COLOURS[code]
    if flow[label] == "SKIPPED" or flow[label] == "lost" then
      codeColour = colors.orange
    end
    drawRow(y, label, m.role or "?",
            online and "ONLINE" or "OFFLINE",
            online and colors.lime or colors.red,
            codeText, codeColour)
    y = y + 1
    if y > H - 5 then break end
  end

  for _, b in ipairs(buttons) do
    local c = b.colour
    if b.label == "UPDATE ALL" and (remote == nil or updating) then
      c = colors.gray   -- disabled without a repo picture / while running
    end
    fill(b.x, b.y, b.w, b.h, c)
    centreText(b.label, b.x, b.y, b.w, b.h, c, colors.white)
  end
end

-------------------------------------------------------------------------------
-- Input + coroutines
-------------------------------------------------------------------------------

local function isInside(b, x, y)
  return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h
end

local function onTouch(x, y)
  for _, b in ipairs(buttons) do
    if isInside(b, x, y) then
      b.action()
      fill(b.x, b.y, b.w, b.h, colors.white)
      centreText(b.label, b.x, b.y, b.w, b.h, colors.white, colors.black)
      sleep(0.15)
      return
    end
  end
  if rowByY[y] then selected = rowByY[y] end
end

local function uiLoop()
  layoutButtons()
  redraw()
  local tick = os.startTimer(1)
  while true do
    local event, p1, p2, p3 = os.pullEvent()
    if event == "monitor_touch" then
      onTouch(p2, p3)
      redraw()
    elseif event == "timer" and p1 == tick then
      tick = os.startTimer(1)
      redraw()
    elseif event == "monitor_resize" then
      W, H = mon.getSize()
      layoutButtons()
      redraw()
    end
  end
end

local function pushEvent(from, text)
  table.insert(events, 1, {
    t = textutils.formatTime(os.time(), true),
    from = from, text = text,
  })
  events[EVENTS_KEPT + 1] = nil
end

local function watcher()
  bus.watch(
    function(msg) record(msg) end,
    function(msg)
      local detail = msg.event
      if msg.data ~= nil then
        detail = detail .. " " .. textutils.serialize(msg.data):gsub("%s+", " ")
      end
      pushEvent(msg.from, detail)
    end
  )
end

local function doRescan()
  fetchRemote()
  bus.scan(3)
end

local function updateAll()
  -- Task 9 implements the real orchestration.
end

local function actionLoop()
  while true do
    if requestRescan then
      requestRescan = false
      doRescan()
    end
    if requestUpdateAll then
      requestUpdateAll = false
      updateAll()
    end
    sleep(0.2)
  end
end

doRescan()
parallel.waitForAny(watcher, uiLoop, actionLoop)
