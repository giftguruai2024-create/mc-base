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
