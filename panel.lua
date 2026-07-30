--[[
  panel.lua -- stats screen + remote control for the amalgam turtle

  SETUP
    * Advanced Computer with your 3x2 Advanced Monitor
    * A wireless modem (or ender modem for long range) on any free side
      of the computer -- right-click it to enable it
    * The turtle needs a matching modem on its spare upgrade slot

  Save as "startup" on the computer and it comes back after every reboot.

  Buttons: start / stop pause and resume the turtle, reset zeroes the counters.
]]

local PROTO_STATS = "amalgam_stats"
local PROTO_CMD   = "amalgam_cmd"
local OFFLINE_AFTER = 20   -- seconds without a message before we call it offline

-------------------------------------------------------------------------------
-- Peripherals
-------------------------------------------------------------------------------

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached", 0) end

local modem = peripheral.find("modem")
if not modem then error("No modem attached -- put a wireless modem on the computer", 0) end
rednet.open(peripheral.getName(modem))

mon.setTextScale(0.5)
local W, H = mon.getSize()

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local stats = nil
local lastSeen = 0
local turtleId = nil

local buttons = {
  { label = "Start", cmd = "start", colour = colors.green },
  { label = "Stop",  cmd = "stop",  colour = colors.red   },
  { label = "Reset", cmd = "reset", colour = colors.gray  },
}

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

-- label on the left, value right-aligned
local function row(y, label, value, valueColour)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  mon.setCursorPos(3, y)
  mon.write(label)

  value = tostring(value)
  mon.setTextColor(valueColour or colors.white)
  mon.setCursorPos(W - 2 - #value, y)
  mon.write(value)
end

local function layoutButtons()
  local n = #buttons
  local gap = 2
  local bw = math.floor((W - 4 - (n - 1) * gap) / n)
  local bh = 3
  local total = n * bw + (n - 1) * gap
  local startX = math.floor((W - total) / 2) + 1
  local y = H - bh

  for i, b in ipairs(buttons) do
    b.w = bw
    b.h = bh
    b.x = startX + (i - 1) * (bw + gap)
    b.y = y
  end
end

local function online()
  return stats ~= nil and (os.clock() - lastSeen) < OFFLINE_AFTER
end

local function redraw()
  mon.setBackgroundColor(colors.black)
  mon.clear()

  fill(1, 1, W, 1, colors.blue)
  centreText("Amalgam plant", 1, 1, W, 1, colors.blue, colors.white)

  local y = 3

  if not online() then
    centreText("TURTLE OFFLINE", 1, y + 2, W, 1, colors.black, colors.red)
    if stats then
      centreText("last status: " .. tostring(stats.status), 1, y + 4, W, 1,
                 colors.black, colors.gray)
    end
  else
    local s = stats

    local statusColour = colors.lime
    if s.status ~= "idle" and s.status:find("no ") then statusColour = colors.red end
    if s.status == "paused" then statusColour = colors.orange end

    row(y,     "Status",        s.status, statusColour);            y = y + 2
    row(y,     "Alloy made",    s.alloy,    colors.lime);           y = y + 1
    row(y,     "Blocks mined",  s.blocks);                          y = y + 1
    row(y,     "Buckets used",  s.buckets,  colors.lightBlue);      y = y + 1
    row(y,     "Stone used",    s.stone);                           y = y + 1
    row(y,     "Cycles",        s.cycles);                          y = y + 1
    row(y,     "Retries",       s.retries or 0,
        (s.retries or 0) > 0 and colors.yellow or colors.gray);     y = y + 1
    row(y,     "Failures",      s.failures,
        (s.failures or 0) > 0 and colors.orange or colors.gray);    y = y + 2

    local fuel = s.fuel
    row(y, "Fuel", fuel == -1 and "unlimited" or fuel,
        (fuel ~= -1 and fuel < 200) and colors.red or colors.white)

    if turtleId then
      mon.setTextColor(colors.gray)
      mon.setCursorPos(3, H - 4)
      mon.write("turtle #" .. turtleId)
    end
  end

  for _, b in ipairs(buttons) do
    fill(b.x, b.y, b.w, b.h, b.colour)
    centreText(b.label, b.x, b.y, b.w, b.h, b.colour, colors.white)
  end
end

-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------

local function isInside(b, x, y)
  return x >= b.x and x < b.x + b.w
     and y >= b.y and y < b.y + b.h
end

local function send(cmd)
  rednet.broadcast({ cmd = cmd }, PROTO_CMD)
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------

layoutButtons()
redraw()

local tick = os.startTimer(1)

while true do
  local event, p1, p2, p3, p4 = os.pullEvent()

  if event == "monitor_touch" then
    for _, b in ipairs(buttons) do
      if isInside(b, p2, p3) then
        send(b.cmd)
        -- brief flash so the press is visible
        fill(b.x, b.y, b.w, b.h, colors.white)
        centreText(b.label, b.x, b.y, b.w, b.h, colors.white, colors.black)
        sleep(0.15)
        redraw()
        break
      end
    end

  elseif event == "rednet_message" then
    -- p1 = sender id, p2 = message, p3 = protocol
    if p3 == PROTO_STATS and type(p2) == "table" then
      stats = p2
      turtleId = p1
      lastSeen = os.clock()
      redraw()
    end

  elseif event == "timer" and p1 == tick then
    tick = os.startTimer(1)
    redraw()

  elseif event == "monitor_resize" then
    W, H = mon.getSize()
    layoutButtons()
    redraw()
  end
end
