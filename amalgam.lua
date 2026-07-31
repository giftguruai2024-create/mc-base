--[[
  amalgam.lua -- FTB Skies 2 dripper automation (turtle side)

  stone -> andesite -> andesite amalgam, one bucket of water per step.

  LAYOUT
          [ OUTPUT BARREL ]
  [water] [  TURTLE  B    ] [ DRIPPER ]
          [  TURTLE  A    ] [  block  ]
          [ INPUT BARREL  ]

  UPGRADES   diamond pickaxe + wireless/ender modem
  INVENTORY  1: stone   2: empty bucket   3: empty (output)   4: coal

  USAGE
    amalgam probe   -- print what the turtle can see
    amalgam         -- run forever
    amalgam 10      -- run 10 cycles then stop
]]

-------------------------------------------------------------------------------
-- CONFIG
-------------------------------------------------------------------------------

local STAGES = {
  { id = "minecraft:stone",             label = "stone"    },
  { id = "minecraft:andesite",          label = "andesite" },
  { id = "ftb:andesite_amalgam_block",  label = "amalgam"  },
}

-- Landmarks the turtle uses to work out where it is and which way it faces
local BARREL_ID  = "sophisticatedstorage:barrel"
local DRIPPER_ID = "ftbstuff:dripper"

local SLOT_INPUT  = 1
local SLOT_BUCKET = 2
local SLOT_OUTPUT = 3

local EMPTY_BUCKET = "minecraft:bucket"
local FULL_BUCKET  = "minecraft:water_bucket"

local STAGE_TIMEOUT   = 15   -- seconds to wait for one conversion
local POLL_INTERVAL   = 0.4
local MAX_DRIPS       = 4    -- attempts at a single stage before giving up
local WAIT_ON_BLOCKED = 15   -- pause when a barrel is full/empty

local PROTO_STATS = "amalgam_stats"
local PROTO_CMD   = "amalgam_cmd"

-- Machine bus (cc.stats / cc.cmd). Optional: if bus.lua is missing the
-- turtle still runs standalone and the old panel still works.
local bus_ok, bus = pcall(require, "bus")
if not bus_ok then bus = nil end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local PAUSE_MARKER = ".paused"

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

local hasModem = false

local function openModem()
  local modem = peripheral.find("modem")
  if modem then
    rednet.open(peripheral.getName(modem))
    hasModem = true
    if bus then
      bus.open{
        label    = os.getComputerLabel() or "AmalgamTurtle",
        role     = "turtle",
        program  = "amalgam.lua",
        provides = { "amalgam" },
        accepts  = { "start", "stop", "reset", "update" },
      }
    end
  end
end

local function broadcast()
  if not hasModem then return end
  local fuel = turtle.getFuelLevel()
  stats.fuel = (fuel == "unlimited") and -1 or fuel
  stats.running = running
  rednet.broadcast(stats, PROTO_STATS)
  if bus and bus.isOpen() then bus.publish(stats) end
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

-- What is actually in the bucket slot right now?
local function bucketState()
  local item = turtle.getItemDetail(SLOT_BUCKET)
  if not item then return "missing" end
  if item.name == FULL_BUCKET  then return "full"  end
  if item.name == EMPTY_BUCKET then return "empty" end
  return "wrong"
end

-------------------------------------------------------------------------------
-- Position recovery
--
-- Works out whether the turtle is at A or B and which way it faces, then puts
-- it back to "at A, facing the conversion spot". Called before every cycle and
-- after every failure, so a half-finished cycle or a manual nudge self-heals.
-------------------------------------------------------------------------------

local function atA()
  return downName() == BARREL_ID
end

local function facingWork()
  -- at A the spot in front is either empty or one of our chain blocks
  local n = frontName()
  return n == nil or stageIndex(n) ~= nil
end

local function recover()
  -- If the dripper is in front of us we're one block too high.
  if frontName() == DRIPPER_ID then
    if turtle.down() then
      stats.recoveries = stats.recoveries + 1
      log("Recovered: dropped from B to A")
    end
  end

  -- Still not on the barrel? Try going down a level.
  if not atA() then
    if upName() == BARREL_ID then
      -- output barrel above means we're at B, but facing the wrong way
      turtle.down()
      stats.recoveries = stats.recoveries + 1
    end
  end

  if not atA() then
    setStatus("lost position")
    log("Cannot find the input barrel below -- put the turtle back at A")
    return false
  end

  -- Spin until the conversion spot is in front.
  for _ = 1, 4 do
    if facingWork() then return true end
    turtle.turnRight()
    stats.recoveries = stats.recoveries + 1
  end

  setStatus("lost facing")
  log("Cannot find the conversion spot -- check the layout")
  return false
end

-------------------------------------------------------------------------------
-- Fuel
-------------------------------------------------------------------------------

local function ensureFuel()
  local fuel = turtle.getFuelLevel()
  if fuel == "unlimited" then return true end
  if fuel < 40 then
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
-- Probe
-------------------------------------------------------------------------------

local function probe()
  print("=== PROBE ===")
  print("Fuel: " .. tostring(turtle.getFuelLevel()))
  print("FRONT: " .. tostring(frontName() or "(nothing)"))
  print("UP   : " .. tostring(upName()    or "(nothing)"))
  print("DOWN : " .. tostring(downName()  or "(nothing)"))
  print("Bucket slot: " .. bucketState())
  print("Inventory:")
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then print(("  %2d: %s x%d"):format(slot, item.name, item.count)) end
  end
end

-------------------------------------------------------------------------------
-- Water handling -- verified by watching the bucket, not the return value
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

  -- the only proof that actually worked
  if bucketState() ~= "empty" then
    setStatus("dripper full")
    return false
  end

  stats.buckets = stats.buckets + 1
  return true
end

-- Go up, water the dripper, come back down. Always returns to A.
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
  if stageIndex(frontName()) then return true end   -- resume whatever is there

  if frontName() then
    turtle.select(SLOT_OUTPUT)
    turtle.dig()
  end

  turtle.select(SLOT_INPUT)
  if turtle.getItemCount(SLOT_INPUT) == 0 then
    setStatus("restocking")
    if not turtle.suckDown(64) then
      setStatus("no stone")
      return false
    end
  end

  if turtle.getItemDetail(SLOT_INPUT).name ~= STAGES[1].id then
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

-- Wait for the block to move forward at least one stage. Returns the new index,
-- or nil on timeout.
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

-- Drive the block to the last stage, retrying individual drips.
local function convert()
  while true do
    local idx = stageIndex(frontName())

    if not idx then
      setStatus("block missing")
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
        -- drip() already set a specific status; a missing bucket or dry
        -- water source will not fix itself by retrying immediately
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

-- Faults where retrying instantly is pointless -- wait for the player instead
local function isWaitState(s)
  return s == "no stone" or s == "output full" or s == "no water"
      or s == "no bucket" or s == "out of fuel"
end

local function cycle()
  if not recover()    then return false end
  if not ensureFuel() then return false end
  if not ensureBlock() then return false end
  if not convert()    then return false end
  if not harvest()    then return false end
  return true
end

-------------------------------------------------------------------------------
-- Worker + listener
-------------------------------------------------------------------------------

local limit = nil

local function worker()
  while not stopped do
    if wantUpdate then
      stats.idle = true
      setStatus("updating")
      if bus and bus.isOpen() then bus.event("updating") end
      sleep(0.5)                -- let the event leave the modem
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

      if limit and stats.cycles >= limit then
        setStatus("finished")
        return
      end
    end
  end
  setStatus("stopped")
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

local function resetStats()
  stats.cycles, stats.blocks, stats.buckets = 0, 0, 0
  stats.alloy, stats.stone = 0, 0
  stats.failures, stats.retries, stats.recoveries = 0, 0, 0
end

local busHandlers = {
  start = function() setRunning(true)  end,
  stop  = function() setRunning(false) end,
  reset = function() resetStats()    end,
  -- Only requests. The worker loop performs the update when idle -
  -- never yank the rug out from under a moving turtle.
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

local function listener()
  if not hasModem then
    while not stopped do sleep(5) end
    return
  end
  while not stopped do
    local _, msg = rednet.receive(PROTO_CMD, 5)
    if type(msg) == "table" then
      if msg.cmd == "stop" then
        setRunning(false)
      elseif msg.cmd == "start" then
        setRunning(true)
      elseif msg.cmd == "reset" then
        resetStats()
      end
    end
    broadcast()
  end
end

local function heartbeat()
  while not stopped do
    broadcast()
    sleep(5)
  end
end

-------------------------------------------------------------------------------
-- Entry point
-------------------------------------------------------------------------------

local args = { ... }

if args[1] == "probe" then
  probe()
  return
end

limit = tonumber(args[1])

openModem()
log(hasModem and "Modem found, broadcasting stats" or "No modem, running standalone")
log("%s -> %s", STAGES[1].label, STAGES[#STAGES].label)
log("Hold Ctrl+T to stop.")

parallel.waitForAny(worker, listener, busListener, heartbeat)
