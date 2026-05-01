-- Pure LuaJIT JSON encoder/decoder — no FFI, no C libs
-- Used by ljpm. Lives at /lua/pm/json.lua in LJOS.

local json = {}

-- ─── Encoder ─────────────────────────────────────────────────────────────────

local function encode_val(v, indent, level)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 2^53 then
      return string.format("%d", v)
    end
    return string.format("%.17g", v)
  elseif t == "string" then
    local s = v:gsub('\\', '\\\\')
               :gsub('"',  '\\"')
               :gsub('\n', '\\n')
               :gsub('\r', '\\r')
               :gsub('\t', '\\t')
               :gsub('%c', function(c) return string.format('\\u%04x', c:byte()) end)
    return '"' .. s .. '"'
  elseif t == "table" then
    -- Detect array vs object
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    local is_arr = (#v == n)
    for k in pairs(v) do
      if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
        is_arr = false; break
      end
    end

    local nl   = indent and "\n" or ""
    local sp   = indent and string.rep(indent, level+1) or ""
    local csp  = indent and string.rep(indent, level) or ""
    local sep  = indent and (", " ) or ","

    if is_arr and n == 0 then return "[]" end
    if not is_arr and n == 0 then return "{}" end

    if is_arr then
      local parts = {}
      for i = 1, #v do
        parts[i] = sp .. encode_val(v[i], indent, level+1)
      end
      return "[" .. nl .. table.concat(parts, "," .. nl) .. nl .. csp .. "]"
    else
      local keys = {}
      for k in pairs(v) do
        if type(k) == "string" then keys[#keys+1] = k end
      end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do
        parts[#parts+1] = sp .. encode_val(k, nil, 0) .. ":" ..
                          (indent and " " or "") .. encode_val(v[k], indent, level+1)
      end
      return "{" .. nl .. table.concat(parts, "," .. nl) .. nl .. csp .. "}"
    end
  end
  error("Cannot JSON-encode value of type: " .. t)
end

function json.encode(val, pretty)
  return encode_val(val, pretty and "  " or nil, 0)
end

-- ─── Decoder ─────────────────────────────────────────────────────────────────

local skip_ws, decode_val  -- forward decls

skip_ws = function(s, i)
  while i <= #s do
    local c = s:sub(i,i)
    if c==' ' or c=='\t' or c=='\n' or c=='\r' then i=i+1 else break end
  end
  return i
end

local function decode_str(s, i)
  i = i + 1  -- skip opening "
  local buf = {}
  while i <= #s do
    local c = s:sub(i,i)
    if c == '"' then
      return table.concat(buf), i+1
    elseif c == '\\' then
      i = i + 1
      local e = s:sub(i,i)
      if     e=='"'  then buf[#buf+1]='"'
      elseif e=='\\'then buf[#buf+1]='\\'
      elseif e=='/'  then buf[#buf+1]='/'
      elseif e=='n'  then buf[#buf+1]='\n'
      elseif e=='r'  then buf[#buf+1]='\r'
      elseif e=='t'  then buf[#buf+1]='\t'
      elseif e=='b'  then buf[#buf+1]='\b'
      elseif e=='f'  then buf[#buf+1]='\f'
      elseif e=='u'  then
        local cp = tonumber(s:sub(i+1,i+4), 16) or 0
        if cp < 0x80 then
          buf[#buf+1] = string.char(cp)
        elseif cp < 0x800 then
          buf[#buf+1] = string.char(0xC0+math.floor(cp/64), 0x80+cp%64)
        else
          buf[#buf+1] = string.char(0xE0+math.floor(cp/4096),
                                    0x80+math.floor(cp%4096/64),
                                    0x80+cp%64)
        end
        i = i + 4
      end
      i = i + 1
    else
      buf[#buf+1] = c
      i = i + 1
    end
  end
  error("Unterminated JSON string")
end

local function decode_num(s, i)
  local tok = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
  if not tok then error("Bad JSON number at "..i) end
  return tonumber(tok), i + #tok
end

local function decode_arr(s, i)
  i = i + 1  -- skip [
  local arr = {}
  i = skip_ws(s, i)
  if s:sub(i,i)==']' then return arr, i+1 end
  while true do
    i = skip_ws(s, i)
    local v; v, i = decode_val(s, i)
    arr[#arr+1] = v
    i = skip_ws(s, i)
    local c = s:sub(i,i)
    if     c==']' then return arr, i+1
    elseif c==',' then i=i+1
    else error("Expected ',' or ']' at "..i) end
  end
end

local function decode_obj(s, i)
  i = i + 1  -- skip {
  local obj = {}
  i = skip_ws(s, i)
  if s:sub(i,i)=='}' then return obj, i+1 end
  while true do
    i = skip_ws(s, i)
    if s:sub(i,i)~='"' then error("Expected string key at "..i) end
    local k; k, i = decode_str(s, i)
    i = skip_ws(s, i)
    if s:sub(i,i)~=':' then error("Expected ':' at "..i) end
    i = i + 1
    i = skip_ws(s, i)
    local v; v, i = decode_val(s, i)
    obj[k] = v
    i = skip_ws(s, i)
    local c = s:sub(i,i)
    if     c=='}' then return obj, i+1
    elseif c==',' then i=i+1
    else error("Expected ',' or '}' at "..i) end
  end
end

decode_val = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i,i)
  if     c=='"' then return decode_str(s, i)
  elseif c=='{' then return decode_obj(s, i)
  elseif c=='[' then return decode_arr(s, i)
  elseif c=='t' and s:sub(i,i+3)=='true'  then return true,  i+4
  elseif c=='f' and s:sub(i,i+4)=='false' then return false, i+5
  elseif c=='n' and s:sub(i,i+3)=='null'  then return nil,   i+4
  elseif c=='-' or c:match('%d') then return decode_num(s, i)
  else error("Unexpected JSON token '"..c.."' at "..i) end
end

function json.decode(s)
  assert(type(s)=="string", "json.decode: expected string")
  local val, pos = decode_val(s, 1)
  pos = skip_ws(s, pos)
  if pos <= #s then
    error("Trailing garbage in JSON at position "..pos)
  end
  return val
end

return json
