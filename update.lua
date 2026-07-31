--[[
  update.lua -- pull the latest programs from a GitHub repo

  ONE-TIME SETUP
    1. Make a public GitHub repo, e.g.  yourname/mc-amalgam
    2. Put amalgam.lua, panel.lua, update.lua and files.txt in it
    3. Edit the three settings below
    4. On each in-game computer, run once:
         wget https://raw.githubusercontent.com/YOU/REPO/main/update.lua update
    5. From then on, just run:  update

  files.txt is a plain list of filenames to download, one per line.
  Lines starting with # are ignored. Example:

      amalgam.lua
      panel.lua
      update.lua

  USAGE
    update           -- download anything that changed
    update -f        -- redownload everything even if unchanged
    update -r        -- reboot the computer afterwards
]]

-------------------------------------------------------------------------------
-- SETTINGS
-------------------------------------------------------------------------------

local USER   = "giftguruai2024-create"
local REPO   = "mc-base"
local BRANCH = "main"

-------------------------------------------------------------------------------

local BASE = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(USER, REPO, BRANCH)

local args = { ... }
local force, reboot = false, false
for _, a in ipairs(args) do
  if a == "-f" then force = true end
  if a == "-r" then reboot = true end
end

if not http then
  error("HTTP is disabled on this server -- ask an admin to enable it in the CC config", 0)
end

local function colour(c, text)
  if term.isColour() then term.setTextColour(c) end
  write(text)
  if term.isColour() then term.setTextColour(colours.white) end
end

-- GitHub caches raw files for a few minutes, so bust it with a changing query
local function fetch(path)
  local url = BASE .. path .. "?cb=" .. tostring(os.epoch("utc"))
  local res, err = http.get(url)
  if not res then return nil, tostring(err) end
  local body = res.readAll()
  local code = res.getResponseCode()
  res.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  return body
end

local function readLocal(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local body = f.readAll()
  f.close()
  return body
end

local function writeLocal(path, body)
  local dir = fs.getDir(path)
  if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  f.write(body)
  f.close()
end

-------------------------------------------------------------------------------

print("Fetching manifest from " .. USER .. "/" .. REPO)

local manifest, err = fetch("files.txt")
if not manifest then
  colour(colours.red, "Could not read files.txt: " .. err .. "\n")
  print("Check USER, REPO and BRANCH at the top of this file,")
  print("and that the repo is public.")
  return
end

local files = {}
for line in manifest:gmatch("[^\r\n]+") do
  local name = line:match("^%s*(.-)%s*$")
  if name ~= "" and name:sub(1, 1) ~= "#" then
    files[#files + 1] = name
  end
end

if #files == 0 then
  colour(colours.orange, "files.txt is empty\n")
  return
end

-- Save the manifest so bus.trackedFiles() knows what to fingerprint.
writeLocal("files.txt", manifest)

local updated, skipped, failed = 0, 0, 0

for _, name in ipairs(files) do
  write("  " .. name .. " ... ")

  local body, ferr = fetch(name)
  if not body then
    colour(colours.red, "failed (" .. ferr .. ")\n")
    failed = failed + 1
  elseif not force and readLocal(name) == body then
    colour(colours.lightGrey, "unchanged\n")
    skipped = skipped + 1
  else
    writeLocal(name, body)
    colour(colours.lime, "updated\n")
    updated = updated + 1
  end
end

print("")
print(("%d updated, %d unchanged, %d failed"):format(updated, skipped, failed))

if failed > 0 then
  colour(colours.orange, "Some files did not download -- check the names in files.txt\n")
end

if reboot and updated > 0 then
  print("Rebooting in 2s...")
  sleep(2)
  os.reboot()
end
