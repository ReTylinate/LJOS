-- Filesystem utilities for ljpm on LJOS
-- Uses io.* for file I/O and busybox (os.execute) for directory ops.
-- Lives at /dev/pm/fs.lua
--
-- NOTE: Pure-FFI variants are possible and planned for when LJOS eliminates
-- busybox. For now, busybox is in /bin/ so os.execute is acceptable.

local fs = {}

-- ─── File I/O ────────────────────────────────────────────────────────────────

function fs.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, "Cannot open '"..path.."': "..(err or "unknown") end
  local data = f:read("*a")
  f:close()
  return data
end

function fs.write(path, data)
  -- Ensure parent directory exists
  local dir = fs.dirname(path)
  if dir and dir ~= "" and dir ~= "." then
    fs.mkdir(dir, true)
  end
  local f, err = io.open(path, "wb")
  if not f then return false, "Cannot write '"..path.."': "..(err or "unknown") end
  f:write(data or "")
  f:close()
  return true
end

function fs.append(path, data)
  local f, err = io.open(path, "ab")
  if not f then return false, err end
  f:write(data or "")
  f:close()
  return true
end

-- ─── Existence & Type Checks (via busybox test) ──────────────────────────────

function fs.exists(path)
  return os.execute("test -e "..fs.quote(path).." 2>/dev/null") == 0
end

function fs.isfile(path)
  return os.execute("test -f "..fs.quote(path).." 2>/dev/null") == 0
end

function fs.isdir(path)
  return os.execute("test -d "..fs.quote(path).." 2>/dev/null") == 0
end

-- ─── Directory Operations ─────────────────────────────────────────────────────

function fs.mkdir(path, recursive)
  if recursive then
    return os.execute("mkdir -p "..fs.quote(path).." 2>/dev/null") == 0
  else
    return os.execute("mkdir "..fs.quote(path).." 2>/dev/null") == 0
  end
end

function fs.rmdir(path)
  return os.execute("rmdir "..fs.quote(path).." 2>/dev/null") == 0
end

function fs.remove(path)
  return os.execute("rm -f "..fs.quote(path).." 2>/dev/null") == 0
end

function fs.rmrf(path)
  if not path or path == "" or path == "/" then
    return false, "Refusing to rm -rf empty or root path"
  end
  return os.execute("rm -rf "..fs.quote(path).." 2>/dev/null") == 0
end

function fs.rename(old, new)
  return os.execute("mv "..fs.quote(old).." "..fs.quote(new).." 2>/dev/null") == 0
end

function fs.copy(src, dst)
  local dir = fs.dirname(dst)
  if dir and dir ~= "" then fs.mkdir(dir, true) end
  return os.execute("cp "..fs.quote(src).." "..fs.quote(dst).." 2>/dev/null") == 0
end

function fs.copydir(src, dst)
  fs.mkdir(dst, true)
  return os.execute("cp -r "..fs.quote(src).."/. "..fs.quote(dst).."/ 2>/dev/null") == 0
end

-- ─── Directory Listing ───────────────────────────────────────────────────────

function fs.listdir(path)
  local p = io.popen("ls -1a "..fs.quote(path).." 2>/dev/null")
  if not p then return nil, "Cannot list directory: "..path end
  local entries = {}
  for line in p:lines() do
    if line ~= "." and line ~= ".." and line ~= "" then
      entries[#entries+1] = line
    end
  end
  p:close()
  table.sort(entries)
  return entries
end

-- ─── Symlinks ────────────────────────────────────────────────────────────────

function fs.symlink(target, linkpath)
  return os.execute("ln -sf "..fs.quote(target).." "..fs.quote(linkpath).." 2>/dev/null") == 0
end

-- ─── Path Helpers ────────────────────────────────────────────────────────────

function fs.basename(path)
  return path:match("([^/]+)$") or path
end

function fs.dirname(path)
  local d = path:match("^(.*)/[^/]*$")
  return d or "."
end

function fs.join(...)
  local parts = {...}
  local out = {}
  for _, p in ipairs(parts) do
    p = tostring(p)
    if p:sub(1,1) == "/" then
      out = {p}
    else
      out[#out+1] = p
    end
  end
  local result = table.concat(out, "/")
  -- Clean up double slashes; wrap in () to discard gsub's count return value
  return (result:gsub("//+", "/"):gsub("^(.-)/?$", "%1")) or "/"
end

function fs.split(path)
  return fs.dirname(path), fs.basename(path)
end

-- Shell-safe quoting (single-quote the path, escape embedded single quotes)
function fs.quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

-- ─── Size ────────────────────────────────────────────────────────────────────

function fs.size(path)
  local p = io.popen("wc -c < "..fs.quote(path).." 2>/dev/null")
  if not p then return nil end
  local n = p:read("*n")
  p:close()
  return n
end

-- ─── Checksum ────────────────────────────────────────────────────────────────

function fs.sha256(path)
  local p = io.popen("sha256sum "..fs.quote(path).." 2>/dev/null")
  if not p then return nil end
  local line = p:read("*l")
  p:close()
  if not line then return nil end
  return line:match("^(%x+)")
end

-- ─── Walk (recursive file list) ──────────────────────────────────────────────

function fs.walk(dir, cb)
  local entries = fs.listdir(dir)
  if not entries then return end
  for _, name in ipairs(entries) do
    local full = dir .. "/" .. name
    if fs.isdir(full) then
      fs.walk(full, cb)
    else
      cb(full, name, dir)
    end
  end
end

return fs
