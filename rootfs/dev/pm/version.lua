-- Pure LuaJIT semantic versioning for ljpm on LJOS
-- Lives at /dev/pm/version.lua
-- No FFI, no C — pure Lua string/number operations.

local M = {}

-- Parse "1.2.3", "1.2", "1", "1.2.3-alpha.1" into a table
function M.parse(str)
  if not str then return nil end
  str = tostring(str):match("^%s*(.-)%s*$")

  local core, pre, build
  -- Split build metadata (+)
  core, build = str:match("^([^+]+)%+(.+)$")
  if not core then core = str end
  -- Split pre-release (-)
  core, pre = core:match("^([^%-]+)%-(.+)$")
  if not core then core = str:match("^([^%-]+)") end

  local nums = {}
  for n in (core or ""):gmatch("%d+") do
    nums[#nums+1] = tonumber(n)
  end
  if #nums == 0 then return nil end

  return {
    major = nums[1] or 0,
    minor = nums[2] or 0,
    patch = nums[3] or 0,
    pre   = pre,
    build = build,
    raw   = str,
  }
end

-- Compare two version strings or parsed tables
-- Returns -1 (a < b), 0 (a == b), 1 (a > b)
function M.cmp(a, b)
  if type(a) == "string" then a = M.parse(a) end
  if type(b) == "string" then b = M.parse(b) end
  if not a or not b then return 0 end

  for _, f in ipairs({"major","minor","patch"}) do
    if a[f] < b[f] then return -1 end
    if a[f] > b[f] then return  1 end
  end
  -- Pre-release: a.pre < a.release
  if a.pre and not b.pre then return -1 end
  if not a.pre and b.pre then return  1 end
  if a.pre and b.pre then
    if a.pre < b.pre then return -1 end
    if a.pre > b.pre then return  1 end
  end
  return 0
end

function M.eq(a,b)  return M.cmp(a,b)==0  end
function M.lt(a,b)  return M.cmp(a,b)<0   end
function M.gt(a,b)  return M.cmp(a,b)>0   end
function M.lte(a,b) return M.cmp(a,b)<=0  end
function M.gte(a,b) return M.cmp(a,b)>=0  end

function M.tostring(v)
  if type(v) == "string" then return v end
  local s = string.format("%d.%d.%d", v.major, v.minor, v.patch)
  if v.pre   then s = s .. "-" .. v.pre   end
  if v.build then s = s .. "+" .. v.build end
  return s
end

-- Parse a constraint expression:
--   "*"  "any"         → any version
--   ">=1.0"  "<=2.0"  ">1"  "<2"  "=1.2.3"
--   "~1.2.3"  (compatible with minor: >=1.2.3 <1.3.0)
--   "^1.2.3"  (compatible with major: >=1.2.3 <2.0.0)
--   "1.2.x"  "1.x"
function M.parse_constraint(str)
  str = str:match("^%s*(.-)%s*$")
  if str=="" or str=="*" or str=="any" then return {op="any"} end

  -- Wildcard: "1.2.x" or "1.x"
  if str:match("%.x$") or str:match("%.%*$") then
    local prefix = str:match("^(%d+%.%d+)%.") or str:match("^(%d+)%.")
    return {op="~", ver=M.parse(prefix or "0"), wildcard=true}
  end

  local op, verstr = str:match("^([><=~^!]+)%s*(.+)$")
  if op and verstr then
    return {op=op, ver=M.parse(verstr)}
  end

  -- Plain version = exact match
  local v = M.parse(str)
  if v then return {op="=", ver=v} end
  return nil
end

-- Check if version v satisfies constraint c
function M.satisfies(v, c)
  if type(v)=="string" then v=M.parse(v) end
  if type(c)=="string" then c=M.parse_constraint(c) end
  if not v or not c then return false end

  local op, cv = c.op, c.ver

  if op=="any" then return true end
  if op=="="  or op=="==" then return M.eq(v,cv)  end
  if op=="!=" then return not M.eq(v,cv) end
  if op==">"  then return M.gt(v,cv) end
  if op==">=" then return M.gte(v,cv) end
  if op=="<"  then return M.lt(v,cv) end
  if op=="<=" then return M.lte(v,cv) end
  if op=="~"  then
    local upper = {major=cv.major, minor=cv.minor+1, patch=0}
    return M.gte(v,cv) and M.lt(v,upper)
  end
  if op=="^"  then
    local upper = {major=cv.major+1, minor=0, patch=0}
    return M.gte(v,cv) and M.lt(v,upper)
  end
  return false
end

-- Find best (latest) version from list that satisfies constraint
function M.resolve(available, constraint)
  if type(constraint)=="string" then constraint=M.parse_constraint(constraint) end
  local best = nil
  for _, v in ipairs(available) do
    local pv = type(v)=="string" and M.parse(v) or v
    if pv and M.satisfies(pv, constraint) then
      if not best or M.gt(pv, best) then best = pv end
    end
  end
  return best and M.tostring(best) or nil
end

-- Sort list of version strings ascending (in-place, returns list)
function M.sort(list)
  table.sort(list, function(a,b) return M.lt(a,b) end)
  return list
end

return M
