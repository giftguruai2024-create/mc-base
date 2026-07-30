--[[
  touchpanel.lua -- auto-centering touchscreen button panel for CC: Tweaked

  Buttons now have NO hard-coded positions. The layout() function arranges them
  in a grid and centres that grid on whatever size monitor you have, so it works
  the same on a 2x2 or a 6x3 screen.

  Tune the grid with the LAYOUT settings below.
]]

-------------------------------------------------------------------------------
-- 1. Find the monitor
-------------------------------------------------------------------------------

local mon = peripheral.find("monitor")
if not mon then
  error("No monitor found. Attach one directly or over a wired modem network.", 0)
end

-- 0.5 = tiny text (lots of room), 5 = huge. Must be a multiple of 0.5.
-- On a 3x2 monitor you almost certainly want 0.5.
mon.setTextScale(0.5)

local W, H = mon.getSize()

-------------------------------------------------------------------------------
-- 2. Layout settings
-------------------------------------------------------------------------------

local COLS     = 2   -- buttons per row
local BTN_W    = 14  -- preferred button width (shrinks automatically if needed)
local BTN_H    = 3   -- button height
local GAP_X    = 2   -- horizontal space between buttons
local GAP_Y    = 1   -- vertical space between buttons

-------------------------------------------------------------------------------
-- 3. Define your buttons (order = reading order in the grid)
-------------------------------------------------------------------------------

local buttons = {
  {
    label = "Lights",
    state = false,
    on = colors.lime, off = colors.gray,
    action = function(self)
      self.state = not self.state
      redstone.setOutput("back", self.state)   -- top bottom left right front back
    end,
  },
  {
    label = "Door",
    state = false,
    on = colors.orange, off = colors.gray,
    action = function(self)
      self.state = not self.state
      redstone.setOutput("top", self.state)
    end,
  },
  {
    label = "Pulse",
    state = false,
    on = colors.red, off = colors.blue,
    action = function(self)
      redstone.setOutput("left", true)
      sleep(0.5)
      redstone.setOutput("left", false)
    end,
  },
  {
    label = "All Off",
    state = false,
    on = colors.red, off = colors.red,
    action = function(self)
      for _, side in ipairs(redstone.getSides()) do
        redstone.setOutput(side, false)
      end
      for _, b in ipairs(buttons) do b.state = false end
    end,
  },
}

-------------------------------------------------------------------------------
-- 4. Centring layout
-------------------------------------------------------------------------------

local function layout()
  W, H = mon.getSize()

  local rows = math.ceil(#buttons / COLS)

  -- shrink buttons if the preferred width won't fit the screen
  local maxW = math.floor((W - 2 - (COLS - 1) * GAP_X) / COLS)
  local bw = math.max(1, math.min(BTN_W, maxW))
  local bh = BTN_H

  local gridW = COLS * bw + (COLS - 1) * GAP_X
  local gridH = rows * bh + (rows - 1) * GAP_Y

  -- centre horizontally across the whole screen,
  -- vertically within rows 2 .. H-1 (leaving the header and status bar alone)
  local startX = math.floor((W - gridW) / 2) + 1
  local startY = 2 + math.floor(((H - 2) - gridH) / 2)
  if startY < 2 then startY = 2 end

  for i, b in ipairs(buttons) do
    local col = (i - 1) % COLS
    local row = math.floor((i - 1) / COLS)
    b.w = bw
    b.h = bh
    b.x = startX + col * (bw + GAP_X)
    b.y = startY + row * (bh + GAP_Y)
  end
end

-------------------------------------------------------------------------------
-- 5. Drawing helpers
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

local function drawButton(b)
  local colour = b.state and b.on or b.off
  fill(b.x, b.y, b.w, b.h, colour)
  centreText(b.label, b.x, b.y, b.w, b.h, colour, colors.white)
end

local function drawHeader()
  fill(1, 1, W, 1, colors.blue)
  centreText("CONTROL PANEL", 1, 1, W, 1, colors.blue, colors.white)
end

local function drawStatus()
  fill(1, H, W, 1, colors.black)
  centreText(textutils.formatTime(os.time(), true), 1, H, W, 1, colors.black, colors.lightGray)
end

local function redraw()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  drawHeader()
  for _, b in ipairs(buttons) do drawButton(b) end
  drawStatus()
end

-------------------------------------------------------------------------------
-- 6. Hit testing
-------------------------------------------------------------------------------

local function isInside(b, x, y)
  return x >= b.x and x < b.x + b.w
     and y >= b.y and y < b.y + b.h
end

-------------------------------------------------------------------------------
-- 7. Main event loop
-------------------------------------------------------------------------------

layout()
redraw()
local clock = os.startTimer(1)

while true do
  local event, p1, p2, p3 = os.pullEvent()

  if event == "monitor_touch" then
    for _, b in ipairs(buttons) do
      if isInside(b, p2, p3) then
        b.action(b)
        redraw()
        break
      end
    end

  elseif event == "timer" and p1 == clock then
    clock = os.startTimer(1)
    drawStatus()

  elseif event == "monitor_resize" then
    layout()
    redraw()
  end
end
