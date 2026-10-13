-- Remote control for mGBA 0.10.3, for experiments and emulator-in-the-loop checks. Not part of the tracker.
-- Load it once with Tools > Scripting > File > Load script; then drive it with tools/remote.py.
-- Usage, the functions a chunk can call, and the quirks this works around: tools/README.md.
--
-- Protocol (files in <repo>/.remote/): cmd.lua is a chunk to run (first line `--id=N`, deleted once read);
-- out-N.txt gets what it logged, then `OK` or `ERROR <message>`; watch.log gets lines from watchers.

local dir = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local root = dir .. "../../"
local rdir = root .. ".remote/"
package.path = root .. "lua/?.lua;" .. package.path
for _, name in ipairs({ "addresses", "gen3", "json" }) do package.loaded[name] = nil end
local A, G = require("addresses"), require("gen3")

local KEY = { A = 0, B = 1, SELECT = 2, START = 3, RIGHT = 4, LEFT = 5, UP = 6, DOWN = 7, R = 8, L = 9 }

local held = 0      -- key mask the current command holds down
local job           -- { co, id, out, wait }
local watchers = {}
local S = {}
local frame = 0

local function write_file(p, s)
  local tmp = p .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(s)
  f:close()
  assert(os.rename(tmp, p))
end

local wlog_file
local function wlog(...)
  if not wlog_file then wlog_file = io.open(rdir .. "watch.log", "a") end
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  wlog_file:write(string.format("f%d ", frame), table.concat(parts, " "), "\n")
  wlog_file:flush()
end

local function mask_of(spec)
  local m = 0
  for k in spec:gmatch("[^+]+") do
    local bit = KEY[k:upper()]
    if not bit then error("unknown key " .. k, 3) end
    m = m | (1 << bit)
  end
  return m
end

local env = setmetatable({}, { __index = _G })

function env.log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  job.out[#job.out + 1] = table.concat(parts, " ")
end

function env.wait(n)
  coroutine.yield(math.max(1, n or 1))
end

function env.press(spec, hold, gap)
  held = mask_of(spec)
  env.wait(hold or 6)
  held = 0
  env.wait(gap or 12)
end

function env.keys(seq, hold, gap)
  for k in seq:gmatch("%S+") do env.press(k, hold, gap) end
end

function env.watch(name, fn) watchers[name] = fn end
function env.unwatch(name) watchers[name] = nil end

-- mGBA only allows `emu` calls from the main Lua thread, not from a coroutine, so inside a chunk `emu` is a
-- proxy: each method call yields to the frame callback, which makes the real call and resumes with the result.
local proxy = setmetatable({}, { __index = function(_, name)
  return function(_, ...) return coroutine.yield({ name, table.pack(...) }) end
end })

function env.shot(name)
  local p = rdir .. name .. ".png"
  proxy:screenshot(p)
  env.log("shot " .. p)
end

env.emu, env.A, env.G, env.S, env.wlog = proxy, A, G, S, wlog

local function finish(status)
  write_file(rdir .. "out-" .. job.id .. ".txt", table.concat(job.out, "\n") .. (#job.out > 0 and "\n" or "") .. status .. "\n")
  job, held = nil, 0
end

local function resume()
  local ok, w = coroutine.resume(job.co)
  while ok and type(w) == "table" do -- an emu call from the chunk
    local call = w
    local r = table.pack(pcall(function() return emu[call[1]](emu, table.unpack(call[2], 1, call[2].n)) end))
    if not r[1] then finish("ERROR emu:" .. call[1] .. ": " .. tostring(r[2])) return end
    ok, w = coroutine.resume(job.co, table.unpack(r, 2, r.n))
  end
  if not ok then
    finish("ERROR " .. tostring(w) .. "\n" .. debug.traceback(job.co))
  elseif coroutine.status(job.co) == "dead" then
    finish("OK")
  else
    job.wait = w
  end
end

local function poll()
  local p = rdir .. "cmd.lua"
  local f = io.open(p, "r")
  if not f then return end
  local src = f:read("a")
  f:close()
  os.remove(p)
  local id = src:match("^%-%-id=(%w+)") or tostring(frame)
  job = { id = id, out = {} }
  local chunk, err = load(src, "=cmd-" .. id, "t", env)
  if not chunk then finish("ERROR " .. err) return end
  job.co = coroutine.create(chunk)
  resume()
end

-- emu:addKeys is sticky (keys stay down until cleared), so release whatever the previous press added.
local applied = 0
local function on_keys()
  if held ~= applied then
    if applied & ~held ~= 0 then emu:clearKeys(applied & ~held) end
    if held ~= 0 then emu:addKeys(held) end
    applied = held
  end
end

local function on_frame()
  frame = frame + 1
  for name, fn in pairs(watchers) do
    local ok, err = pcall(fn, frame, wlog, emu)
    if not ok then wlog("watcher " .. name .. " failed: " .. tostring(err)); watchers[name] = nil end
  end
  if job then
    job.wait = job.wait - 1
    if job.wait <= 0 then resume() end
  elseif frame % 6 == 0 then
    poll()
  end
end

if REMOTE_CBS then for _, cb in ipairs(REMOTE_CBS) do callbacks:remove(cb) end end
emu:clearKeys(0x3ff) -- in case an earlier copy left keys down
REMOTE_CBS = { callbacks:add("frame", on_frame), callbacks:add("keysRead", on_keys) }

if not io or not os then
  console:log("remote: io/os libraries are not available in this build; cannot work")
else
  console:log("remote: polling " .. rdir .. "cmd.lua (the directory must exist; tools/remote.py creates it)")
end
