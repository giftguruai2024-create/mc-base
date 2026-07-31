# Master Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 4×4 monitor "Master Control" screen that shows every machine on the base, marks each CURRENT or STALE against the GitHub repo, and safely pushes updates to all of them with one button.

**Architecture:** Every machine hashes its own files (FNV-1a via `bus.lua`) and reports the hashes inside its existing `cc.stats` heartbeat. A new `master.lua` fetches the same files from GitHub, hashes them identically, and compares. UPDATE ALL is stop → wait-for-idle → update → reboot → restore-prior-state, never broadcast-and-hope. **The existing Base Panel computer becomes the Master**: its monitor wall expands to 4×4 and its startup switches from `panel` to `master` at milestone 2. `amalgam.lua` is ported onto the bus while *temporarily* keeping its legacy protocol — the old panel is the only screen between milestones 1 and 2 — and both the legacy protocol and `panel.lua` are deleted in the milestone-3 cleanup.

**Tech Stack:** CC:Tweaked (Minecraft 1.21.1, NeoForge), Lua 5.2 + `bit32`, rednet over ender/wireless modems, GitHub raw fetches for deploy. Spec: the vault note `08 - Machines/M - Master Control.md` in the Obsidian vault at `C:\Users\Trevo\OneDrive\Desktop\FTB Skies 2 Aero`.

## Global Constraints

- **Lua dialect:** CC:Tweaked ≈ Lua 5.2. NO native bitwise operators (`~`, `&`, `|`, `>>`), NO integer division `//`. Use `bit32.bxor` etc. Numbers are doubles — no intermediate value may reach 2^53 (the FNV multiply below is split for exactly this reason).
- **Repo:** `giftguruai2024-create/mc-base`, branch `main`, public. Raw base URL: `https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/`.
- **Line endings:** everything stored LF (already true; Task 1 pins it with `.gitattributes`). Both sides of the hash comparison depend on this.
- **Monitor sizes are never hardcoded.** Read `mon.getSize()` at runtime, re-layout on `monitor_resize`.
- **Worker interface contract** (produced in Tasks 2–4, consumed by Task 7+): every bus worker publishes `stats.idle` (boolean — safe to reboot right now) and `stats.running` (boolean — operator intent), its heartbeat message carries `fingerprint = { [filename] = "8-hex-hash" }`, and its `update` command handler only *requests*: the worker's main loop performs `shell.run("update")` + `os.reboot()` at a safe idle point.
- **Verification is in-game.** Local checks are Python-oracle vectors and a syntax gate; nothing is marked proven until seen working on the monitor (the vault's verification loop). Milestone checkpoints are Tasks 6, 11, and 13.
- **Commits:** end every commit message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Working directory for all tasks:** `C:\Users\Trevo\Code\mc-base` (Windows, PowerShell-compatible commands).

---

### Task 1: Repo hygiene — .gitattributes and this plan

**Files:**
- Create: `.gitattributes`
- Create: `docs/superpowers/plans/2026-07-30-master-control.md` (this file — already written)

**Interfaces:**
- Produces: guaranteed-LF storage for every text file in the repo. Every later hash comparison assumes it.

- [ ] **Step 1: Write `.gitattributes`**

```gitattributes
* text=auto eol=lf
*.lua text eol=lf
files.txt text eol=lf
```

- [ ] **Step 2: Verify nothing renormalizes (all files are already LF)**

Run: `git add --renormalize . ; git status --short`
Expected: only `.gitattributes` and `docs/` appear as new; NO existing `.lua` file shows as modified. If one does, stop and inspect it — do not commit a renormalization silently.

- [ ] **Step 3: Commit**

```bash
git add .gitattributes docs/
git commit -m "chore: pin LF line endings and add master-control plan

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Local Lua syntax gate (tools/check.py)

A pushed syntax error costs a full GitHub→in-game round trip. This tool catches it on the PC in one second.

**Files:**
- Create: `tools/check.py`

**Interfaces:**
- Produces: `py tools\check.py` — exits 0 when every `*.lua` in the repo parses, 1 otherwise. Every later task runs this before committing.

- [ ] **Step 1: Install the parser**

Run: `py -m pip install luaparser`
Expected: `Successfully installed ...` (or already satisfied). If the install fails, skip this task and note in the commit log that the syntax gate is unavailable — in-game selftest still covers correctness.

- [ ] **Step 2: Write the failing check (tool doesn't exist yet)**

Run: `py tools\check.py`
Expected: FAIL — `can't open file ... tools\\check.py`

- [ ] **Step 3: Write `tools/check.py`**

```python
import sys, glob, os
from luaparser import ast

patterns = sys.argv[1:] or ["*.lua"]
files = []
for p in patterns:
    files.extend(glob.glob(p))
fail = 0
for f in sorted(files):
    with open(f, encoding="utf-8") as fh:
        src = fh.read()
    try:
        ast.parse(src)
        print(f"ok    {f}")
    except Exception as e:
        print(f"FAIL  {f}: {e}")
        fail = 1
sys.exit(fail)
```

- [ ] **Step 4: Run it on the current repo — must pass**

Run: `py tools\check.py`
Expected: `ok` for all seven current `.lua` files, exit code 0.

- [ ] **Step 5: Prove it catches a real error**

Run: `Set-Content -Encoding utf8 broken.lua "local x = ="; py tools\check.py broken.lua; Remove-Item broken.lua`
Expected: `FAIL  broken.lua: ...` and exit code 1.

- [ ] **Step 6: Commit**

```bash
git add tools/check.py
git commit -m "chore: add local Lua syntax gate

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: bus.lua fingerprints + selftest.lua

**Files:**
- Modify: `bus.lua` (add hashing section after the `Joining` section, ~line 128; extend `bus.open`, `bus.publish`, `bus.registry`)
- Create: `selftest.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `bus.hashString(data) -> "8-hex"` — FNV-1a 32-bit of a string.
  - `bus.hashFile(path) -> "8-hex" | nil` — nil if the file doesn't exist.
  - `bus.trackedFiles() -> { "name", ... }` — parsed from local `files.txt`; `{}` if missing.
  - `bus.fingerprint() -> { [name] = "8-hex" }` — hash of every tracked file that exists.
  - `bus.open` caches `bus.fingerprint()` once at boot; `bus.publish` attaches it to every stats broadcast as `fingerprint`; `bus.registry`'s record function stores `msg.fingerprint` on each machine entry.
  - `selftest.lua` — run `selftest` on any machine; prints PASS/FAIL against known vectors.

The test vectors below were computed with an independent Python oracle on 2026-07-30 (`h=2166136261; h ^= byte; h = (h*16777619) % 2**32`):

| input | FNV-1a 32 |
|---|---|
| `""` | `811c9dc5` |
| `"a"` | `e40c292c` |
| `"abc"` | `1a47e90b` |
| `"hello\nworld\n"` | `3d3d5389` |
| `"The quick brown fox"` | `ae4d67e2` |

- [ ] **Step 1: Write the test first — `selftest.lua`**

```lua
--[[
  selftest.lua -- verify bus hashing against known FNV-1a vectors.
  Run on any machine:  selftest
  Every machine and the master MUST produce identical hashes for identical
  bytes, or the whole STALE/CURRENT comparison silently lies.
]]

local bus = require("bus")

local vectors = {
  { name = "empty",     data = "",                     want = "811c9dc5" },
  { name = "a",         data = "a",                    want = "e40c292c" },
  { name = "abc",       data = "abc",                  want = "1a47e90b" },
  { name = "two-lines", data = "hello\nworld\n",       want = "3d3d5389" },
  { name = "fox",       data = "The quick brown fox",  want = "ae4d67e2" },
}

local failed = 0
for _, v in ipairs(vectors) do
  local got = bus.hashString(v.data)
  if got == v.want then
    print(("ok    %-10s %s"):format(v.name, got))
  else
    failed = failed + 1
    print(("FAIL  %-10s got %s want %s"):format(v.name, got, v.want))
  end
end

local fp = bus.fingerprint()
local n = 0
for name, h in pairs(fp) do
  n = n + 1
  print(("file  %-14s %s"):format(name, h))
end
if n == 0 then
  print("note: fingerprint empty - no files.txt on this machine yet")
end

print(failed == 0 and "SELFTEST PASS" or ("SELFTEST FAIL (" .. failed .. ")"))
```

- [ ] **Step 2: Verify it fails against current bus.lua**

Run: `py tools\check.py selftest.lua`
Expected: `ok` (it parses). It cannot *run* on the PC — the failure we care about is that `bus.hashString` does not exist yet, which the in-game run at Task 6 would report as `attempt to call nil`. Proceed knowing the test exists before the implementation.

- [ ] **Step 3: Add the hashing section to `bus.lua`**

Insert after the `Joining` section (after the `require_open` function, before `-- Publishing`):

```lua
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
```

- [ ] **Step 4: Cache the fingerprint at boot and attach it to every publish**

In `bus.open`, add a cache. Near the top of the file, next to `local identity = nil`:

```lua
local fingerprintCache = nil
```

At the end of `bus.open`, just before `return true`:

```lua
  fingerprintCache = bus.fingerprint()
```

In `bus.publish`, add one field to the broadcast table:

```lua
  rednet.broadcast({
    from  = identity.label,
    id    = identity.id,
    role  = identity.role,
    stats = stats,
    fingerprint = fingerprintCache,
    t     = os.epoch("utc"),
  }, bus.PROTO_STATS)
```

Machines always reboot after an update, so a boot-time cache is always fresh — no re-hash on the heartbeat path.

- [ ] **Step 5: Store the fingerprint in the registry**

In `bus.registry`, extend `record`:

```lua
  local function record(msg)
    seen[msg.from] = {
      label       = msg.from,
      id          = msg.id,
      role        = msg.role,
      stats       = msg.stats,
      fingerprint = msg.fingerprint,
      lastSeen    = os.clock(),
    }
  end
```

- [ ] **Step 6: Syntax gate**

Run: `py tools\check.py`
Expected: all files `ok`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add bus.lua selftest.lua
git commit -m "feat: file fingerprints in bus heartbeat + selftest vectors

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: update.lua writes the manifest to disk

`bus.trackedFiles()` reads a local `files.txt`, but the updater currently only fetches the manifest into memory. One line fixes the gap.

**Files:**
- Modify: `update.lua` (after the manifest parse, ~line 111)

**Interfaces:**
- Produces: every machine that has run `update` has a local `files.txt` matching the manifest it was updated from.

- [ ] **Step 1: Add the write**

Immediately after the `files` list is parsed and the empty check passes (after the `if #files == 0 ... return end` block), add:

```lua
-- Save the manifest so bus.trackedFiles() knows what to fingerprint.
writeLocal("files.txt", manifest)
```

- [ ] **Step 2: Syntax gate**

Run: `py tools\check.py update.lua`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add update.lua
git commit -m "feat: updater saves files.txt locally for fingerprinting

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Port amalgam.lua onto the bus (dual protocol, transitional)

The turtle keeps speaking `amalgam_stats` / `amalgam_cmd` **for now** — the old Base Panel is the only screen on the base until `master.lua` exists at milestone 2, and it must not go dark in between. The legacy protocol and `panel.lua` itself are both deleted in Task 13's cleanup once the master is proven. Meanwhile the turtle additionally joins the bus so the master can see and command it. The `update` command only *requests* — the worker loop updates at a safe point.

**Files:**
- Modify: `amalgam.lua`

**Interfaces:**
- Consumes: `bus.open`, `bus.publish`, `bus.serve`, `bus.event` from Task 3's `bus.lua`.
- Produces (the worker contract the master relies on):
  - stats gain `idle` (true when between cycles / paused — safe to reboot) and `running` (operator intent).
  - bus identity: role `"turtle"`, `accepts = { "start", "stop", "reset", "update" }`, `program = "amalgam.lua"`.
  - `update` command → stops taking work, then at the next idle point emits `bus.event("updating")`, runs `shell.run("update")`, reboots.

- [ ] **Step 1: Require the bus (degrade gracefully if absent)**

After the CONFIG section (after `local PROTO_CMD = "amalgam_cmd"`), add:

```lua
-- Machine bus (cc.stats / cc.cmd). Optional: if bus.lua is missing the
-- turtle still runs standalone and the old panel still works.
local bus_ok, bus = pcall(require, "bus")
if not bus_ok then bus = nil end
```

- [ ] **Step 2: Extend state**

In the `stats` table add two fields, and add the update flag next to `running`:

```lua
local stats = {
  cycles = 0, blocks = 0, buckets = 0, alloy = 0, stone = 0,
  failures = 0, retries = 0, recoveries = 0,
  status = "starting", fuel = 0,
  idle = false, running = true,
}

local running, stopped = true, false
local wantUpdate = false
```

- [ ] **Step 3: Dual-publish in `broadcast()` and join the bus in `openModem()`**

```lua
local function broadcast()
  if not hasModem then return end
  local fuel = turtle.getFuelLevel()
  stats.fuel = (fuel == "unlimited") and -1 or fuel
  stats.running = running
  rednet.broadcast(stats, PROTO_STATS)
  if bus and bus.isOpen() then bus.publish(stats) end
end
```

```lua
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
```

- [ ] **Step 4: Extract `resetStats()` and add the bus command handlers**

Replace the inline reset in `listener()` with a shared function (place above `listener`):

```lua
local function resetStats()
  stats.cycles, stats.blocks, stats.buckets = 0, 0, 0
  stats.alloy, stats.stone = 0, 0
  stats.failures, stats.retries, stats.recoveries = 0, 0, 0
end

local busHandlers = {
  start = function() running = true  end,
  stop  = function() running = false end,
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
```

And in the legacy `listener()`, the `reset` branch becomes `resetStats()`.

- [ ] **Step 5: Worker loop honors `wantUpdate` and maintains `idle`**

Replace the body of `worker()`:

```lua
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
```

Note `stats.idle = true` is set on *every* path out of a cycle (success, failure-wait, paused) and `false` only while `cycle()` is actually driving the turtle. `wantUpdate` is only acted on at the top of the loop — i.e., never mid-cycle.

- [ ] **Step 6: Run the bus listener in parallel**

The last line becomes:

```lua
parallel.waitForAny(worker, listener, busListener, heartbeat)
```

(CC's `parallel` delivers every event to every coroutine; the legacy listener and `bus.serve` each filter by their own protocol, so they coexist.)

- [ ] **Step 7: Syntax gate**

Run: `py tools\check.py amalgam.lua`
Expected: `ok`.

- [ ] **Step 8: Commit and push milestone 1**

```bash
git add amalgam.lua
git commit -m "feat: amalgam turtle joins the machine bus (dual protocol)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 6: MILESTONE 1 — in-game verification (bus foundations)

Nothing after this point is worth building until this checkpoint passes. Give these instructions to the player exactly; one action per step; each has a checkpoint.

**Files:** none (in-game + vault updates)

- [ ] **Step 1: Bootstrap the updater on the old panel computer**

On the Base Panel's computer: press and hold `Ctrl+T` to stop `panel.lua`. Type:

```
wget https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/update.lua update
```

Checkpoint: it prints `Downloaded as update`.

- [ ] **Step 2: Pull the code on the panel computer**

Type: `update`
Checkpoint: it lists each file with `updated`, ending `N updated, 0 failed`. Then type `reboot` — the panel returns to its normal display (startup still runs `panel`).

- [ ] **Step 3: Bootstrap + pull on the turtle**

On the turtle: `Ctrl+T`, then the same `wget ... update` line, then `update`, then `reboot`.
Checkpoint: after reboot the turtle log shows `Modem found, broadcasting stats` and it resumes its amalgam work.

- [ ] **Step 4: Selftest on the turtle**

On the turtle: `Ctrl+T`, type `selftest`.
Checkpoint: five `ok` vector lines, a `file` line per tracked file, `SELFTEST PASS`. Then `reboot`.
If any vector FAILs, STOP — the hash function is wrong and every STALE/CURRENT verdict would lie. Debug before proceeding (superpowers:systematic-debugging).

- [ ] **Step 5: Rollcall sees the turtle with a fingerprint**

On the panel computer: `Ctrl+T`, type `rollcall`.
Checkpoint: the Amalgam Turtle appears with role `turtle`. Then `reboot`.

- [ ] **Step 6: The old panel still works**

Look at the Base Panel monitor.
Checkpoint: live stats from the turtle are displayed exactly as before the change. This proves the legacy protocol survived the port.

- [ ] **Step 7: Record in the vault**

In `06 - Code/bus.lua.md` and `06 - Code/amalgam.lua.md`, sync the updated code and keep `status: working`. In `08 - Machines/M - Master Control.md` note "Milestone 1 verified in-game <date>". If anything failed and got fixed, write an `09 - Lessons` note (cc-learning).

---

### Task 7: master.lua skeleton — registry, list, RESCAN

First slice of the new program: draw every machine the bus can see on the 4×4, full-width, with LINK (online/offline) but CODE always `unknown` (remote hashes come in Task 8).

**Files:**
- Create: `master.lua`

**Interfaces:**
- Consumes: `bus.open/watch/registry/scan/command`, `bus.fingerprint` (Task 3).
- Produces (later tasks build on these exact names):
  - `machines, record, isOnline` — the registry triple.
  - `local flow = {}` — `label -> transient status string` drawn in the CODE column when set.
  - `fill(x, y, w, h, colour)`, `centreText(text, x, y, w, h, bg, fg)` — draw helpers.
  - `codeState(m) -> "current" | "stale" | "unknown"` — stub returning `"unknown"` until Task 8.
  - `sortedLabels() -> { label, ... }`, `SELF_LABEL`, `selfFp`.
  - `redraw()`, `rowByY` (y → label hit map), `buttons` list with `.action` callbacks.
  - Request flags consumed by `actionLoop`: `requestRescan` (Task 7), `requestUpdateAll` (Task 9).

- [ ] **Step 1: Write master.lua**

```lua
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
-- Freshness (stub -- Task 8 implements the comparison)
-------------------------------------------------------------------------------

local function codeState(m)
  return "unknown"
end

local function selfIsStale()
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
  bus.scan(3)          -- provokes iam replies; heartbeats fill the registry
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
```

- [ ] **Step 2: Syntax gate**

Run: `py tools\check.py master.lua`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add master.lua
git commit -m "feat: master.lua skeleton - registry list, header, buttons

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Remote fingerprints and the STALE verdict

**Files:**
- Modify: `master.lua` (replace the freshness stubs; hook `doRescan`)

**Interfaces:**
- Consumes: `bus.hashString`, `remote`/`remoteErr` state, `codeState`/`selfIsStale` names from Task 7.
- Produces: `fetchRemote()` — fills `remote = { [name] = hash }` or sets `remoteErr`; real `codeState`/`selfIsStale`.

- [ ] **Step 1: Replace the freshness section**

Replace the stub `codeState` and `selfIsStale` with:

```lua
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
```

- [ ] **Step 2: Fetch at boot and on RESCAN**

`doRescan` becomes:

```lua
local function doRescan()
  fetchRemote()
  bus.scan(3)
end
```

(`doRescan()` is already called once before the parallel loop and from the RESCAN flag — no other changes.)

- [ ] **Step 3: Syntax gate**

Run: `py tools\check.py master.lua`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add master.lua
git commit -m "feat: master compares machine fingerprints against GitHub

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: UPDATE ALL orchestration

The heart of the project. Replace the `updateAll` stub with the locked seven-step sequence from the spec.

**Files:**
- Modify: `master.lua`

**Interfaces:**
- Consumes: `machines`, `isOnline`, `codeState`, `selfIsStale`, `fetchRemote`, `flow`, `bus.command`, `pushEvent` — all defined in Tasks 7–8.
- Produces: working `updateAll()`; `flow[label]` narration consumed by `redraw`.

- [ ] **Step 1: Replace the `updateAll` stub**

```lua
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
```

Delete the old stub (`local function updateAll() ... end` with the Task 9 comment). `waitUntil` and `updateAll` must be defined *above* `actionLoop` and *below* `doRescan`/`pushEvent` so every name they reference already exists.

- [ ] **Step 2: Syntax gate**

Run: `py tools\check.py master.lua`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add master.lua
git commit -m "feat: UPDATE ALL - stop, idle ack, update, restore, self last

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Ship it — manifest + push (milestone 2 code complete)

**Files:**
- Modify: `files.txt`

- [ ] **Step 1: Add the new programs to the manifest**

`files.txt` becomes:

```
# Manifest read by update.lua. One filename per line.
# Add a line and the updater pulls it to every machine automatically.
update.lua
bus.lua
rollcall.lua
amalgam.lua
panel.lua
master.lua
selftest.lua
```

- [ ] **Step 2: Full syntax gate**

Run: `py tools\check.py`
Expected: every file `ok`.

- [ ] **Step 3: Commit and push**

```bash
git add files.txt
git commit -m "feat: ship master.lua and selftest.lua to every machine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 4: Verify the push landed**

Run: `Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/files.txt?cb=1" | Select-Object -ExpandProperty Content`
Expected: the new manifest including `master.lua`.

---

### Task 11: MILESTONE 2 — convert the Base Panel into the Master and prove UPDATE ALL in-game

The Base Panel computer becomes the Master. Its `update` bootstrap already happened in Task 6, so this is a monitor expansion plus a startup rewrite.

**Files:** none (in-game + vault updates)

- [ ] **Step 1: Expand the monitor wall to 4×4**

On the Base Panel: hold `Ctrl+T` in its terminal to stop `panel.lua`. Break the existing 3×2 Advanced Monitor wall and rebuild it as 4×4 (16 Advanced Monitor blocks — the existing 6 plus 10 new; they merge automatically). Keep at least one face of the computer touching the wall, or leave the computer where it is if the wall grows around the same spot.
Checkpoint: the wall is one large black rectangle and the computer still opens a terminal on right-click.

- [ ] **Step 2: Check the modem**

Look at the modem on the computer. If it is a plain Wireless Modem and the base is (or will be) spread out, replace it with an Ender Modem and right-click the new modem to enable it (it glows red when open — the enable step is the classic miss). A wireless modem silently loses machines beyond ~64 blocks and shows them as offline.
Checkpoint: the modem is enabled (red glow).

- [ ] **Step 3: Rename the machine and rewrite startup**

In the computer's terminal type `label set Master`, then `update` (pulls `master.lua` — the computer was bootstrapped in Task 6). Then `edit startup`, replace the old `shell.run("panel")` contents with exactly these two lines, then `Ctrl+S`, `Ctrl+E` (save, exit):

```lua
shell.run("update")
shell.run("master")
```

Checkpoint: `update` listed `master.lua` as downloaded; `startup` contains the two lines above and nothing else.

- [ ] **Step 4: First light**

Type `reboot`.
Checkpoint: the monitor shows the blue BASE MASTER header, the master's own row (`self`, `current`), and the Amalgam Turtle row `ONLINE` / `current` within ~10 seconds. The three buttons sit along the bottom. (Update the turtle first via `update` + `reboot` on it if it still shows `unknown` — it needs Task 5's code to report fingerprints.)

- [ ] **Step 5: Make the turtle stale on purpose**

On the PC: edit `amalgam.lua`'s top comment (add a line like `-- test: staleness probe`), then:

```bash
git add amalgam.lua
git commit -m "test: staleness probe

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

In-game, tap RESCAN on the monitor.
Checkpoint: the turtle's row flips to `STALE` (orange). The master's own row also flips STALE (it tracks `amalgam.lua` too) — expected.

- [ ] **Step 6: The one-button update**

Tap UPDATE ALL. Watch the turtle's row.
Checkpoint: the row narrates `stopping` → `updating` → `rebooting` → `current`, the turtle reboots and resumes working (it was running before, so it gets restarted). The master then updates itself and reboots; the screen comes back with everything `current`. This is the moment the whole project exists for.

- [ ] **Step 7: Restore-prior-state check**

Tap STOP ALL on the master (the old panel no longer exists — this is the master's job now). Checkpoint: the turtle's Status goes `paused` within ~5s. Make another trivial stale-probe commit and push, tap RESCAN, then UPDATE ALL.
Checkpoint: the turtle updates and comes back `current` but **stays paused** — it was stopped before, so it is left stopped. To resume it before Task 12's START button exists, reboot the turtle (its startup relaunches `amalgam`, which starts running).

- [ ] **Step 8: Record in the vault**

Update `08 - Machines/M - Master Control.md`: frontmatter `status: built`, add "Milestone 2 verified in-game <date>" with what was seen. Update `08 - Machines/M - Base Panel.md`: note the hardware now belongs to the Master and `panel.lua` no longer runs (full retirement lands at milestone 3). Update `08 - Machines/Machine index.md` and `08 - Machines/Network map.md`. Create `06 - Code/master.lua.md` from the code template. Write lessons for anything that needed more than one attempt.

---

### Task 12: Hybrid layout — detail pane, per-file diff, events strip

Restructures `redraw` into panes. List left, tapped machine's detail right, events strip above the global buttons. Per the spec mockup in the vault note.

**Files:**
- Modify: `master.lua` (drawing + touch sections only; orchestration untouched)

**Interfaces:**
- Consumes: everything above; `selected`, `events` already exist.
- Produces: `detailButtons` (per-machine START/STOP/UPDATE), pane layout driven by `W, H`.

- [ ] **Step 1: Add pane geometry and the detail/events drawing**

Insert after `drawRow` (and delete nothing yet):

```lua
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
```

- [ ] **Step 2: Rework `redraw` for panes**

Replace the whole `redraw` function:

```lua
local function redraw()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  rowByY = {}

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

  for _, label in ipairs(sortedLabels()) do
    if y > listBottom then break end
    local m = machines[label]
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
```

Also delete the now-unused `drawRow` function from Task 7.

- [ ] **Step 3: Route touches to detail buttons**

In `onTouch`, before the row lookup, add:

```lua
  for _, b in ipairs(detailButtons) do
    if isInside(b, x, y) then
      b.action()
      fill(b.x, b.y, b.w, b.h, colors.white)
      centreText(b.label, b.x, b.y, b.w, b.h, colors.white, colors.black)
      sleep(0.15)
      return
    end
  end
```

- [ ] **Step 4: Syntax gate**

Run: `py tools\check.py master.lua`
Expected: `ok`.

- [ ] **Step 5: Commit and push**

```bash
git add master.lua
git commit -m "feat: hybrid layout - detail pane, per-file diff, events strip

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

---

### Task 13: MILESTONE 3 — in-game verification + harvest

**Files:** none (in-game + vault updates)

- [ ] **Step 1: Pull the new master via its own button**

The master is now stale (master.lua changed). Tap RESCAN.
Checkpoint: the master's own row shows `STALE`. Tap UPDATE ALL.
Checkpoint: the master updates itself and reboots into the hybrid layout — the update system just updated the updater's screen. List left, `tap a machine` hint right, EVENTS strip, three buttons.

- [ ] **Step 2: Drive the detail pane**

Tap the Amalgam Turtle's row.
Checkpoint: the row highlights; the right pane shows its status, running yes/no, last seen, fuel, alloy, cycles, `Code current` with an `ok` line per file, and START / STOP / UPDATE buttons.

- [ ] **Step 3: Per-machine buttons**

Tap STOP in the detail pane. Checkpoint: within ~5s Status shows `paused`, Running flips `no` (and the old Base Panel also shows paused — same turtle). Tap START. Checkpoint: it resumes.

- [ ] **Step 4: Events strip**

Watch the strip during step 3. Checkpoint: turtle status events appear as they happen. If the turtle hits a real fault later (`no stone`, `output full`), it shows here — that's the strip doing its job.

- [ ] **Step 5: Retire panel.lua and strip the turtle's legacy protocol**

The master is proven, so the transition scaffolding comes out. On the PC:

1. In `amalgam.lua`: delete the `local PROTO_STATS = "amalgam_stats"` and `local PROTO_CMD = "amalgam_cmd"` lines; delete the `rednet.broadcast(stats, PROTO_STATS)` line inside `broadcast()`; delete the entire legacy `listener()` function; change the last line to `parallel.waitForAny(worker, busListener, heartbeat)`.
2. Remove the `panel.lua` line from `files.txt`.
3. Delete the program: `git rm panel.lua`

Run: `py tools\check.py`
Expected: all remaining files `ok`.

```bash
git add amalgam.lua files.txt
git commit -m "chore: retire panel.lua and the legacy amalgam protocol

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

In-game, on the master: tap RESCAN (turtle shows STALE), select the turtle, tap its UPDATE button.
Checkpoint: the turtle updates, reboots, and its row returns `ONLINE` / `current` — now speaking only the bus. The update system just deleted its own scaffolding.

- [ ] **Step 6: Vault: prove and harvest**

- `08 - Machines/M - Master Control.md` → `status: proven`, "Milestone 3 verified <date>".
- `08 - Machines/M - Base Panel.md` → retired/superseded by M - Master Control; hardware absorbed into the 4×4 wall.
- `06 - Code/master.lua.md`, `bus.lua.md`, `amalgam.lua.md`, `update.lua.md` → sync code, `status: working`. `06 - Code/panel.lua.md` → note retired, code removed from repo at milestone 3.
- Harvest components (cc-components): **C - File fingerprint staleness** (hash + compare, both sides), **C - Safe fleet update** (stop → idle ack → update → restore), **C - Event feed strip** (ring buffer + renderer), **C - List detail panes** (pane geometry + row hit map). Create notes from the component template, link them from `Component index`, mark `proven`.
- `08 - Machines/Network map.md` → add the master and its protocol traffic.
- Any fight along the way → `09 - Lessons` note.

---

## Self-Review (completed at plan time)

- **Spec coverage:** fingerprints (T3), heartbeat transport (T3), updater manifest gap (T4), worker port + dual protocol + safe update handler (T5), list UI (T7), STALE verdict + unreachable-GitHub fallback (T8), seven-step UPDATE ALL incl. restore-state / skip-amber / self-last (T9), deploy (T10), Base Panel → Master conversion + startup-pull setup (T11), hybrid panes + detail buttons + per-file diff + events (T12), panel retirement + legacy-protocol strip (T13 step 5), verification loop + vault records (T6/T11/T13). The spec's "startup runs update" lives in T11 step 3 (master) and the existing machines' startups already run their programs — add `shell.run("update")` above the program line on the turtle/panel when convenient (T11 step 8 vault note covers it).
- **Placeholder scan:** none — every code step contains the actual code.
- **Type consistency:** `bus.hashString/hashFile/trackedFiles/fingerprint` (T3) match T5/T7/T8 call sites; `stats.idle`/`stats.running` produced in T5, consumed in T9; `flow`, `rowByY`, `buttons`, `detailButtons`, `selected`, `events` names consistent across T7/T9/T12; `CODE_COLOURS` keys are exactly the three `codeState` returns.
