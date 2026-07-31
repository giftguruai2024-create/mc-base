--[[
  amalgamturtle.lua -- one dripper station of the Amalgam Farm (turtle side)

  stone -> andesite -> andesite amalgam, one bucket of water per step.
  Four identical turtles run this; each is labelled AmalgamT1..T4 and
  declares parent = "AmalgamFarm" so the Master folds them into one row.

  LAYOUT (see the vault's amalgam-station diagram)
          [ OUTPUT BARREL ]
  [water] [  TURTLE  B    ] [ DRIPPER ]
          [  TURTLE  A    ] [  block  ]
          [ INPUT BARREL  ]

  UPGRADES   diamond pickaxe + wireless modem
  INVENTORY  1: stone   2: empty bucket   3: empty (output)   4: coal

  SAFETY (new over the retired amalgam.lua)
    * boot self-probe: verifies the station before any work; on failure the
      status is "misplaced: <what>" and the turtle WAITS for a human
    * dig whitelist: only stone / andesite / amalgam are ever dug; anything
      else in the work spot halts with "unexpected block: <id>"

  USAGE
    amalgamturtle probe   -- print what the turtle can see, then exit
    amalgamturtle         -- run forever
]]

-------------------------------------------------------------------------------
-- CONFIG
-------------------------------------------------------------------------------

local STAGES = {
  { id = "minecraft:stone",             label = "stone"    },
  { id = "minecraft:andesite",          label = "andesite" },
  { id = "ftb:andesite_amalgam_block",  label = "amalgam"  },
}

local BARREL_ID  = "sophisticatedstorage:barrel"
local DRIPPER_ID = "ftbstuff:dripper"

local SLOT_INPUT  = 1
local SLOT_BUCKET = 2
local SLOT_OUTPUT = 3

local EMPTY_BUCKET = "minecraft:bucket"
local FULL_BUCKET  = "minecraft:water_bucket"

local STAGE_TIMEOUT   = 15
local POLL_INTERVAL   = 0.4
local MAX_DRIPS       = 4
local WAIT_ON_BLOCKED = 15
local FUEL_FLOOR      = 40

local PARENT = "AmalgamFarm"
local PAUSE_MARKER = ".paused"

local bus_ok, bus = pcall(require, "bus")
if not bus_ok then bus = nil end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local stats = {
  cycles = 0, blocks = 0, buckets = 0, alloy = 0, stone = 0,
  failures = 0, retries = 0, recoveries = 0,
  status = "starting", fuel = 0,
  idle = false, running = true,
}

local running, stopped = not fs.exists(PAUSE_MARKER), false
local wantUpdate = false

local function log(fmt, ...)
  print(("[%s] "):format(textutils.formatTime(os.time(), true)) .. fmt:format(...))
end

-------------------------------------------------------------------------------
-- Networking
-------------------------------------------------------------------------------

local function openBus()
  if not bus then return end
  bus.open{
    label    = os.getComputerLabel() or ("AmalgamT" .. os.getComputerID()),
    role     = "turtle",
    program  = "amalgamturtle.lua",
    parent   = PARENT,
    provides = { "andesite_alloy" },
    accepts  = { "start", "stop", "reset", "update" },
  }
end

local function broadcast()
  if not (bus and bus.isOpen()) then return end
  local fuel = turtle.getFuelLevel()
  stats.fuel = (fuel == "unlimited") and -1 or fuel
  stats.running = running
  bus.publish(stats)
end

local function setStatus(s)
  if stats.status ~= s then log("-> %s", s) end
  stats.status = s
  broadcast()
end

-------------------------------------------------------------------------------
-- Inspection helpers
-------------------------------------------------------------------------------

local function turnAround()
  turtle.turnLeft()
  turtle.turnLeft()
end

local function nameAt(fn)
  local ok, data = fn()
  if ok then return data.name end
  return nil
end

local function frontName() return nameAt(turtle.inspect)     end
local function upName()    return nameAt(turtle.inspectUp)   end
local function downName()  return nameAt(turtle.inspectDown) end

local function stageIndex(name)
  if not name then return nil end
  for i, s in ipairs(STAGES) do
    if s.id == name then return i end
  end
  return nil
end

local function bucketState()
  local item = turtle.getItemDetail(SLOT_BUCKET)
  if not item then return "missing" end
  if item.name == FULL_BUCKET  then return "full"  end
  if item.name == EMPTY_BUCKET then return "empty" end
  return "wrong"
end

-------------------------------------------------------------------------------
-- Boot self-probe -- verify the station BEFORE any work. On failure the
-- turtle reports and waits; it never guesses and never wanders.
-------------------------------------------------------------------------------

local function probeStation()
  if downName() ~= BARREL_ID then
    return false, "no input barrel below (am I at position A?)"
  end
  local front = frontName()
  if front and not stageIndex(front) then
    return false, "unexpected block in work spot: " .. front
  end
  local b = bucketState()
  if b == "missing" then return false, "no bucket in slot 2" end
  if b == "wrong"   then return false, "slot 2 is not a bucket" end
  local fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and fuel < FUEL_FLOOR then
    return false, "fuel below floor (" .. tostring(fuel) .. ")"
  end
  -- check the dripper without disturbing anything: up to B, look, come back
  if not turtle.up() then
    return false, "cannot reach position B (blocked above)"
  end
  local atB = frontName()
  local backDown = turtle.down()
  if atB ~= DRIPPER_ID then
    return false, "no dripper at B-front (found " .. tostring(atB or "nothing") .. ")"
  end
  if not backDown then
    return false, "could not return to A from B"
  end
  return true
end

-------------------------------------------------------------------------------
-- Position recovery (proven logic, unchanged)
-------------------------------------------------------------------------------

local function atA()
  return downName() == BARREL_ID
end

local function facingWork()
  local n = frontName()
  return n == nil or stageIndex(n) ~= nil
end

local function recover()
  if frontName() == DRIPPER_ID then
    if turtle.down() then
      stats.recoveries = stats.recoveries + 1
      log("Recovered: dropped from B to A")
    end
  end
  if not atA() then
    if upName() == BARREL_ID then
      turtle.down()
      stats.recoveries = stats.recoveries + 1
    end
  end
  if not atA() then
    setStatus("misplaced: cannot find the input barrel below")
    return false
  end
  for _ = 1, 4 do
    if facingWork() then return true end
    turtle.turnRight()
    stats.recoveries = stats.recoveries + 1
  end
  setStatus("misplaced: cannot find the conversion spot")
  return false
end

-------------------------------------------------------------------------------
-- Fuel
-------------------------------------------------------------------------------

local function ensureFuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  if fuel < FUEL_FLOOR then
    for slot = 1, 16 do
      if slot ~= SLOT_BUCKET and slot ~= SLOT_INPUT and slot ~= SLOT_OUTPUT then
        turtle.select(slot)
        if turtle.refuel(1) then break end
      end
    end
    turtle.select(SLOT_INPUT)
  end
  fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and fuel < 8 then
    setStatus("out of fuel")
    return false
  end
  return true
end

-------------------------------------------------------------------------------
-- Probe mode (terminal diagnostic)
-------------------------------------------------------------------------------

local function probe()
  print("=== PROBE ===")
  print("Fuel: " .. tostring(turtle.getFuelLevel()))
  print("FRONT: " .. tostring(frontName() or "(nothing)"))
  print("UP   : " .. tostring(upName()    or "(nothing)"))
  print("DOWN : " .. tostring(downName()  or "(nothing)"))
  print("Bucket slot: " .. bucketState())
  local ok, why = probeStation()
  print("Station check: " .. (ok and "OK" or ("FAIL - " .. why)))
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then print(("  %2d: %s x%d"):format(slot, item.name, item.count)) end
  end
end

-------------------------------------------------------------------------------
-- Water handling -- verified by watching the bucket, never the return value
-------------------------------------------------------------------------------

local function fillBucket()
  local state = bucketState()
  if state == "full"    then return true end
  if state == "missing" then setStatus("no bucket"); return false end
  if state == "wrong"   then setStatus("bad bucket slot"); return false end

  turtle.select(SLOT_BUCKET)
  turnAround()
  turtle.place()
  turnAround()

  if bucketState() ~= "full" then
    setStatus("no water")
    return false
  end
  return true
end

local function pourBucket()
  if bucketState() ~= "full" then return false end
  turtle.select(SLOT_BUCKET)
  turtle.place()
  if bucketState() ~= "empty" then
    setStatus("dripper full")
    return false
  end
  stats.buckets = stats.buckets + 1
  return true
end

local function drip()
  if not turtle.up() then
    setStatus("blocked above")
    return false
  end
  local ok = fillBucket() and pourBucket()
  if not turtle.down() then
    setStatus("blocked below")
    return false
  end
  return ok
end

-------------------------------------------------------------------------------
-- Steps
-------------------------------------------------------------------------------

local function ensureBlock()
  local front = frontName()
  if stageIndex(front) then return true end   -- resume whatever is there

  -- THE DIG WHITELIST: never dig a block that isn't part of our chain.
  if front then
    setStatus("unexpected block: " .. front)
    return false
  end

  turtle.select(SLOT_INPUT)
  if turtle.getItemCount(SLOT_INPUT) == 0 then
    setStatus("restocking")
    if not turtle.suckDown(64) then
      setStatus("no stone")
      return false
    end
  end

  local item = turtle.getItemDetail(SLOT_INPUT)
  if not item or item.name ~= STAGES[1].id then
    setStatus("wrong input item")
    return false
  end

  if not turtle.place() then
    setStatus("cannot place")
    return false
  end
  stats.stone = stats.stone + 1
  return true
end

local function waitForAdvance(from)
  local elapsed = 0
  while elapsed < STAGE_TIMEOUT do
    local now = stageIndex(frontName())
    if now == nil then return nil end
    if now > from then return now end
    sleep(POLL_INTERVAL)
    elapsed = elapsed + POLL_INTERVAL
  end
  return nil
end

local function convert()
  while true do
    local idx = stageIndex(frontName())
    if not idx then
      local front = frontName()
      if front then
        setStatus("unexpected block: " .. front)
      else
        setStatus("block missing")
      end
      return false
    end
    if idx == #STAGES then return true end

    setStatus("dripping " .. STAGES[idx].label)
    local advanced = false
    for attempt = 1, MAX_DRIPS do
      if attempt > 1 then
        stats.retries = stats.retries + 1
        log("Retry %d on %s", attempt - 1, STAGES[idx].label)
        setStatus("retrying " .. STAGES[idx].label)
        sleep(2)
      end
      if drip() then
        if waitForAdvance(idx) then
          advanced = true
          break
        end
        log("Poured but %s did not change", STAGES[idx].label)
      else
        if stats.status == "no bucket" or stats.status == "bad bucket slot" then
          return false
        end
        sleep(3)
      end
    end
    if not advanced then
      setStatus("stuck on " .. STAGES[idx].label)
      return false
    end
  end
end

local function harvest()
  setStatus("harvesting")
  -- only ever reached when the front block is the final whitelisted stage
  if stageIndex(frontName()) ~= #STAGES then
    setStatus("unexpected block: " .. tostring(frontName()))
    return false
  end
  turtle.select(SLOT_OUTPUT)
  local before = turtle.getItemCount(SLOT_OUTPUT)
  if not turtle.dig() then
    setStatus("cannot mine")
    return false
  end
  stats.blocks = stats.blocks + 1
  local gained = turtle.getItemCount(SLOT_OUTPUT) - before

  if not turtle.up() then
    setStatus("blocked above")
    return false
  end
  turtle.select(SLOT_OUTPUT)
  local dropped = turtle.dropUp()
  turtle.down()

  if not dropped then
    setStatus("output full")
    return false
  end
  stats.alloy = stats.alloy + math.max(gained, 0)
  return true
end

-------------------------------------------------------------------------------
-- Cycle
-------------------------------------------------------------------------------

local function isWaitState(s)
  return s == "no stone" or s == "output full" or s == "no water"
      or s == "no bucket" or s == "out of fuel"
      or s:find("misplaced") == 1 or s:find("unexpected block") == 1
end

local function cycle()
  if not recover()     then return false end
  if not ensureFuel()  then return false end
  if not ensureBlock() then return false end
  if not convert()     then return false end
  if not harvest()     then return false end
  return true
end

-------------------------------------------------------------------------------
-- Worker + bus
-------------------------------------------------------------------------------

local function resetStats()
  stats.cycles, stats.blocks, stats.buckets = 0, 0, 0
  stats.alloy, stats.stone = 0, 0
  stats.failures, stats.retries, stats.recoveries = 0, 0, 0
end

-- Operator start/stop intent survives reboots via the marker file.
-- The update handler's transient stop must NOT touch the marker.
local function setRunning(on)
  running = on
  if on then
    if fs.exists(PAUSE_MARKER) then fs.delete(PAUSE_MARKER) end
  elseif not fs.exists(PAUSE_MARKER) then
    local f = fs.open(PAUSE_MARKER, "w")
    if f then f.write("operator stop\n") f.close() end
  end
end

local busHandlers = {
  start = function() setRunning(true)  end,
  stop  = function() setRunning(false) end,
  reset = function() resetStats()      end,
  update = function()
    running = false
    wantUpdate = true
  end,
}

local function busListener()
  if not (bus and bus.isOpen()) then
    while not stopped do sleep(5) end
    return
  end
  bus.serve(busHandlers)
end

local function heartbeat()
  while not stopped do
    broadcast()
    sleep(5)
  end
end

local function worker()
  -- boot self-probe: nothing moves until the station checks out
  while true do
    local ok, why = probeStation()
    if ok then break end
    stats.idle = true
    setStatus("misplaced: " .. why)
    sleep(5)
  end
  setStatus("station ok")

  while not stopped do
    if wantUpdate then
      stats.idle = true
      setStatus("updating")
      if bus and bus.isOpen() then bus.event("updating") end
      sleep(0.5)
      shell.run("update")
      os.reboot()
    end

    if not running then
      stats.idle = true
      setStatus("paused")
      sleep(1)
    else
      stats.idle = false
      if cycle() then
        stats.cycles = stats.cycles + 1
        stats.idle = true
        setStatus("idle")
        log("Cycle %d done (%d alloy)", stats.cycles, stats.alloy)
      else
        stats.failures = stats.failures + 1
        stats.idle = true
        local wait = isWaitState(stats.status) and WAIT_ON_BLOCKED or 5
        log("Cycle failed (%s), waiting %ds", stats.status, wait)
        broadcast()
        sleep(wait)
        recover()
      end
    end
  end
  setStatus("stopped")
end

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

local args = { ... }

if args[1] == "probe" then
  probe()
  return
end

openBus()
log((bus and bus.isOpen()) and "On the bus as %s"
    or "No modem, running standalone", os.getComputerLabel() or "?")
log("Hold Ctrl+T to stop.")

parallel.waitForAny(worker, busListener, heartbeat)
