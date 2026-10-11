-- Minimal JSON encoder (objects with sorted keys, arrays, strings, numbers, booleans). Encode only.

local J = {}

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function str(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n > 0 and n == #t
end

function J.encode(v)
  local t = type(v)
  if t == "string" then return str(v)
  elseif t == "number" then
    if math.type(v) == "integer" then return tostring(v) end
    return string.format("%.14g", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "nil" then return "null"
  elseif t == "table" then
    local out = {}
    if is_array(v) then
      for i = 1, #v do out[i] = J.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = str(k) .. ":" .. J.encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode " .. t)
end

return J
