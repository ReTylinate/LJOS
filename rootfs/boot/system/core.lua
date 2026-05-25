-- Core system utilities for LJOS
-- Lives at /boot/system/core.lua

local core = {}

function core.ls(path)
  path = path or "."
  os.execute("ls -F " .. path)
end

function core.cd(path)
  local ok = os.execute("test -d " .. path .. " 2>/dev/null")
  if ok ~= 0 then
    print("cd: no such directory: " .. path)
    return false
  end
  return true
end

function core.cat(path)
  os.execute("cat " .. path)
end

function core.mkdir(path)
  os.execute("mkdir -p " .. path)
end

function core.touch(path)
  os.execute("touch " .. path)
end

function core.rm(path)
  os.execute("rm -rf " .. path)
end

function core.write(path, content)
  local f = io.open(path, "w")
  if f then
    f:write(content or "")
    f:close()
  else
    print("write: could not open file: " .. path)
  end
end

return core
