--[[
  amalgamfarm.lua -- Amalgam Farm controller (headless)

  Owns the farm's logistics numbers: reads the stone drawer and the alloy
  drawer over wired modems, publishes them on the bus, and forwards
  start/stop to its four turtles. The Master's screen is its display.

  SETUP
    * Advanced Computer: wireless modem (bus) + wired modem (drawer network)
    * After the in-game drawer probe, set the two peripheral names below
    * startup:  shell.run("update")  then  shell.run("amalgamfarm")
]]

-------------------------------------------------------------------------------
-- CONFIG  (drawer names come from the Task 8 probe: peripheral.getNames())
-------------------------------------------------------------------------------

local STONE_DRAWER = nil     -- e.g. "functionalstorage:oak_drawer_0"
local ALLOY_DRAWER = nil     -- e.g. "functionalstorage:oak_drawer_1"

local CHILDREN = { "AmalgamT1", "AmalgamT2", "AmalgamT3", "AmalgamT4" }

local STONE_LOW    = 256     -- warn below this many stone
local RATE_WINDOW  = 600     -- seconds of samples for the alloy/hour figure
local PAUSE_MARKER = ".paused"

local bus = require("bus")

local ok, err = bus.open{
  label    = os.getComputerLabel() or "AmalgamFarm",
  role     = "controller",
  program  = "amalgamfarm.lua",
  provides = { "andesite_alloy" },
  accepts  = { "start", "stop", "update" },
}
if not ok then error(err, 0) end

-------------------------------------------------------------------------------
-- Drawer metering
-------------------------------------------------------------------------------

local function wrapDrawer(name)
  if not name then return nil end
  if not peripheral.isPresent(name) then return nil end
  return peripheral.wrap(name)
end

local function countItems(p)
  if not p then return nil end
  local total = 0
  local okList, listed = pcall(p.list)
  if not okList or type(listed) ~= "table" then return nil end
  for _, item in pairs(listed) do
    total = total + (item.count or 0)
  end
  return total
end

local samples = {}   -- { t = epoch-seconds, count = alloy total }

local function ratePerHour(now, count)
  if count == nil then return nil end
  samples[#samples + 1] = { t = now, count = count }
  while samples[1] and now - samples[1].t > RATE_WINDOW do
    table.remove(samples, 1)
  end
  local first = samples[1]
  if not first or now - first.t < 30 then return nil end
  return math.floor((count - first.count) * 3600 / (now - first.t) + 0.5)
end

-------------------------------------------------------------------------------
-- Fleet-contract state
-------------------------------------------------------------------------------

local running = not fs.exists(PAUSE_MARKER)
local wantUpdate = false

local function setRunning(on)
  running = on
  if on then
    if fs.exists(PAUSE_MARKER) then fs.delete(PAUSE_MARKER) end
  elseif not fs.exists(PAUSE_MARKER) then
    local f = fs.open(PAUSE_MARKER, "w")
    if f then f.write("operator stop\n") f.close() end
  end
end

-- the hive-mind part: farm-level start/stop fans out to every child
local function forward(cmd)
  for _, child in ipairs(CHILDREN) do
    bus.command(child, cmd)
  end
end

local busHandlers = {
  start = function() setRunning(true)  forward("start") end,
  stop  = function() setRunning(false) forward("stop")  end,
  update = function() wantUpdate = true end,
}

-------------------------------------------------------------------------------
-- Coroutines
-------------------------------------------------------------------------------

local function serve()
  bus.serve(busHandlers)
end

local function heartbeat()
  while true do
    local stone = countItems(wrapDrawer(STONE_DRAWER))
    local alloy = countItems(wrapDrawer(ALLOY_DRAWER))
    local now = math.floor(os.epoch("utc") / 1000)
    local rate = ratePerHour(now, alloy)

    local status = "ok"
    if not (STONE_DRAWER and ALLOY_DRAWER) then
      status = "drawers not configured"
    elseif stone == nil or alloy == nil then
      status = "drawer offline"
    elseif stone < STONE_LOW then
      status = "stone low"
    end

    bus.publish{
      status  = status,
      stored  = alloy,
      stone   = stone,
      rate    = rate,
      running = running,
      idle    = true,             -- a controller has no unsafe moment
      extras  = { { name = "(drawers)", link = "wired" } },
    }

    if wantUpdate then
      bus.event("updating")
      sleep(0.5)
      shell.run("update")
      os.reboot()
    end
    sleep(5)
  end
end

print("AmalgamFarm controller up. The Master is my screen.")
parallel.waitForAny(serve, heartbeat)
