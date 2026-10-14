-- Sends events to relay/relay.mjs over a TCP connection to 127.0.0.1, one JSON object per line.
-- Nothing is kept: an event that can't be sent right away (relay not running, connection lost) is dropped, and the
-- tracker logs it. While disconnected it tries to connect every two seconds; on localhost a refused connect returns
-- at once, so the emulator doesn't stall.
--
-- The relay never writes to the connection, so the socket becoming readable means the relay closed it. It is then
-- closed here before anything else is written: mGBA 0.10.3 sends with a plain write() and doesn't ignore SIGPIPE,
-- so writing to a connection the relay has reset would kill the emulator.

local C = {}
C.__index = C

local HOST = "127.0.0.1"
local RETRY = 120 -- frames between connection attempts

-- `sockets` is mGBA's `socket` global; tests pass a fake.
function C.new(port, log, sockets)
  return setmetatable({ port = port, log = log or function() end, sockets = sockets or socket, wait = 0 }, C)
end

function C:close(why)
  if not self.sock then return end
  self.sock:close()
  self.sock, self.wait = nil, RETRY
  if why then self.log(why) end
end

-- False once the relay has closed the connection (readable, or an error from the check).
local function alive(sock) return sock:hasdata() == false end

-- Once per frame: notices a closed connection, and reconnects every RETRY frames.
function C:step()
  if self.sock then
    if not alive(self.sock) then self:close("disconnected; reconnecting every 2 s") end
    return
  end
  self.wait = self.wait - 1
  if self.wait > 0 then return end
  self.wait = RETRY
  local s = self.sockets.tcp()
  local ok, err = s:connect(HOST, self.port)
  if ok then
    self.sock, self.warned = s, false
    self.log(string.format("connected on port %d", self.port))
  else
    s:close()
    if not self.warned then
      self.log(string.format("not running on port %d (%s); events are not sent until it is", self.port, tostring(err)))
      self.warned = true
    end
  end
end

-- Sends one line; returns true, or false and why it wasn't sent.
function C:send(line)
  if self.sock and not alive(self.sock) then self:close("disconnected; reconnecting every 2 s") end
  if not self.sock then return false, "relay not connected" end
  local n, err = self.sock:send(line .. "\n")
  if n ~= #line + 1 then
    local why = "send failed: " .. tostring(err or "partial write")
    self:close() -- a partial line is discarded by the relay when the connection closes
    return false, why
  end
  return true
end

return C
