--[[
  bus.lua -- shared machine bus for a ComputerCraft base

  Every machine that loads this becomes discoverable, reports its stats, and
  accepts commands, using one common set of protocols. Two machines that both
  speak the bus can be connected without writing any bespoke networking.

  USAGE (a worker machine)

    local bus = require("bus")

    bus.open{
      label = "TreeCutter",
      role  = "turtle",
      provides = { "logs", "saplings" },
      accepts  = { "start", "stop", "reset" },
    }

    local handlers = {
      start = function() running = true  end,
      stop  = function() running = false end,
      reset = function() resetStats()    end,
    }

    parallel.waitForAny(
      worker,
      function() bus.serve(handlers) end,
      function() bus.heartbeat(function() return stats end) end
    )

  USAGE (a dashboard)

    local bus = require("bus")
    bus.open{ label = "BasePanel", role = "display" }

    local machines = bus.scan(3)          -- who is out there right now
    bus.command("TreeCutter", "stop")     -- tell one machine
    bus.command("*", "stop")              -- tell everything

    bus.watch(function(report) ... end)   -- live stats from every machine

  PROTOCOLS

    cc.discover   whois / iam        identity exchange
    cc.stats      periodic reports   every machine publishes
    cc.cmd        addressed commands target = label, id, or "*"
    cc.event      notable moments    finished, fault, needs input

  Put bus.lua in the same directory as the program that requires it, and list it
  in files.txt so the updater pulls it everywhere.
]]

local bus = {}

bus.PROTO_DISCOVER = "cc.discover"
bus.PROTO_STATS    = "cc.stats"
bus.PROTO_CMD      = "cc.cmd"
bus.PROTO_EVENT    = "cc.event"

bus.VERSION = "1"

local identity = nil
local opened   = false
local fingerprintCache = nil

-------------------------------------------------------------------------------
-- Joining
-------------------------------------------------------------------------------

--- Open a modem and register this machine's identity.
-- info = { label, role, provides, accepts, location }
-- Returns true, or false plus a reason.
function bus.open(info)
  info = info or {}

  local modem = peripheral.find("modem")
  if not modem then
    return false, "no modem attached"
  end
  rednet.open(peripheral.getName(modem))
  opened = true

  local label = info.label
             or os.getComputerLabel()
             or ("machine_" .. os.getComputerID())

  -- keep the in-game label in sync so the machine is identifiable by hand too
  if os.getComputerLabel() ~= label then
    os.setComputerLabel(label)
  end

  identity = {
    id        = os.getComputerID(),
    label     = label,
    role      = info.role or "unknown",
    provides  = info.provides or {},
    accepts   = info.accepts or {},
    parent    = info.parent,
    location  = info.location,
    turtle    = turtle ~= nil,
    version   = bus.VERSION,
    program   = info.program,
    startedAt = os.epoch("utc"),
  }

  fingerprintCache = bus.fingerprint()
  return true
end

function bus.isOpen() return opened end
function bus.identity() return identity end

local function require_open()
  if not opened then
    error("bus.open() must be called first", 0)
  end
end

-------------------------------------------------------------------------------
-- Code fingerprints
--
-- FNV-1a, 32-bit, 8 hex chars. Not cryptographic - we only need "did this
-- file change". CC:Tweaked is Lua 5.2: no native bitwise operators, and all
-- numbers are doubles, so the multiply is split into 16-bit halves to keep
-- every intermediate far below 2^53.
-------------------------------------------------------------------------------

function bus.hashString(data)
  local h = 2166136261
  for i = 1, #data do
    h = bit32.bxor(h, data:byte(i))
    local lo = h % 65536
    local hi = math.floor(h / 65536)
    h = (lo * 16777619 + ((hi * 16777619) % 65536) * 65536) % 4294967296
  end
  return ("%08x"):format(h)
end

function bus.hashFile(path)
  local f = fs.open(path, "r")
  if not f then return nil end
  local data = f.readAll()
  f.close()
  return bus.hashString(data)
end

--- Filenames listed in the local files.txt (written by update.lua).
function bus.trackedFiles()
  local f = fs.open("files.txt", "r")
  if not f then return {} end
  local body = f.readAll()
  f.close()
  local out = {}
  for line in body:gmatch("[^\r\n]+") do
    local name = line:match("^%s*(.-)%s*$")
    if name ~= "" and name:sub(1, 1) ~= "#" then
      out[#out + 1] = name
    end
  end
  return out
end

--- { ["amalgam.lua"] = "a31f9c04", ... } for every tracked file that exists.
function bus.fingerprint()
  local out = {}
  for _, name in ipairs(bus.trackedFiles()) do
    out[name] = bus.hashFile(name)
  end
  return out
end

-------------------------------------------------------------------------------
-- Publishing
-------------------------------------------------------------------------------

--- Broadcast a stats table. Call whenever state changes, plus on a heartbeat.
function bus.publish(stats)
  if not opened then return end
  rednet.broadcast({
    from  = identity.label,
    id    = identity.id,
    role  = identity.role,
    parent = identity.parent,
    stats = stats,
    fingerprint = fingerprintCache,
    t     = os.epoch("utc"),
  }, bus.PROTO_STATS)
end

--- Broadcast a notable moment. Other machines can react to these.
-- e.g. bus.event("output_full") or bus.event("finished", { count = 64 })
function bus.event(name, data)
  if not opened then return end
  rednet.broadcast({
    from  = identity.label,
    id    = identity.id,
    event = name,
    data  = data,
    t     = os.epoch("utc"),
  }, bus.PROTO_EVENT)
end

--- Run forever, publishing stats every `interval` seconds.
-- getStats is a function returning the current stats table.
function bus.heartbeat(getStats, interval)
  require_open()
  while true do
    bus.publish(getStats and getStats() or {})
    sleep(interval or 5)
  end
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

--- Send a command. target is a label, a computer id, or "*" for everything.
function bus.command(target, cmd, args)
  require_open()
  rednet.broadcast({
    target = target,
    cmd    = cmd,
    args   = args,
    from   = identity.label,
  }, bus.PROTO_CMD)
end

local function addressedToMe(msg)
  return msg.target == "*"
      or msg.target == identity.label
      or msg.target == identity.id
      or msg.target == nil
end

--- Run forever, answering discovery and routing commands to handlers.
-- handlers = { start = function(args, sender) end, ... }
-- Pass an onEvent function to also react to other machines' events.
function bus.serve(handlers, onEvent)
  require_open()
  handlers = handlers or {}

  while true do
    local sender, msg, proto = rednet.receive(nil, 5)

    if type(msg) == "table" then
      if proto == bus.PROTO_DISCOVER and msg.op == "whois" then
        local reply = {}
        for k, v in pairs(identity) do reply[k] = v end
        reply.op = "iam"
        rednet.send(sender, reply, bus.PROTO_DISCOVER)

      elseif proto == bus.PROTO_CMD and addressedToMe(msg) then
        local handler = handlers[msg.cmd]
        if handler then
          local ok, err = pcall(handler, msg.args, sender)
          if not ok then
            bus.event("handler_error", { cmd = msg.cmd, error = tostring(err) })
          end
        end

      elseif proto == bus.PROTO_EVENT and onEvent and msg.from ~= identity.label then
        pcall(onEvent, msg)
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Discovery
-------------------------------------------------------------------------------

--- Ask who is out there. Returns a list of identity tables.
function bus.scan(timeout)
  require_open()
  rednet.broadcast({ op = "whois" }, bus.PROTO_DISCOVER)

  local found, seen = {}, {}
  local deadline = os.clock() + (timeout or 3)

  while os.clock() < deadline do
    local sender, msg, proto = rednet.receive(bus.PROTO_DISCOVER, 0.5)
    if proto == bus.PROTO_DISCOVER
       and type(msg) == "table"
       and msg.op == "iam"
       and not seen[msg.id] then
      seen[msg.id] = true
      msg.senderId = sender
      found[#found + 1] = msg
    end
  end

  table.sort(found, function(a, b) return (a.label or "") < (b.label or "") end)
  return found
end

-------------------------------------------------------------------------------
-- Watching
-------------------------------------------------------------------------------

--- Run forever, calling onReport(report) for every stats broadcast on the base.
-- Also answers discovery so a dashboard shows up in scans.
-- onEvent, if given, receives cc.event messages.
function bus.watch(onReport, onEvent)
  require_open()
  while true do
    local sender, msg, proto = rednet.receive(nil, 5)

    if type(msg) == "table" then
      if proto == bus.PROTO_STATS and onReport then
        pcall(onReport, msg)

      elseif proto == bus.PROTO_EVENT and onEvent then
        pcall(onEvent, msg)

      elseif proto == bus.PROTO_DISCOVER and msg.op == "whois" then
        local reply = {}
        for k, v in pairs(identity) do reply[k] = v end
        reply.op = "iam"
        rednet.send(sender, reply, bus.PROTO_DISCOVER)
      end
    end
  end
end

--- Keeps a live table of every machine seen, with staleness tracking.
-- Returns the table plus a function to test whether a machine is online.
function bus.registry(offlineAfter)
  offlineAfter = offlineAfter or 20
  local seen = {}

  local function record(msg)
    seen[msg.from] = {
      label       = msg.from,
      id          = msg.id,
      role        = msg.role,
      parent      = msg.parent,
      stats       = msg.stats,
      fingerprint = msg.fingerprint,
      lastSeen    = os.clock(),
    }
  end

  local function online(label)
    local m = seen[label]
    return m ~= nil and (os.clock() - m.lastSeen) < offlineAfter
  end

  return seen, record, online
end

return bus
