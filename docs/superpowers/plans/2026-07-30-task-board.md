# Task Board Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A personal to-do board on its own computer: type tasks on the terminal, tap them done on a touch monitor, list survives reboots, machine shows up on the Master like any other bus citizen.

**Architecture:** One new program `tasks.lua` (four coroutines: terminal input, monitor UI, bus serve, heartbeat) with a Lua-serialized `tasks.dat` store. Ships via the existing GitHub deploy; the same commit retires the amalgam-era programs (`panel.lua`, `amalgam.lua`, `touchpanel.lua`) from the manifest and repo. Spec: vault note `08 - Machines/M - Task Board.md`.

**Tech Stack:** CC:Tweaked (MC 1.21.1), Lua 5.2, existing `bus.lua`/`update.lua` infrastructure, repo `giftguruai2024-create/mc-base` on `main`.

## Global Constraints

- **Lua dialect:** CC:Tweaked ≈ Lua 5.2. No native bitwise ops, no `//`.
- **Monitor size never hardcoded:** all layout from `mon.getSize()` at runtime; re-layout on `monitor_resize`.
- **`tasks.dat` must never be in `files.txt`** — the updater must never overwrite user data. Saves go through a tmp-file + move so a crash mid-write can't corrupt the list.
- **Terminal numbers = displayed numbers.** `done N`/`del N` refer to the numbers currently shown on the wall (open tasks first in added order, then done tasks). The view order is computed by one function used by both the renderer and the command parser.
- **Fleet update contract:** the bus `update` handler only sets a flag; the UI loop performs `update` + reboot between draws, emitting `bus.event("updating")` first. `stats.idle = true` and `stats.running = true` always (a display has no unsafe moment).
- **Standalone degrade:** no modem → print a note and run without bus features; never crash.
- **Manifest-shrink is safe by design** (verified in the master's final review): `codeState` compares only files listed in the *remote* `files.txt`, so removing `panel.lua`/`amalgam.lua` strands nothing. After the manifest changes, existing machines show STALE until they update — expected and correct.
- **Commits:** end every commit message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- **Working directory:** `C:\Users\Trevo\Code\mc-base`. Syntax gate: `py tools\check.py`.

---

### Task 1: Write tasks.lua

**Files:**
- Create: `tasks.lua`

**Interfaces:**
- Consumes: `bus.open/isOpen/serve/heartbeat/event` from the existing `bus.lua`.
- Produces: the complete program below, verbatim.

- [ ] **Step 1: Create `tasks.lua` with exactly this code**

```lua
--[[
  tasks.lua -- personal to-do board: terminal input, touch monitor display

  SETUP
    * Advanced Computer + touch Advanced Monitor + modem (modem optional)
    * Bootstrap once:
        wget https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/update.lua update
        update
    * startup:  shell.run("update")  then  shell.run("tasks")

  USAGE (type on the computer's terminal)
    <any text>   add a task
    done N       toggle task N done (N = number shown on the wall)
    del N        delete task N
    clear        remove all done tasks
    help         show commands

  Touch: tap a row to toggle done, tap the x at the right edge to delete.
  Tasks persist in tasks.dat -- NOT in files.txt, so updates never touch it.
]]

local DATA_FILE = "tasks.dat"

local bus = require("bus")

-------------------------------------------------------------------------------
-- Peripherals
-------------------------------------------------------------------------------

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached", 0) end
mon.setTextScale(0.5)
local W, H = mon.getSize()

local busOk, busErr = bus.open{
  label    = os.getComputerLabel() or "TaskBoard",
  role     = "display",
  program  = "tasks.lua",
  provides = { "tasks" },
  accepts  = { "update" },
}
if not busOk then
  print("bus: " .. tostring(busErr) .. " -- running standalone")
end

-------------------------------------------------------------------------------
-- Task store
-------------------------------------------------------------------------------

local tasks = {}          -- { { text = "...", done = false, addedAt = ms }, ... }
local wantUpdate = false
local rowHit = {}         -- monitor row y -> tasks index

local function loadTasks()
  local f = fs.open(DATA_FILE, "r")
  if not f then return end
  local body = f.readAll()
  f.close()
  local data = textutils.unserialize(body)
  if type(data) == "table" then tasks = data end
end

-- tmp + move so a crash mid-write cannot corrupt the list
local function saveTasks()
  local f = fs.open(DATA_FILE .. ".tmp", "w")
  if not f then return end
  f.write(textutils.serialize(tasks))
  f.close()
  if fs.exists(DATA_FILE) then fs.delete(DATA_FILE) end
  fs.move(DATA_FILE .. ".tmp", DATA_FILE)
end

local function counts()
  local open, done = 0, 0
  for _, t in ipairs(tasks) do
    if t.done then done = done + 1 else open = open + 1 end
  end
  return open, done
end

-- Display order: open tasks in added order, then done tasks. The numbers the
-- terminal accepts are positions in THIS list -- what the wall shows.
local function viewOrder()
  local view = {}
  for i, t in ipairs(tasks) do
    if not t.done then view[#view + 1] = i end
  end
  for i, t in ipairs(tasks) do
    if t.done then view[#view + 1] = i end
  end
  return view
end

-------------------------------------------------------------------------------
-- Drawing
-------------------------------------------------------------------------------

local function drawBoard()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  rowHit = {}

  local open, done = counts()
  mon.setBackgroundColor(colors.blue)
  mon.setCursorPos(1, 1)
  mon.write(string.rep(" ", W))
  mon.setCursorPos(2, 1)
  mon.setTextColor(colors.white)
  mon.write("TASKS")
  local right = ("%d open   %d done"):format(open, done)
  mon.setCursorPos(math.max(8, W - #right - 1), 1)
  mon.write(right)

  mon.setBackgroundColor(colors.black)
  local view = viewOrder()
  local maxRows = H - 3
  local y = 2
  for v = 1, math.min(#view, maxRows) do
    local t = tasks[view[v]]
    rowHit[y] = view[v]
    mon.setCursorPos(2, y)
    if t.done then
      mon.setTextColor(colors.gray)
      mon.write(("[x] %s"):format(t.text):sub(1, W - 4))
    else
      mon.setTextColor(colors.orange)
      mon.write("[ ] ")
      mon.setTextColor(colors.white)
      mon.write(t.text:sub(1, W - 7))
    end
    mon.setCursorPos(W - 1, y)
    mon.setTextColor(colors.red)
    mon.write("x")
    y = y + 1
  end

  if #view > maxRows then
    mon.setCursorPos(2, y)
    mon.setTextColor(colors.gray)
    mon.write(("+%d more"):format(#view - maxRows))
  end

  mon.setCursorPos(2, H)
  mon.setTextColor(colors.gray)
  mon.write(("type on the computer to add a task"):sub(1, W - 2))
end

-------------------------------------------------------------------------------
-- Input: touch
-------------------------------------------------------------------------------

local function handleTouch(x, y)
  local idx = rowHit[y]
  if not idx then return end
  if x >= W - 2 then
    table.remove(tasks, idx)
  else
    tasks[idx].done = not tasks[idx].done
  end
  saveTasks()
end

-------------------------------------------------------------------------------
-- Input: terminal
-------------------------------------------------------------------------------

local function handleLine(line)
  line = line:match("^%s*(.-)%s*$")
  if line == "" then return end

  local cmd, arg = line:match("^(%S+)%s*(.*)$")
  local lower = cmd:lower()
  local view = viewOrder()

  if lower == "help" then
    print("  <text>  add a task")
    print("  done N  toggle task N done")
    print("  del N   delete task N")
    print("  clear   remove all done tasks")

  elseif lower == "done" and tonumber(arg) then
    local idx = view[tonumber(arg)]
    if not idx then
      print("no task #" .. arg)
    else
      tasks[idx].done = not tasks[idx].done
      saveTasks()
      print((tasks[idx].done and "done" or "reopened")
        .. " #" .. arg .. ": " .. tasks[idx].text)
    end

  elseif lower == "del" and tonumber(arg) then
    local idx = view[tonumber(arg)]
    if not idx then
      print("no task #" .. arg)
    else
      local t = table.remove(tasks, idx)
      saveTasks()
      print("deleted #" .. arg .. ": " .. t.text)
    end

  elseif lower == "clear" then
    local kept, removed = {}, 0
    for _, t in ipairs(tasks) do
      if t.done then removed = removed + 1 else kept[#kept + 1] = t end
    end
    tasks = kept
    saveTasks()
    print("cleared " .. removed .. " done task(s)")

  else
    tasks[#tasks + 1] = { text = line, done = false, addedAt = os.epoch("utc") }
    saveTasks()
    local open = counts()
    print("added #" .. open .. ": " .. line)
  end

  os.queueEvent("task_redraw")
end

local function terminalLoop()
  print("TaskBoard ready. Type a task, or: done N, del N, clear, help")
  while true do
    write("> ")
    handleLine(read())
  end
end

-------------------------------------------------------------------------------
-- Coroutines
-------------------------------------------------------------------------------

local function uiLoop()
  drawBoard()
  local tick = os.startTimer(1)
  while true do
    local event, p1, p2, p3 = os.pullEvent()
    if event == "monitor_touch" then
      handleTouch(p2, p3)
      drawBoard()
      tick = os.startTimer(1)
    elseif event == "task_redraw" then
      drawBoard()
    elseif event == "monitor_resize" then
      W, H = mon.getSize()
      drawBoard()
    elseif event == "timer" and p1 == tick then
      tick = os.startTimer(1)
      if wantUpdate then
        if bus.isOpen() then bus.event("updating") end
        sleep(0.5)
        shell.run("update")
        os.reboot()
      end
    end
  end
end

local function busServe()
  if not bus.isOpen() then
    while true do sleep(60) end
  end
  bus.serve({
    update = function() wantUpdate = true end,
  })
end

local function heartbeat()
  if not bus.isOpen() then
    while true do sleep(60) end
  end
  bus.heartbeat(function()
    local open, done = counts()
    return { open = open, done = done, status = "ok",
             idle = true, running = true }
  end)
end

-------------------------------------------------------------------------------
-- Entry
-------------------------------------------------------------------------------

loadTasks()
parallel.waitForAny(terminalLoop, uiLoop, busServe, heartbeat)
```

- [ ] **Step 2: Syntax gate**

Run: `py tools\check.py tasks.lua`
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add tasks.lua
git commit -m "feat: task board - terminal input, touch monitor, persistent list

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Manifest update + amalgam-era cleanup + push

**Files:**
- Modify: `files.txt`
- Delete: `panel.lua`, `amalgam.lua`, `touchpanel.lua`

**Interfaces:**
- Produces: the manifest every machine pulls. After this push, all machines show STALE on the master until updated (expected — the manifest changed).

- [ ] **Step 1: Rewrite `files.txt`**

```
# Manifest read by update.lua. One filename per line.
# Add a line and the updater pulls it to every machine automatically.
update.lua
bus.lua
rollcall.lua
master.lua
selftest.lua
tasks.lua
```

- [ ] **Step 2: Remove the retired programs**

Run: `git rm panel.lua amalgam.lua touchpanel.lua`
Expected: three `rm` lines. (Git history and the vault code notes remain the record; the amalgam plant no longer exists in-world.)

- [ ] **Step 3: Full syntax gate**

Run: `py tools\check.py`
Expected: `ok` for the five remaining `.lua` files, exit 0.

- [ ] **Step 4: Commit and push**

```bash
git add files.txt
git commit -m "feat: ship task board; retire amalgam-era programs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push
```

- [ ] **Step 5: Verify the push**

Run: `Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/files.txt?cb=1" | Select-Object -ExpandProperty Content`
Expected: the six-entry manifest including `tasks.lua`, excluding `panel.lua`/`amalgam.lua`.

---

### Task 3: MILESTONE — build and verify in-game (user)

**Files:** none (in-game + vault updates)

- [ ] **Step 1: Build the hardware**

Place an Advanced Computer, attach a modem on a free side (right-click to enable — red glow), and build the touch Advanced Monitor wall next to it (2×2 or larger).
Checkpoint: terminal opens; monitor is one black rectangle.

- [ ] **Step 2: Bootstrap**

```
wget https://raw.githubusercontent.com/giftguruai2024-create/mc-base/main/update.lua update
```
then `update`, then `label set TaskBoard`.
Checkpoint: six files download including `tasks.lua`.

- [ ] **Step 3: Startup file**

`edit startup`, exactly two lines, save (Ctrl → Save), exit (Ctrl → Exit):

```lua
shell.run("update")
shell.run("tasks")
```

Then `reboot`.
Checkpoint: monitor shows the blue TASKS header, `0 open   0 done`, and the hint line.

- [ ] **Step 4: Exercise it**

Type `get more iron` + Enter → appears on the wall as `[ ] get more iron`. Add one more. `done 1` → grays. Tap task 2's checkbox on the wall → grays. Tap an `x` → row disappears. `clear` → done tasks swept.
Checkpoint: every action reflects on the wall within a second.

- [ ] **Step 5: Persistence**

`reboot`. Checkpoint: the list comes back exactly as it was.

- [ ] **Step 6: The fleet sees it**

Walk to the Master. Checkpoint: `TaskBoard  ONLINE  current` row exists. The Master itself likely shows STALE (the manifest changed under it) — tap UPDATE ALL and watch it update itself; TaskBoard stays current.

- [ ] **Step 7: Vault records**

`M - Task Board.md` → `status: built` (then `proven` once steps 4–6 all passed), record the computer ID and location. Add to `Machine index` and `Network map`. Create `06 - Code/tasks.lua.md`. Mark `M - Base Panel.md` retired if not already. Harvest components per cc-components if anything new proved reusable (the tmp+move save and the view-order numbering are candidates).

---

## Self-Review (completed at plan time)

- **Spec coverage:** terminal add/done/del/clear/help (T1 `handleLine`), touch toggle/delete (T1 `handleTouch`), open-first ordering with matching numbers (`viewOrder` used by both parser and renderer), overflow `+N more`, persistence with tmp+move, standalone degrade, bus identity/heartbeat/update-flag contract, deploy rider removing the three retired programs (T2), full in-game verification incl. Master row (T3). 
- **Placeholder scan:** none.
- **Type consistency:** `viewOrder`/`counts`/`saveTasks`/`drawBoard`/`handleTouch`/`handleLine` names consistent throughout; stats fields match the spec note's table (`open`, `done`, `status`, `idle`, `running`).
