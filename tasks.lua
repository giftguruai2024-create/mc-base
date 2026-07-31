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
  local path = DATA_FILE
  if not fs.exists(path) and fs.exists(DATA_FILE .. ".tmp") then
    path = DATA_FILE .. ".tmp"   -- a crash landed between delete and move
  end
  local f = fs.open(path, "r")
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
