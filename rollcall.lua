--[[
  rollcall.lua -- find every machine on the base and write down what it found

  Broadcasts a discovery ping. Every machine running bus.lua answers with its
  identity. The result is printed, and optionally saved as machines.json so it
  can be committed to the repo -- which is how an assistant reading your repo
  learns what machines you actually have.

  USAGE
    rollcall            scan and print
    rollcall -save      scan, print, and write machines.json
    rollcall -md        also print a markdown table for pasting into notes
    rollcall -t 10      wait 10 seconds instead of 3

  REQUIRES
    bus.lua in the same directory, and a modem on this computer.

  WORKFLOW
    1. rollcall -save
    2. commit machines.json to the repo
    3. the assistant reads it and knows the whole network
]]

local ok, bus = pcall(require, "bus")
if not ok then
  error("bus.lua not found -- put it next to this program and add it to files.txt", 0)
end

local args = { ... }
local save, markdown, timeout = false, false, 3
for i, a in ipairs(args) do
  if a == "-save" or a == "-s" then save = true end
  if a == "-md"   or a == "-m" then markdown = true end
  if a == "-t" then timeout = tonumber(args[i + 1]) or 3 end
end

local started, err = bus.open{
  label = os.getComputerLabel() or ("scanner_" .. os.getComputerID()),
  role  = "scanner",
}
if not started then
  error("Cannot scan: " .. tostring(err), 0)
end

local function colour(c, text)
  if term.isColour() then term.setTextColour(c) end
  write(text)
  if term.isColour() then term.setTextColour(colours.white) end
end

print("Scanning for " .. timeout .. "s...")
print("")

local machines = bus.scan(timeout)

if #machines == 0 then
  colour(colours.orange, "No machines answered.\n")
  print("")
  print("Check that each machine:")
  print(" - has a modem equipped or attached")
  print(" - is running a program that calls bus.open()")
  print(" - is inside modem range (ender modems are unlimited)")
  print(" - is in a loaded chunk")
  return
end

-------------------------------------------------------------------------------
-- Print
-------------------------------------------------------------------------------

for _, m in ipairs(machines) do
  colour(colours.lime, m.label)
  write(("  #%d  %s%s\n"):format(m.id, m.role or "?", m.turtle and " (turtle)" or ""))

  if m.provides and #m.provides > 0 then
    print("   provides: " .. table.concat(m.provides, ", "))
  end
  if m.accepts and #m.accepts > 0 then
    print("   accepts:  " .. table.concat(m.accepts, ", "))
  end
  if m.location then
    print("   at:       " .. tostring(m.location))
  end
end

print("")
colour(colours.lightBlue, ("%d machine%s found\n"):format(#machines, #machines == 1 and "" or "s"))

-------------------------------------------------------------------------------
-- Markdown table
-------------------------------------------------------------------------------

if markdown then
  print("")
  print("| Machine | ID | Role | Provides | Accepts |")
  print("|---|---|---|---|---|")
  for _, m in ipairs(machines) do
    print(("| %s | %d | %s | %s | %s |"):format(
      m.label, m.id, m.role or "?",
      table.concat(m.provides or {}, ", "),
      table.concat(m.accepts or {}, ", ")))
  end
end

-------------------------------------------------------------------------------
-- Save
-------------------------------------------------------------------------------

if save then
  local out = {
    scannedAt = os.epoch("utc"),
    scannedBy = bus.identity().label,
    machines  = machines,
  }

  local f = fs.open("machines.json", "w")
  f.write(textutils.serialiseJSON(out))
  f.close()

  print("")
  colour(colours.lime, "Wrote machines.json\n")
  print("Commit it to your repo so the network is on record.")
end
