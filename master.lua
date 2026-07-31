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
local rowFold = {}         -- y -> group label ([+]/[-] tap zone)
local folded  = {}         -- group label -> collapsed? (default true, set lazily)
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

-- Hive grouping: a machine with .parent renders under that parent's row.
-- A group exists if any machine names this label as parent - even when the
-- controller itself hasn't been seen yet (e.g. children deployed first).
local function childrenOf(parent)
  local out = {}
  for _, label in ipairs(sortedLabels()) do
    if machines[label].parent == parent then out[#out + 1] = label end
  end
  return out
end

local function groupParents()
  local seen, out = {}, {}
  for _, label in ipairs(sortedLabels()) do
    local p = machines[label].parent
    if p and not seen[p] then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  table.sort(out)
  return out
end

local function isGroup(label)
  for _, label2 in ipairs(sortedLabels()) do
    if machines[label2].parent == label then return true end
  end
  return false
end

-- members = controller (if seen) + children. Returns total, up, codeText, colour.
local function groupSummary(label)
  local members = childrenOf(label)
  if machines[label] then table.insert(members, 1, label) end
  local up, stale, unknown = 0, 0, 0
  for _, l in ipairs(members) do
    if isOnline(l) then up = up + 1 end
    local c = codeState(machines[l])
    if c == "stale" then stale = stale + 1
    elseif c == "unknown" then unknown = unknown + 1 end
  end
  if stale > 0 then
    return #members, up, stale .. " stale", CODE_COLOURS.stale
  elseif unknown > 0 then
    return #members, up, "unknown", CODE_COLOURS.unknown
  end
  return #members, up, "current", CODE_COLOURS.current
end

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

local detailButtons = {}

local function paneGeometry()
  local listW   = math.max(34, math.floor(W * 0.45))
  local eventsH = 5
  local listBottom = H - 4 - eventsH - 1
  return listW, eventsH, listBottom
end

local function drawDetail(x1, yTop, yBottom)
  detailButtons = {}
  local paneW = W - x1 + 1
  local label = selected
  if not label then
    centreText("tap a machine", x1, yTop + 2, paneW, 1, colors.black, colors.gray)
    return
  end

  local isSelf = (label == SELF_LABEL)
  local m = not isSelf and machines[label] or nil
  if not isSelf and not m then
    centreText(label .. " not seen yet", x1, yTop + 2, paneW, 1,
               colors.black, colors.gray)
    return
  end

  fill(x1, yTop, paneW, 1, colors.gray)
  writeAt(x1 + 1, yTop, label:sub(1, paneW - 10), colors.white, colors.gray)
  local idText = isSelf and ("#" .. os.getComputerID()) or ("#" .. tostring(m.id))
  writeAt(x1 + paneW - #idText - 1, yTop, idText, colors.lightGray, colors.gray)

  local y = yTop + 2
  local function statRow(k, v, colour)
    if y > yBottom - 5 then return end
    writeAt(x1 + 1, y, k, colors.lightBlue)
    writeAt(x1 + 14, y, tostring(v):sub(1, paneW - 15), colour or colors.white)
    y = y + 1
  end

  if isSelf then
    statRow("Status", updating and "updating fleet" or "watching")
    statRow("Machines", (function()
      local n = 0
      for _ in pairs(machines) do n = n + 1 end
      return n + 1
    end)())
  else
    local st = m.stats or {}
    statRow("Status", st.status or "?")
    statRow("Running", st.running and "yes" or "no",
            st.running and colors.lime or colors.orange)
    local ago = math.floor(os.clock() - m.lastSeen)
    statRow("Last seen", ago .. "s ago", ago < OFFLINE_AFTER and colors.lime
                                          or colors.red)
    if st.fuel then
      statRow("Fuel", st.fuel == -1 and "unlimited" or st.fuel)
    end
    if st.alloy  then statRow("Alloy",  st.alloy)  end
    if st.cycles then statRow("Cycles", st.cycles) end
    -- any other scalar stats a machine publishes (controllers: stored, rate...)
    local known = { status=true, running=true, idle=true, fuel=true,
                    alloy=true, cycles=true, extras=true }
    local extraKeys = {}
    for k, v in pairs(st) do
      if not known[k] and (type(v) == "number" or type(v) == "string") then
        extraKeys[#extraKeys + 1] = k
      end
    end
    table.sort(extraKeys)
    for i = 1, math.min(#extraKeys, 6) do
      statRow(extraKeys[i]:sub(1,1):upper() .. extraKeys[i]:sub(2), st[extraKeys[i]])
    end
  end

  -- per-file hash comparison
  y = y + 1
  local fp = isSelf and selfFp or m.fingerprint
  local state = isSelf and (selfIsStale() and "stale" or
                            (remote and "current" or "unknown"))
                or codeState(m)
  statRow("Code", state, CODE_COLOURS[state])
  if remote and type(fp) == "table" then
    local names = {}
    for name in pairs(remote) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      if y > yBottom - 2 then break end
      local same = fp[name] == remote[name]
      writeAt(x1 + 2, y, name:sub(1, 16), colors.lightGray)
      writeAt(x1 + 19, y, same and "ok" or "differs",
              same and colors.lime or colors.orange)
      y = y + 1
    end
  end

  -- per-machine buttons (not for the master's own row)
  if not isSelf then
    local defs = {
      { label = "START",  colour = colors.green,
        action = function() bus.command(label, "start") end },
      { label = "STOP",   colour = colors.red,
        action = function() bus.command(label, "stop") end },
      { label = "UPDATE", colour = colors.orange,
        action = function() bus.command(label, "update") end },
    }
    local gap = 1
    local bw = math.floor((paneW - 2 - (#defs - 1) * gap) / #defs)
    local bx = x1 + 1
    for _, d in ipairs(defs) do
      d.x, d.y, d.w, d.h = bx, yBottom - 2, bw, 3
      bx = bx + bw + gap
      detailButtons[#detailButtons + 1] = d
    end
    for _, b in ipairs(detailButtons) do
      fill(b.x, b.y, b.w, b.h, b.colour)
      centreText(b.label, b.x, b.y, b.w, b.h, b.colour, colors.white)
    end
  end
end

local function drawEvents(yTop, height)
  writeAt(2, yTop, "EVENTS", colors.lightBlue)
  for i = 1, height - 1 do
    local e = events[i]
    if not e then break end
    local y = yTop + i
    writeAt(2, y, e.t, colors.gray)
    writeAt(9, y, tostring(e.from):sub(1, 15), colors.white)
    writeAt(26, y, tostring(e.text):sub(1, W - 27), colors.yellow)
  end
end

local function redraw()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  rowByY = {}
  rowFold = {}

  local listW, eventsH, listBottom = paneGeometry()

  local total, stale, offline = countStates()
  fill(1, 1, W, 1, colors.blue)
  centreText(("BASE MASTER   %d machines   %d stale   %d offline")
    :format(total, stale, offline), 1, 1, W, 1, colors.blue, colors.white)

  if remoteErr then
    centreText("GitHub: " .. remoteErr, 1, 2, W, 1, colors.black, colors.orange)
  end

  -- list pane header
  fill(1, 3, listW, 1, colors.gray)
  writeAt(2, 3, "MACHINE", colors.white, colors.gray)
  writeAt(listW - 14, 3, "LINK", colors.white, colors.gray)
  writeAt(listW - 7, 3, "CODE", colors.white, colors.gray)

  -- divider
  for y = 3, listBottom do
    writeAt(listW + 1, y, "\149", colors.gray, colors.black)
  end

  local function listRow(y, name, link, linkColour, code, codeColour)
    rowByY[y] = name
    if name == selected then
      fill(1, y, listW, 1, colors.brown)
    end
    local bg = (name == selected) and colors.brown or colors.black
    writeAt(2, y, name:sub(1, listW - 18), colors.white, bg)
    writeAt(listW - 14, y, link, linkColour, bg)
    writeAt(listW - 7, y, code:sub(1, 8), codeColour, bg)
  end

  local y = 4
  local selfCode = selfIsStale() and "stale" or (remote and "current" or "unknown")
  listRow(y, SELF_LABEL, "self", colors.cyan,
          flow[SELF_LABEL] or selfCode,
          flow[SELF_LABEL] and colors.yellow or CODE_COLOURS[selfCode])
  y = y + 1

  local groups = groupParents()
  local inGroup = {}
  for _, g in ipairs(groups) do inGroup[g] = true end

  -- flat machines first: no parent, and not themselves a group controller
  for _, label in ipairs(sortedLabels()) do
    if y > listBottom then break end
    local m = machines[label]
    if not m.parent and not inGroup[label] then
      local online = isOnline(label)
      local code = codeState(m)
      local codeText = flow[label] or code
      local codeColour = flow[label] and colors.yellow or CODE_COLOURS[code]
      if flow[label] == "SKIPPED" or flow[label] == "lost" then
        codeColour = colors.orange
      end
      listRow(y, label,
              online and "ONLINE" or "OFFLINE",
              online and colors.lime or colors.red,
              codeText, codeColour)
      y = y + 1
    end
  end

  -- then the groups
  for _, g in ipairs(groups) do
    if y > listBottom then break end
    if folded[g] == nil then folded[g] = true end
    local total, up, codeText, codeColour = groupSummary(g)

    rowFold[y] = g
    if g == selected then fill(1, y, listW, 1, colors.brown) end
    local bg = (g == selected) and colors.brown or colors.black
    writeAt(2, y, folded[g] and "[+]" or "[-]", colors.yellow, bg)
    writeAt(6, y, g:sub(1, listW - 22), colors.white, bg)
    writeAt(listW - 14, y, up .. " up", up == total and colors.lime or colors.orange, bg)
    writeAt(listW - 7, y, codeText:sub(1, 8), codeColour, bg)
    rowByY[y] = g
    y = y + 1

    if not folded[g] then
      for _, label in ipairs(childrenOf(g)) do
        if y > listBottom then break end
        local m = machines[label]
        local online = isOnline(label)
        local code = codeState(m)
        local codeText2 = flow[label] or code
        local codeColour2 = flow[label] and colors.yellow or CODE_COLOURS[code]
        if flow[label] == "SKIPPED" or flow[label] == "lost" then
          codeColour2 = colors.orange
        end
        if label == selected then fill(1, y, listW, 1, colors.brown) end
        local bg2 = (label == selected) and colors.brown or colors.black
        writeAt(4, y, "\7 " .. label:sub(1, listW - 20), colors.white, bg2)
        writeAt(listW - 14, y, online and "ONLINE" or "OFFLINE",
                online and colors.lime or colors.red, bg2)
        writeAt(listW - 7, y, codeText2:sub(1, 8), codeColour2, bg2)
        rowByY[y] = label
        y = y + 1
      end
      -- display-only extras published by the controller
      local ctl = machines[g]
      local extras = ctl and ctl.stats and ctl.stats.extras
      if type(extras) == "table" then
        for _, e in ipairs(extras) do
          if y > listBottom then break end
          writeAt(4, y, "\7 " .. tostring(e.name):sub(1, listW - 20), colors.gray)
          writeAt(listW - 14, y, tostring(e.link or "-"):sub(1, 7), colors.cyan)
          writeAt(listW - 7, y, "-", colors.gray)
          y = y + 1
        end
      end
    end
  end

  drawDetail(listW + 2, 3, listBottom)

  writeAt(1, listBottom + 1, string.rep("\140", W), colors.gray, colors.black)
  drawEvents(listBottom + 2, eventsH)

  for _, b in ipairs(buttons) do
    local c = b.colour
    if b.label == "UPDATE ALL" and (remote == nil or updating) then
      c = colors.gray
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
  for _, b in ipairs(detailButtons) do
    if isInside(b, x, y) then
      b.action()
      fill(b.x, b.y, b.w, b.h, colors.white)
      centreText(b.label, b.x, b.y, b.w, b.h, colors.white, colors.black)
      sleep(0.15)
      return
    end
  end
  if rowFold[y] and x <= 5 then
    folded[rowFold[y]] = not folded[rowFold[y]]
    return
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
      tick = os.startTimer(1)
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
    function(msg)
      record(msg)
      local f = flow[msg.from]
      if (f == "SKIPPED" or f == "lost")
         and codeState(machines[msg.from]) == "current" then
        flow[msg.from] = nil
      end
    end,
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

-------------------------------------------------------------------------------
-- UPDATE ALL
--
-- stop -> wait for each machine to report idle -> update -> reboot ->
-- restore prior run state -> master updates itself last. Machines that
-- do not acknowledge idle are SKIPPED, never force-updated: a turtle
-- rebooted mid-run wakes up lost.
-------------------------------------------------------------------------------

local function waitUntil(seconds, predicate)
  local deadline = os.clock() + seconds
  while os.clock() < deadline do
    if predicate() then return true end
    sleep(0.5)
  end
  return false
end

local function updateAll()
  if updating then return end
  updating = true
  fetchRemote()                       -- freshest picture before deciding
  if remote == nil then updating = false return end

  -- 1. target only online + stale machines
  local targets = {}
  for _, label in ipairs(sortedLabels()) do
    if isOnline(label) and codeState(machines[label]) == "stale" then
      targets[#targets + 1] = label
    end
  end

  -- 2. snapshot operator intent BEFORE touching anything
  local wasRunning = {}
  for _, label in ipairs(targets) do
    local st = machines[label].stats or {}
    wasRunning[label] = (st.running == true)
  end

  -- 3. stop, then wait for each to acknowledge idle
  for _, label in ipairs(targets) do
    flow[label] = "stopping"
    bus.command(label, "stop")
  end
  local acked = {}
  for _, label in ipairs(targets) do
    local ok = waitUntil(IDLE_TIMEOUT, function()
      local st = machines[label].stats or {}
      return st.idle == true
    end)
    if ok then
      acked[#acked + 1] = label
    else
      flow[label] = "SKIPPED"
      pushEvent(SELF_LABEL, "skipped " .. label .. " (no idle ack)")
      if wasRunning[label] then bus.command(label, "start") end
    end
  end

  -- 4. update (workers reboot themselves afterwards)
  for _, label in ipairs(acked) do
    flow[label] = "updating"
    bus.command(label, "update")
  end

  -- 5. wait for each to come back CURRENT, 6. restore prior state
  for _, label in ipairs(acked) do
    flow[label] = "rebooting"
    local back = waitUntil(RETURN_TIMEOUT, function()
      return isOnline(label) and codeState(machines[label]) == "current"
    end)
    if back then
      flow[label] = nil
      if wasRunning[label] then bus.command(label, "start") end
      pushEvent(SELF_LABEL, "updated " .. label
        .. (wasRunning[label] and " (restarted)" or " (left stopped)"))
    else
      flow[label] = "lost"
      pushEvent(SELF_LABEL, "lost " .. label .. " after update")
    end
  end

  -- 7. the master itself, last
  if selfIsStale() then
    flow[SELF_LABEL] = "updating"
    pushEvent(SELF_LABEL, "updating self, rebooting")
    sleep(1)
    shell.run("update")
    os.reboot()
  end

  updating = false
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
