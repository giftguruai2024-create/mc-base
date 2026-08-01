# Amalgam Farm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A four-turtle andesite-alloy farm under one headless controller, appearing on the Master as a single foldable `[+] AmalgamFarm` row — and the hive pattern (parent tags + fold UI) that every future self-contained system reuses.

**Architecture:** One bus, no new plumbing: children declare `parent = "AmalgamFarm"`; the Master groups rows by parent with `[+]`/`[-]` folding and a worst-of-children summary. The turtle program is harvested from the proven `amalgam.lua` (git `f9532f0`, the last version before retirement) with a new safety layer: boot self-probe, dig whitelist, misplaced-waits-for-human. The controller meters two Functional Storage drawers over wired modems; item pipes do all logistics. UPDATE ALL is untouched.

**Tech Stack:** CC:Tweaked (MC 1.21.1), Lua 5.2 + bit32, existing bus/update/master infrastructure, repo `giftguruai2024-create/mc-base` on `main`. Specs: vault notes `08 - Machines/M - Amalgam Farm.md` and `04 - ComputerCraft/The hive pattern.md` (vault at `C:\Users\Trevo\OneDrive\Desktop\FTB Skies 2 Aero`). Build diagrams: `amalgam-station.html` / `amalgam-farm-overview.html` next to the spec.

## Global Constraints

- **Lua dialect:** CC:Tweaked ≈ Lua 5.2. No native bitwise ops, no `//`. `bit32` only.
- **Confirmed IDs (pack file — trust these, probe anything else):** `minecraft:stone` → `minecraft:andesite` → `ftb:andesite_amalgam_block` under `ftbstuff:dripper`; barrels are `sophisticatedstorage:barrel`. Conversions are effectively instant — never wait for one specific next stage.
- **Turtle safety rules (from the spec — non-negotiable):** the turtle only ever digs the three whitelisted stage blocks; any other block in the work spot → `unexpected block: <id>`, halt-and-wait. Boot self-probe before any work; failure → `misplaced: <what>`, wait for a human. Effect-checked actions only (bucket state, inspection) — return values are never trusted.
- **Worker contract (every machine):** heartbeat carries `fingerprint`, `stats.idle` (safe to reboot), `stats.running` (operator intent); `update` handler only sets a flag; operator stop/start intent persists across reboots via a `.paused` marker; the `update` handler's transient stop never touches the marker.
- **Hive contract:** `parent` is optional identity; parented machines stay full bus citizens; `UPDATE ALL` iterates everyone flat and MUST NOT change in this plan.
- **Drawer probe gates Task 8's wiring config:** Functional Storage drawers are unverified peripherals. No drawer peripheral names go into config until the in-game probe reports them.
- **Verification is in-game** (milestones: Tasks 6, 7, 8). Local checks: `py tools\check.py` before every commit.
- **Commits:** end every message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Work on `main` (standing consent); push only at the plan's push steps.
- **Working directory:** `C:\Users\Trevo\Code\mc-base`.

---

### Task 1: bus.lua — the parent field

**Files:**
- Modify: `bus.lua`

**Interfaces:**
- Produces: `bus.open{ parent = "Label" }` stores `identity.parent`; every stats broadcast carries `parent`; `bus.registry`'s record stores `msg.parent` on the machine entry. Consumed by Task 2's grouping and Task 3's turtle identity.

- [ ] **Step 1: identity**

In `bus.open`, add one line to the `identity = { ... }` table, after `accepts`:

```lua
    parent    = info.parent,
```

- [ ] **Step 2: broadcast**

In `bus.publish`, add one field to the broadcast table, after `role`:

```lua
    parent = identity.parent,
```

- [ ] **Step 3: registry**

In `bus.registry`'s `record` function, add after `role = msg.role,`:

```lua
      parent      = msg.parent,
```

- [ ] **Step 4: Gate + commit**

Run: `py tools\check.py bus.lua` → `ok`.

```bash
git add bus.lua
git commit -m "feat: optional parent field rides the bus identity and heartbeat

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: master.lua — foldable hive groups

**Files:**
- Modify: `master.lua` (list building in `redraw`, fold state, `onTouch`, `drawDetail` generic stats)

**Interfaces:**
- Consumes: `machines[label].parent` from Task 1; existing `sortedLabels`, `codeState`, `isOnline`, `flow`, `CODE_COLOURS`, `listRow`, `rowByY`, `selected`.
- Produces: `folded` (label → bool, default folded), `rowFold` (y → group label, fold-toggle hit map), `childrenOf(label)`, `isGroup(label)`, `groupSummary(label)`. `UPDATE ALL` and `countStates` are untouched.

- [ ] **Step 1: State**

Next to the existing `local rowByY = {}` declaration add:

```lua
local rowFold = {}         -- y -> group label ([+]/[-] tap zone)
local folded  = {}         -- group label -> collapsed? (default true, set lazily)
```

- [ ] **Step 2: Group helpers**

Insert directly after the `sortedLabels` function:

```lua
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
```

- [ ] **Step 3: Rework the list loop in `redraw`**

At the top of `redraw`, next to `rowByY = {}`, add `rowFold = {}`.

Replace the existing machine-list loop (`for _, label in ipairs(sortedLabels()) do ... end` — the one that calls `listRow` per machine, after the master's own row) with:

```lua
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
```

(The controller's own machine row is intentionally absorbed into the group row — `groupSummary` counts it, and selecting the group row opens the controller's detail pane.)

- [ ] **Step 4: Fold toggle in `onTouch`**

In `onTouch`, immediately BEFORE the `if rowByY[y] then selected = rowByY[y] end` line, add:

```lua
  if rowFold[y] and x <= 5 then
    folded[rowFold[y]] = not folded[rowFold[y]]
    return
  end
```

- [ ] **Step 5: Generic stats in `drawDetail`**

In `drawDetail`, in the non-self branch, after the existing `if st.cycles then statRow("Cycles", st.cycles) end` line, add:

```lua
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
```

- [ ] **Step 6: Gate + commit**

Run: `py tools\check.py master.lua` → `ok`.

```bash
git add master.lua
git commit -m "feat: hive groups - foldable parent rows, extras, generic detail stats

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: amalgamturtle.lua — the smart station turtle

**Files:**
- Create: `amalgamturtle.lua`

**Interfaces:**
- Consumes: `bus.lua` (open/serve/heartbeat/event with `parent`), the retired program for its proven logic: run `git show f9532f0:amalgam.lua` and keep its station mechanics.
- Produces: the program below. Label comes from the computer (`label set AmalgamT1` … `T4`); all four run identical code.

- [ ] **Step 1: Read the proven base**

Run: `git show f9532f0:amalgam.lua > nul` (or view it) — the implementer must read it once; the new program reuses its `bucketState`/`fillBucket`/`pourBucket`/`drip`/`waitForAdvance`/`convert`/`harvest`/`recover` logic near-verbatim. The differences are exactly: legacy protocol removed, boot self-probe added, dig whitelist added, `parent` identity, program name.

- [ ] **Step 2: Create `amalgamturtle.lua` with exactly this code**

```lua
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
```

- [ ] **Step 3: Gate + commit**

Run: `py tools\check.py amalgamturtle.lua` → `ok`.

```bash
git add amalgamturtle.lua
git commit -m "feat: smart station turtle - self-probe, dig whitelist, hive child

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: amalgamfarm.lua — the controller

**Files:**
- Create: `amalgamfarm.lua`

**Interfaces:**
- Consumes: `bus` (open/serve/heartbeat/command/event), the two drawers over wired modems (peripheral names filled in at Task 8 after the probe).
- Produces: the hive controller — forwards start/stop to children, meters the drawers, publishes `stored`/`stone`/`rate` + `extras`.

- [ ] **Step 1: Create `amalgamfarm.lua` with exactly this code**

```lua
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
```

- [ ] **Step 2: Gate + commit**

Run: `py tools\check.py amalgamfarm.lua` → `ok`.

```bash
git add amalgamfarm.lua
git commit -m "feat: amalgam farm controller - drawer metering, child forwarding

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Ship — manifest + push

**Files:**
- Modify: `files.txt`

- [ ] **Step 1: Add the two programs**

Append to `files.txt` (after `tasks.lua`):

```
amalgamturtle.lua
amalgamfarm.lua
```

- [ ] **Step 2: Full gate, commit, push, verify**

Run: `py tools\check.py` → all `ok`.

```bash
git add files.txt
git commit -m "feat: ship the amalgam farm programs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

Then: `Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/files.txt?cb=1" | Select-Object -ExpandProperty Content` → eight entries including both new programs.

---

### Task 6: MILESTONE — hive layer regression check (user, in-game, ~2 minutes)

- [ ] **Step 1:** On the Master, tap RESCAN. Checkpoint: Master and TaskBoard show STALE (the manifest grew — expected).
- [ ] **Step 2:** Tap UPDATE ALL. Checkpoint: both update and come back `current`; the screen looks EXACTLY as before — flat rows, no groups (no machine declares a parent yet), UPDATE ALL unchanged. That's the regression check for Tasks 1–2 passing.

---

### Task 7: MILESTONE — one smart station (user, in-game)

- [ ] **Step 1: Build station 1** from the vault diagram (`amalgam-station.html` — rotate it, use the explode slider): input barrel, position A above it, conversion spot in front of A, dripper above the spot, water source behind B, output barrel above B.
- [ ] **Step 2: Prep the turtle** — diamond pickaxe + wireless modem equipped, inventory 1: stone, 2: empty bucket, 4: coal. Place at position A facing the conversion spot. **`label set AmalgamT1` BEFORE anything else** — an unlabelled turtle broadcasts as `UNLABELLED_<id>` and is deliberately kept out of the hive group (and a label set later only takes effect properly if you set it before the program's first run; if you forget, `label set` the right name and reboot). Then the standard bootstrap (`wget .../update.lua update`, `update`), `edit startup` → `shell.run("update")` / `shell.run("amalgamturtle")`.
- [ ] **Step 3: Self-probe test (do this BEFORE letting it run):** take the bucket out of slot 2, `reboot`. Checkpoint: it does NOT move; terminal and Master show `misplaced: no bucket in slot 2`. Put the bucket back. Checkpoint: within ~5s it reports `station ok` and starts.
- [ ] **Step 4: Whitelist test:** `Ctrl+T`, place a cobblestone (or anything non-chain) in the conversion spot, run `amalgamturtle`. Checkpoint: after `station ok`... it halts with `unexpected block: <id>` and does NOT dig it. Remove the block; it resumes on its own within ~15s.
- [ ] **Step 5: Let it work.** Checkpoint: full cycles complete, alloy lands in the output barrel, and on the Master a `[+] AmalgamFarm  1 up` group row appears (the parent tag at work — controller not built yet, so the group is just its one child). Unfold it; select the turtle; STOP/START from the detail pane.
- [ ] **Step 6:** Vault: record the milestone in `M - Amalgam Farm.md`; any fight → a lesson note.

---

### Task 8: MILESTONE — the full farm (user in-game + one config commit)

- [ ] **Step 1: Build stations 2–4** beside station 1 (adjacent, identical). Prep turtles as in Task 7 with labels `AmalgamT2`–`T4`. Checkpoint: group row reads `4 up`.
- [ ] **Step 2: Drawers + pipes:** place the stone drawer and alloy drawer at the controller end (see `amalgam-farm-overview.html`), run item pipes: stone drawer → all four input barrels; all four output barrels → alloy drawer. Hand-fill the stone drawer. Checkpoint: input barrels fill on their own; harvested alloy reaches the alloy drawer. **Verify the pipes feed ALL four input barrels**, not just the first.
- [ ] **Step 3: Controller computer:** Advanced Computer at the row's end, wireless modem on a free face, wired modems touching each drawer + cable to the computer (right-click each modem — it prints the drawer's network name; **write both names down**). `label set AmalgamFarm`, bootstrap, but don't start it yet.
- [ ] **Step 4: The drawer probe:** on the controller run `lua`, then `peripheral.getNames()` — confirm the two drawer names appear. Wrap one: `p = peripheral.wrap("<name>")`, `p.list()` — confirm it returns items with sane counts. `exit()`. Report the two names and what `list()` looked like back to the PC session.
- [ ] **Step 5: Config commit (PC):** set `STONE_DRAWER` and `ALLOY_DRAWER` in `amalgamfarm.lua` to the probed names; gate; commit (`feat: wire amalgam farm drawer names` + trailer); push. In-game on the controller: `update`, `edit startup` → `shell.run("update")` / `shell.run("amalgamfarm")`, `reboot`.
- [ ] **Step 6: Verify the hive end to end:** Master shows `[+] AmalgamFarm  5 up  current` (controller + 4 turtles). Unfold: children + dimmed `(drawers) wired` row. Select the group row: detail pane shows Stored / Stone / Rate. STOP on the group row pauses all four turtles; START resumes them. Run the stone drawer low → status `stone low`. Push any trivial change → UPDATE ALL walks every farm machine through stop → update → restore, exactly as it does the flat machines.
- [ ] **Step 6b: The pause-respect regression test** (guards the fan-out fix): STOP just one turtle from its detail pane, then run a full UPDATE ALL over the stale farm. Checkpoint: every machine updates, and the paused turtle comes back **still paused** — the controller's restore must not have overridden it. START it when done.
- [ ] **Step 7: Vault records:** `M - Amalgam Farm.md` → `status: running` + what was seen; `The hive pattern` → `status: proven`; machine notes for the controller + one turtle note covering all four; `Machine index` + `Network map`; code notes for both programs; `rollcall -save` + commit `machines.json`; harvest new components (boot self-probe, dig whitelist, drawer metering, group fold UI) per cc-components; lessons for anything that took two attempts.

---

## Self-Review (completed at plan time)

- **Spec coverage:** parent field (T1), fold UI + worst-of + extras + generic detail stats (T2), smart turtle with all five safety rules (T3 — self-probe, whitelist in `ensureBlock`/`convert`/`harvest`, misplaced-waits, effect-checks and fault classes inherited), controller with drawer metering / rate / stone-low / forwarding (T4), deploy (T5), regression + station + farm milestones incl. the drawer probe gating the config commit (T6–T8), vault + registry records (T8.7).
- **Placeholder scan:** `STONE_DRAWER/ALLOY_DRAWER = nil` are deliberate runtime config gated on the in-game probe (the program degrades to `drawers not configured` until Task 8 fills them) — not placeholders in the plan sense.
- **Type consistency:** `machines[label].parent` (T1) matches T2's grouping; `stats.extras` shape `{ {name, link} }` matches T2's renderer; turtle statuses `misplaced: ...`/`unexpected block: ...` match `isWaitState`'s prefix checks; `CHILDREN` labels match Task 7/8's `label set` names; both new programs use the `.paused` contract.
- **UPDATE ALL untouched:** T2 changes rendering and touch only; `updateAll`, `countStates`, `waitUntil` are not edited by any task.
